if exists('g:loaded_gramaculate')
  finish
endif
let g:loaded_gramaculate = 1

let g:gramaculate_model     = get(g:, 'gramaculate_model', 'qwen3:4b')
let g:gramaculate_url       = get(g:, 'gramaculate_url', 'http://localhost:11434/v1/chat/completions')
let g:gramaculate_api_key   = get(g:, 'gramaculate_api_key', '')
let g:gramaculate_map_apply = get(g:, 'gramaculate_map_apply', '<leader>cg')

command! -range=% Gramaculate call gramaculate#Check(<line1>, <line2>)

highlight default GramaculateError ctermfg=White guifg=White ctermbg=Blue guibg=LightBlue
