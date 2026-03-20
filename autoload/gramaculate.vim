let s:system_prompt =
  \ 'You are a grammar and spelling checker for markdown files. ' .
  \ 'The user will provide text with each line prefixed by its line number as "N: text". ' .
  \ 'Identify grammar, spelling, and style errors. ' .
  \ 'Return ONLY a valid JSON array. No explanation, no markdown, no code fences. ' .
  \ 'Each element must have: ' .
  \ '"line" (integer, the line number from the prefix), ' .
  \ '"original" (the exact string to replace), ' .
  \ '"fix" (the corrected string), ' .
  \ '"reason" (brief explanation). ' .
  \ 'If there are no errors return an empty array: []'

" Script-local state for the async job
let s:job              = v:null
let s:chunks           = []
let s:source_bufnr     = -1
let s:status_bufnr     = -1
let s:match_ids        = []
let s:current_fixes    = []
let s:bedrock_tmpfile  = ''

function! s:IsClaudeEndpoint()
  return gramaculate#_is_claude_endpoint()
endfunction

function! s:IsBedrockEndpoint()
  return gramaculate#_is_bedrock_endpoint()
endfunction

" Public for testing
function! gramaculate#_is_claude_endpoint()
  return g:gramaculate_url =~# 'anthropic\.com'
endfunction

" Public for testing
function! gramaculate#_is_bedrock_endpoint()
  return g:gramaculate_url =~# 'bedrock-runtime\.amazonaws\.com'
endfunction

function! gramaculate#Check(line1, line2)
  if s:job isnot v:null
    echo 'Gramaculate: already running.'
    return
  endif

  let s:source_bufnr = bufnr('%')
  let s:chunks       = []
  call s:ClearHighlights()

  let l:content = gramaculate#_number_lines(getline(a:line1, a:line2), a:line1)

  if s:IsBedrockEndpoint()
    let l:payload = json_encode({
      \ 'anthropic_version': 'bedrock-2023-05-31',
      \ 'max_tokens': 4096,
      \ 'system':     s:system_prompt,
      \ 'messages': [
      \   {'role': 'user', 'content': l:content}
      \ ]
    \ })
  elseif s:IsClaudeEndpoint()
    let l:payload = json_encode({
      \ 'model':      g:gramaculate_model,
      \ 'max_tokens': 4096,
      \ 'system':     s:system_prompt,
      \ 'messages': [
      \   {'role': 'user', 'content': l:content}
      \ ]
    \ })
  else
    let l:payload = json_encode({
      \ 'model': g:gramaculate_model,
      \ 'messages': [
      \   {'role': 'system', 'content': s:system_prompt},
      \   {'role': 'user',   'content': l:content}
      \ ]
    \ })
  endif

  call s:OpenStatusWindow()

  if s:IsBedrockEndpoint()
    let s:bedrock_tmpfile = tempname()
    let l:region = matchstr(g:gramaculate_url,
      \ 'bedrock-runtime\.\zs[^.]\+\ze\.amazonaws\.com')
    let l:cmd = ['aws']
    if !empty(g:gramaculate_aws_profile)
      call extend(l:cmd, ['--profile', g:gramaculate_aws_profile])
    endif
    if !empty(l:region)
      call extend(l:cmd, ['--region', l:region])
    endif
    call extend(l:cmd, ['bedrock-runtime', 'invoke-model',
      \ '--model-id', g:gramaculate_model,
      \ '--body', l:payload,
      \ s:bedrock_tmpfile])
  else
    let l:cmd = ['curl', '-s', '-X', 'POST', g:gramaculate_url,
      \ '-H', 'Content-Type: application/json',
      \ '-d', l:payload]
    if s:IsClaudeEndpoint()
      call extend(l:cmd, ['-H', 'anthropic-version: 2023-06-01'])
      if !empty(g:gramaculate_api_key)
        call extend(l:cmd, ['-H', 'x-api-key: ' . g:gramaculate_api_key])
      endif
    elseif !empty(g:gramaculate_api_key)
      call extend(l:cmd, ['-H', 'Authorization: Bearer ' . g:gramaculate_api_key])
    endif
  endif

  let s:job = job_start(
    \ l:cmd,
    \ {
    \   'out_cb':  function('s:OnData'),
    \   'err_cb':  function('s:OnError'),
    \   'exit_cb': function('s:OnExit'),
    \ }
  \ )
endfunction

function! s:OpenStatusWindow()
  let l:winid = bufwinid(s:status_bufnr)
  if l:winid != -1
    call win_gotoid(l:winid)
  else
    botright 3new
    let s:status_bufnr = bufnr('%')
    setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile
    setlocal statusline=Gramaculate
    nnoremap <buffer> q :call <SID>CancelJob()<CR>
    autocmd BufWipeout <buffer> call gramaculate#_on_win_close()
  endif
  setlocal modifiable
  silent! %delete _
  call setline(1, 'Checking...')
  resize 3
  setlocal nomodifiable
endfunction

function! s:OnData(channel, data)
  call add(s:chunks, a:data)
endfunction

function! s:OnError(channel, data)
  call s:Finish()
  echoerr 'Gramaculate: ' . a:data
endfunction

function! s:OnExit(job, status)
  let s:job = v:null

  if a:status != 0
    call s:Finish()
    echoerr 'Gramaculate: command exited with status ' . a:status
    return
  endif

  if s:IsBedrockEndpoint()
    if !filereadable(s:bedrock_tmpfile)
      call s:Finish()
      echoerr 'Gramaculate: Bedrock response file not found'
      return
    endif
    let l:response = join(readfile(s:bedrock_tmpfile), '')
    call delete(s:bedrock_tmpfile)
    let s:bedrock_tmpfile = ''
  else
    let l:response = join(s:chunks, '')
  endif
  let s:chunks = []

  try
    let l:data = json_decode(l:response)
  catch
    call s:Finish()
    echoerr 'Gramaculate: failed to parse API response'
    return
  endtry

  let l:content = (s:IsClaudeEndpoint() || s:IsBedrockEndpoint())
    \ ? l:data.content[0].text
    \ : l:data.choices[0].message.content

  let l:content = gramaculate#_clean_content(l:content)

  try
    let l:fixes = json_decode(l:content)
  catch
    call s:Finish()
    echoerr 'Gramaculate: model returned invalid JSON'
    return
  endtry

  if empty(l:fixes)
    call s:Finish()
    echo 'Gramaculate: no errors found.'
    return
  endif

  call s:ShowFixes(l:fixes)
endfunction

function! s:ShowFixes(fixes)
  let l:winid = bufwinid(s:status_bufnr)
  if l:winid == -1
    botright new
  else
    call win_gotoid(l:winid)
  endif

  setlocal modifiable
  setlocal statusline=Gramaculate\ (<Enter>=apply,\ <leader>cg=apply\ at\ cursor,\ q=quit)

  " b: and s: both reference the same list so either can be used to mutate it
  let b:gramaculate_fixes      = a:fixes
  let b:gramaculate_source_buf = s:source_bufnr
  let s:current_fixes          = a:fixes

  call s:RenderFixes()
  call s:AddHighlights(s:source_bufnr, a:fixes)

  nnoremap <buffer> <CR> :call <SID>ApplyFix()<CR>
  nnoremap <buffer> q    :call <SID>CloseFixWindow()<CR>
endfunction

function! s:RenderFixes()
  setlocal modifiable
  silent! %delete _
  let l:lines = []
  for i in range(len(b:gramaculate_fixes))
    let f = b:gramaculate_fixes[i]
    call add(l:lines, printf('%d) Line %d: "%s" -> "%s"  [%s]',
      \ i + 1, f.line, f.original, f.fix, f.reason))
  endfor
  call setline(1, l:lines)
  resize 10
  setlocal nomodifiable
endfunction

" Shared post-apply logic called from both the fix window and <leader>cg
function! s:PostApply(src_bufnr)
  if empty(s:current_fixes)
    call s:ClearHighlights()
    let s:status_bufnr = -1
    if bufexists(s:status_bufnr)
      execute 'bwipeout' s:status_bufnr
    endif
    echo 'Gramaculate: all fixes applied!'
  else
    call s:AddHighlights(a:src_bufnr, s:current_fixes)
    " Re-render the fix window if it is open
    let l:fix_winid = bufwinid(s:status_bufnr)
    if l:fix_winid != -1
      let l:cur_winid = win_getid()
      call win_gotoid(l:fix_winid)
      call s:RenderFixes()
      call win_gotoid(l:cur_winid)
    endif
  endif
endfunction

function! s:ApplyFix()
  let l:idx = line('.') - 1
  let l:fix = b:gramaculate_fixes[l:idx]
  let l:src = b:gramaculate_source_buf

  let l:orig_lines = split(l:fix.original, "\n", 1)
  let l:num_lines = len(l:orig_lines)
  let l:end_line = l:fix.line + l:num_lines - 1

  let l:target = join(getbufline(l:src, l:fix.line, l:end_line), "\n")
  let l:result = gramaculate#_apply_fix_to_line(l:target, l:fix.original, l:fix.fix)
  let l:new_lines = split(l:result, "\n", 1)

  call deletebufline(l:src, l:fix.line, l:end_line)
  call appendbufline(l:src, l:fix.line - 1, l:new_lines)

  call remove(s:current_fixes, l:idx)
  call s:PostApply(l:src)

  if empty(s:current_fixes)
    q
  endif
endfunction

" Called from <leader>cg in the source buffer
function! gramaculate#ApplyFixAtCursor()
  if empty(s:current_fixes)
    echo 'Gramaculate: no active fixes.'
    return
  endif

  let l:line = line('.')
  let l:col  = col('.')

  for l:i in range(len(s:current_fixes))
    let l:fix       = s:current_fixes[l:i]
    let l:orig_lines = split(l:fix.original, "\n", 1)
    let l:num_lines  = len(l:orig_lines)
    let l:end_line   = l:fix.line + l:num_lines - 1

    " Check if cursor is within the fix's line range
    if l:line < l:fix.line || l:line > l:end_line
      continue
    endif

    " For single-line fixes, check column position exactly
    if l:num_lines == 1
      let l:fix_col = stridx(getline(l:line), l:fix.original) + 1
      let l:fix_end = l:fix_col + len(l:fix.original) - 1
      if l:col < l:fix_col || l:col > l:fix_end
        continue
      endif
    else
      " For multi-line, check column bounds on first and last line
      if l:line == l:fix.line
        let l:fix_col = stridx(getline(l:line), l:orig_lines[0]) + 1
        if l:fix_col <= 0 || l:col < l:fix_col
          continue
        endif
      elseif l:line == l:end_line
        let l:part    = l:orig_lines[-1]
        let l:fix_col = stridx(getline(l:line), l:part) + 1
        let l:fix_end = l:fix_col + len(l:part) - 1
        if l:fix_col <= 0 || l:col > l:fix_end
          continue
        endif
      endif
      " Cursor on a middle line is always within range
    endif

    " Apply the fix (works for both single and multi-line)
    let l:bufnr = bufnr('%')
    let l:target = join(getbufline(l:bufnr, l:fix.line, l:end_line), "\n")
    let l:result = gramaculate#_apply_fix_to_line(l:target, l:fix.original, l:fix.fix)
    let l:new_lines = split(l:result, "\n", 1)

    call deletebufline(l:bufnr, l:fix.line, l:end_line)
    call appendbufline(l:bufnr, l:fix.line - 1, l:new_lines)

    call remove(s:current_fixes, l:i)
    call s:PostApply(s:source_bufnr)
    return
  endfor

  echo 'Gramaculate: no error at cursor position.'
endfunction

" Public for testing
function! gramaculate#_number_lines(lines, start)
  let l:numbered = []
  for l:i in range(len(a:lines))
    call add(l:numbered, printf('%d: %s', a:start + l:i, a:lines[l:i]))
  endfor
  return join(l:numbered, "\n")
endfunction

" Public for testing
function! gramaculate#_clean_content(content)
  let l:c = substitute(a:content, '<think>\_.\{-}<\/think>', '', 'g')
  let l:c = trim(l:c)
  let l:c = substitute(l:c, '^```\(json\)\?\n', '', '')
  let l:c = substitute(l:c, '\n```$', '', '')
  return trim(l:c)
endfunction

" Public for testing
function! gramaculate#_apply_fix_to_line(line, original, fix)
  let l:pos = stridx(a:line, a:original)
  if l:pos < 0
    return a:line
  endif
  return strpart(a:line, 0, l:pos) . a:fix . strpart(a:line, l:pos + len(a:original))
endfunction

" Return [byte_offset, byte_length] of the changed portion within a:original.
" Strips common prefix and suffix so the highlight covers only what differs.
" Public for testing
function! gramaculate#_changed_span(original, fix)
  let l:olen = len(a:original)
  let l:flen = len(a:fix)
  let l:pre  = 0
  while l:pre < l:olen && l:pre < l:flen && a:original[l:pre] ==# a:fix[l:pre]
    let l:pre += 1
  endwhile
  let l:suf = 0
  while l:suf < (l:olen - l:pre) && l:suf < (l:flen - l:pre)
    \ && a:original[l:olen - 1 - l:suf] ==# a:fix[l:flen - 1 - l:suf]
    let l:suf += 1
  endwhile
  let l:hlen = l:olen - l:pre - l:suf
  if l:hlen > 0
    return [l:pre, l:hlen]
  endif
  let l:last_space = strridx(a:original, ' ')
  return l:last_space >= 0 ? [l:last_space + 1, l:olen - l:last_space - 1] : [0, l:olen]
endfunction

function! s:AddHighlights(source_bufnr, fixes)
  call s:ClearHighlights()
  let l:win = bufwinid(a:source_bufnr)
  if l:win == -1
    return
  endif
  for l:fix in a:fixes
    let l:orig_lines = split(l:fix.original, "\n", 1)
    if len(l:orig_lines) <= 1
      " Single-line error
      let l:line_text = getbufline(a:source_bufnr, l:fix.line)
      if empty(l:line_text)
        continue
      endif
      let l:col = stridx(l:line_text[0], l:fix.original) + 1
      if l:col <= 0
        continue
      endif
      let [l:offset, l:hlen] = gramaculate#_changed_span(l:fix.original, l:fix.fix)
      let l:id = matchaddpos('GramaculateError',
        \ [[l:fix.line, l:col + l:offset, l:hlen]],
        \ 10, -1, {'window': l:win})
      call add(s:match_ids, [l:id, l:win])
    else
      " Multi-line error: highlight original text across all spanned lines
      let l:positions = []
      for l:i in range(len(l:orig_lines))
        let l:lnum = l:fix.line + l:i
        let l:part = l:orig_lines[l:i]
        if empty(l:part)
          continue
        endif
        let l:line_text = getbufline(a:source_bufnr, l:lnum)
        if empty(l:line_text)
          continue
        endif
        let l:col = stridx(l:line_text[0], l:part) + 1
        if l:col <= 0
          continue
        endif
        call add(l:positions, [l:lnum, l:col, len(l:part)])
      endfor
      " matchaddpos supports at most 8 positions per call
      while !empty(l:positions)
        let l:batch = remove(l:positions, 0, min([7, len(l:positions) - 1]))
        let l:id = matchaddpos('GramaculateError',
          \ l:batch,
          \ 10, -1, {'window': l:win})
        call add(s:match_ids, [l:id, l:win])
      endwhile
    endif
  endfor
  " Add <leader>cg to the source buffer
  let l:cur_win = win_getid()
  call win_gotoid(l:win)
  execute 'nnoremap <buffer> ' . g:gramaculate_map_apply . ' :call gramaculate#ApplyFixAtCursor()<CR>'
  call win_gotoid(l:cur_win)
endfunction

function! s:ClearHighlights()
  for [l:id, l:win] in s:match_ids
    silent! call matchdelete(l:id, l:win)
  endfor
  let s:match_ids = []
  " Remove <leader>cg from the source buffer if it is still open
  let l:win = bufwinid(s:source_bufnr)
  if l:win != -1
    let l:cur_win = win_getid()
    call win_gotoid(l:win)
    execute 'silent! nunmap <buffer> ' . g:gramaculate_map_apply
    call win_gotoid(l:cur_win)
  endif
endfunction

function! gramaculate#_on_win_close()
  if s:status_bufnr != -1
    call s:ClearHighlights()
    let s:status_bufnr  = -1
    let s:current_fixes = []
  endif
endfunction

function! s:CloseFixWindow()
  call s:ClearHighlights()
  let s:status_bufnr  = -1
  let s:current_fixes = []
  q
endfunction

function! s:CancelJob()
  if s:job isnot v:null
    call job_stop(s:job)
    let s:job = v:null
  endif
  call s:Finish()
endfunction

function! s:Finish()
  if bufexists(s:status_bufnr)
    execute 'bwipeout' s:status_bufnr
  endif
  let s:status_bufnr = -1
  if !empty(s:bedrock_tmpfile)
    call delete(s:bedrock_tmpfile)
    let s:bedrock_tmpfile = ''
  endif
endfunction
