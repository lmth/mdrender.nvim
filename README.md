# mdrender.nvim

`mdrender.nvim` is a Neovim plugin that renders markdown beautifully in-buffer using extmarks and virtual text, with no external rendering tools required. It also includes special support for live-editable Rust code blocks backed by `rust-analyzer`.

## Features

- Headings with icons and colored backgrounds per level
- Code blocks with language icons and full-width background fill for all languages
- Editable Rust blocks with box borders, LSP support (`K` hover, `gd` go-to-definition, `gl` diagnostics), block execution on `<leader>r`, and stdout/stderr fences with collapsible build output
- Supports both `````rust editable`` and `````rust,editable`` fence styles (including mdBook syntax)
- Lazy LSP attach so `rust-analyzer` starts only when the cursor enters a code block

## Prerequisites

- Neovim >= 0.10
- `nvim-treesitter`
- `rustaceanvim` for Rust editable blocks
- A Rust toolchain installed via `rustup`

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "lmth/mdrender.nvim",
  ft = { "markdown", "quarto" },
  dependencies = { "nvim-treesitter/nvim-treesitter" },
  config = function()
    require("mdrender").setup()
  end,
}
```

## Keymaps

These buffer-local mappings are set on markdown buffers:

| Keymap | Description |
| --- | --- |
| `K` | Hover documentation for the symbol under the cursor inside an editable Rust block. |
| `gd` | Go to definition inside an editable Rust block. |
| `gl` | Show diagnostics and refresh the rust-analyzer view for the current block. |
| `<leader>r` | Run the current editable Rust block. |

## Notes

Editable blocks are currently Rust-only. Other fenced code blocks still render with syntax-aware highlighting and styling, but they are not executable yet. Multi-language editable block support is planned.

## Architecture

For editable Rust fences, `mdrender.nvim` creates shadow `.rs` files inside a `.mdrust/` subdirectory and groups them into one Cargo workspace per markdown file. `rustaceanvim` attaches lazily per block, which keeps ordinary markdown navigation fast while still enabling rich Rust tooling when you enter an editable code fence.
