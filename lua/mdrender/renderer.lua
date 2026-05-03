local M = {}

M.ns = vim.api.nvim_create_namespace("mdrender")

-- Nerd Font icons per language (fallback to  )
local lang_icons = {
    rust       = " ", python  = " ", lua    = " ",
    javascript = " ", typescript = " ", go   = " ",
    bash       = " ", sh      = " ",  fish  = " ",
    c          = " ", cpp     = " ",  java  = " ",
    html       = " ", css     = " ",  json  = " ",
    yaml       = " ", toml    = " ",  vim   = " ",
    markdown   = " ", sql     = " ",  ruby  = " ",
    php        = " ", swift   = " ",  kotlin = " ",
    erlang     = " ", elixir  = " ",
}

local heading_icons = { "󰼏 ", "󰎨 ", "󰼑 ", "󰎲 ", "󰼓 ", "󰎴 " }

local function set_mark(buf, row, col, opts)
    opts.undo_restore = false
    opts.invalidate   = true
    vim.api.nvim_buf_set_extmark(buf, M.ns, row, col, opts)
end

-- ── Code blocks ──────────────────────────────────────────────────────────────

local function render_editable(buf, item, win_width)
    local box_width = math.min((win_width or 80) - item.col_start - 1, 80)
    local icon      = lang_icons[item.lang] or " "
    local label     = icon .. (item.lang ~= "" and item.lang or "code")
    local label_str = " " .. label .. " "
    local label_w   = vim.fn.strdisplaywidth(label_str)

    -- Top border: ┌─ icon lang ──┐
    local fill_w = math.max(0, box_width - 2 - label_w - 1)
    local top_virt = {
        { "┌─",                               "MdRenderEditBorder" },
        { label_str,                           "MdRenderEditLabel"  },
        { string.rep("─", fill_w) .. "┐",     "MdRenderEditBorder" },
    }

    -- Bottom border: └──────────────┘
    local bot_virt = {
        { "└" .. string.rep("─", box_width - 2) .. "┘", "MdRenderEditBorder" },
    }

    -- Conceal opening fence, insert top border
    if item.fence_start_row then
        local fence_line = vim.api.nvim_buf_get_lines(buf, item.fence_start_row, item.fence_start_row + 1, false)[1] or ""
        set_mark(buf, item.fence_start_row, item.col_start, {
            end_col        = #fence_line,
            conceal        = "",
            virt_text      = top_virt,
            virt_text_pos  = "inline",
        })
    end

    -- Background fill on content lines
    if item.fence_start_row and item.fence_end_row then
        for row = item.fence_start_row + 1, item.fence_end_row - 1 do
            set_mark(buf, row, 0, { line_hl_group = "MdRenderEditFill" })
        end

        -- Conceal closing fence, insert bottom border
        local close_line = vim.api.nvim_buf_get_lines(buf, item.fence_end_row, item.fence_end_row + 1, false)[1] or ""
        set_mark(buf, item.fence_end_row, item.col_start, {
            end_col        = #close_line,
            conceal        = "",
            virt_text      = bot_virt,
            virt_text_pos  = "inline",
        })
    end
end

local function render_plain_code(buf, item)
    if not item.fence_start_row then return end

    local icon      = lang_icons[item.lang] or " "
    local label_str = " " .. icon .. (item.lang ~= "" and item.lang or "") .. " "

    -- Conceal opening fence, show label on the right
    local fence_line = vim.api.nvim_buf_get_lines(buf, item.fence_start_row, item.fence_start_row + 1, false)[1] or ""
    set_mark(buf, item.fence_start_row, item.col_start, {
        end_col        = #fence_line,
        conceal        = "",
        virt_text      = { { label_str, "MdRenderCodeLabel" } },
        virt_text_pos  = "right_align",
    })

    -- Background fill: fence lines + content
    local end_row = item.fence_end_row or item.fence_start_row
    for row = item.fence_start_row, end_row do
        set_mark(buf, row, 0, { line_hl_group = "MdRenderCode" })
    end

    -- Conceal closing fence (show nothing — bg already marks end of block)
    if item.fence_end_row then
        local close_line = vim.api.nvim_buf_get_lines(buf, item.fence_end_row, item.fence_end_row + 1, false)[1] or ""
        set_mark(buf, item.fence_end_row, item.col_start, {
            end_col = #close_line,
            conceal = "",
        })
    end
end

-- ── Headings ─────────────────────────────────────────────────────────────────

local function render_heading(buf, item)
    local lvl  = math.min(item.level, 6)
    local hl   = "MdRenderHeading" .. lvl
    local sign = "MdRenderHeadingSign" .. lvl
    local icon = heading_icons[lvl] or "# "

    -- Conceal the '#...' marker (and the space after it)
    set_mark(buf, item.row, item.col_start, {
        end_col   = item.text_col,
        conceal   = "",
        virt_text = { { icon, sign } },
        virt_text_pos = "inline",
    })

    -- Colour the whole heading line
    set_mark(buf, item.row, item.col_start, {
        line_hl_group = hl,
    })
end

-- ── Output blocks ─────────────────────────────────────────────────────────────

local function render_output(buf, item)
    if not item.fence_start_row then return end

    -- Conceal opening fence, show a terminal-style label
    local fence_line = vim.api.nvim_buf_get_lines(buf, item.fence_start_row, item.fence_start_row + 1, false)[1] or ""
    set_mark(buf, item.fence_start_row, item.col_start, {
        end_col       = #fence_line,
        conceal       = "",
        virt_text     = { { "  output ", "MdRenderOutputLabel" } },
        virt_text_pos = "inline",
    })

    -- Background on all lines (fences + content)
    local end_row = item.fence_end_row or item.fence_start_row
    for row = item.fence_start_row, end_row do
        set_mark(buf, row, 0, { line_hl_group = "MdRenderOutputFill" })
    end

    -- Dim the header line (first content line = status + timestamp)
    if item.fence_end_row and item.fence_start_row + 1 < item.fence_end_row then
        set_mark(buf, item.fence_start_row + 1, 0, { line_hl_group = "MdRenderOutputHeader" })
    end

    -- Conceal closing fence
    if item.fence_end_row then
        local close_line = vim.api.nvim_buf_get_lines(buf, item.fence_end_row, item.fence_end_row + 1, false)[1] or ""
        set_mark(buf, item.fence_end_row, item.col_start, {
            end_col = #close_line,
            conceal = "",
        })
    end
end

-- ── Public API ───────────────────────────────────────────────────────────────

M.clear = function(buf)
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
end

M.render = function(buf, items, win)
    local win_width = win and vim.api.nvim_win_get_width(win) or 80

    for _, item in ipairs(items) do
        local ok, err = pcall(function()
            if item.type == "output_block" then
                render_output(buf, item)
            elseif item.type == "code_block" then
                if item.editable then
                    render_editable(buf, item, win_width)
                else
                    render_plain_code(buf, item)
                end
            elseif item.type == "heading" then
                render_heading(buf, item)
            end
        end)
        if not ok then
            vim.notify("mdrender render error: " .. tostring(err), vim.log.levels.WARN)
        end
    end
end

return M
