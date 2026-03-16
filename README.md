# vim-gramaculate

Vim grammar checker for markdown files, powered by AI. Supports any OpenAI API
compatible model, local, remote, Claude and AWS Bedrock.

![demo](demo/demo.gif)

## Install

Use your plugin manager to install vim-gramaculate

```vimscript
Plug 'ahalbert/vim-gramaculate'
```

### Running Locally

The defaults assume you want to use a locally run LLM to check grammar. Install
[Ollama](https://ollama.com/) and then install the model `qwen3:4b`. If you want
to use a different model, set `g:gramaculate_model`.

### Calling a remote model

It's a lot faster to call a model such as Claude Haiku on an underpowered
machine. Set the following variables to call another model:

```vimscript
let g:gramaculate_url       = 'https://api.anthropic.com/v1/messages'
let g:gramaculate_model     = 'claude-haiku-4-5-20251001'
let g:gramaculate_api_key   = 'YOUR-API-KEY'
```

### Amazon Bedrock

Set `g:gramaculate_url` to your Bedrock endpoint and `g:gramaculate_model` to
the Bedrock model ID. The region is extracted from the URL automatically. AWS
credentials are read from the environment or `~/.aws/credentials` via the `aws`
CLI, which must be installed and configured.

```vimscript
let g:gramaculate_url   = 'https://bedrock-runtime.us-east-1.amazonaws.com'
let g:gramaculate_model = 'anthropic.claude-haiku-4-5-20251001-v1:0'
```

## Check Grammar

Use `:Gramaculate` to check the grammar of an entire markdown file.
vim-gramaculate supports ranges, so you can select text in visual mode and only
check it. Once the model returns the fixes, you can use `<Enter>` in the window
to apply a change, or a mapping you set in `g:gramaculate_map_apply` (default:
`<leader>cg`) to apply the change in the buffer. Use 'q' in the vim-gramaculate
window to close it and clear the highlights.

## Configuration

| Variable                  | Default                                      | Description                                     |
| ------------------------- | -------------------------------------------- | ----------------------------------------------- |
| `g:gramaculate_model`     | `qwen3:4b`                                   | Model name                                      |
| `g:gramaculate_url`       | `http://localhost:11434/v1/chat/completions` | API endpoint                                    |
| `g:gramaculate_api_key`   | `''`                                         | API key                                         |
| `g:gramaculate_map_apply` | `<leader>cg`                                 | Mapping to apply fix at cursor in source buffer |

## Alternatives

I made gramaculate because I wasn't getting useful fixes from more traditional
grammar checkers, but you may find them useful because they run much faster and
integrate with ALE. Unfortunately, checking on save is cost and performance
prohibitive (for now).

- [Harper](https://writewithharper.com/)
- [markdown-lint](https://github.com/markdownlint/markdownlint)
- [Vale](https://vale.sh/)
- [proselint](https://github.com/amperser/proselint)
- [write-good](https://github.com/btford/write-good)
