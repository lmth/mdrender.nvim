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

    -- Hint line above the block: show <leader>r run keybinding
    if item.fence_start_row then
        set_mark(buf, item.fence_start_row, 0, {
            virt_lines       = { { { "  <leader>r  run", "MdRenderHint" } } },
            virt_lines_above = true,
        })
    end

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

-- ── Build blocks ──────────────────────────────────────────────────────────────

-- Build fences look like:
--   ```build id=<id>
--   -- exit 0  |  <timestamp>
--   <cargo lines>
--   ```
--
-- On success (exit 0): fence label is shown, content lines are concealed.
-- On failure          : full content shown with error highlight.

local function render_build(buf, item, win)
    if not item.fence_start_row then return end

    -- Determine success by reading first content line
    local success = false
    if item.fence_end_row and item.fence_start_row + 1 < item.fence_end_row then
        local header = vim.api.nvim_buf_get_lines(
            buf, item.fence_start_row + 1, item.fence_start_row + 2, false)[1] or ""
        success = header:match("^%-%-  ?exit 0") ~= nil
    end

    local fill_hl  = success and "MdRenderBuildFill"       or "MdRenderBuildErrorFill"
    local label_hl = success and "MdRenderBuildLabel"      or "MdRenderBuildErrorLabel"
    local label    = success and "  build (ok) "          or "  build (FAILED) "

    -- Conceal opening fence, show label
    local fence_line = vim.api.nvim_buf_get_lines(
        buf, item.fence_start_row, item.fence_start_row + 1, false)[1] or ""
    set_mark(buf, item.fence_start_row, item.col_start, {
        end_col       = #fence_line,
        conceal       = "",
        virt_text     = { { label, label_hl } },
        virt_text_pos = "inline",
    })

    -- Background on all lines
    local end_row = item.fence_end_row or item.fence_start_row
    for row = item.fence_start_row, end_row do
        set_mark(buf, row, 0, { line_hl_group = fill_hl })
    end

    if item.fence_end_row then
        -- Conceal closing fence
        local close_line = vim.api.nvim_buf_get_lines(
            buf, item.fence_end_row, item.fence_end_row + 1, false)[1] or ""
        set_mark(buf, item.fence_end_row, item.col_start, {
            end_col = #close_line,
            conceal = "",
        })

        if success and win and vim.api.nvim_win_is_valid(win)
                and item.fence_start_row + 1 < item.fence_end_row then
            -- Create a real vim fold over the content lines (1-indexed for :fold)
            local fold_start = item.fence_start_row + 2   -- first content line
            local fold_end   = item.fence_end_row  + 1    -- closing ``` line
            pcall(vim.api.nvim_win_call, win, function()
                vim.cmd(fold_start .. "," .. fold_end .. "fold")
            end)
        end
    end
end



-- ── Tables ───────────────────────────────────────────────────────────────────

local function parse_cells(line)
    -- Strip optional leading indent and surrounding pipes, then split.
    local inner = line:match("^%s*|?(.-)%s*|?%s*$") or line
    local cells = {}
    for cell in (inner .. "|"):gmatch("([^|]*)|") do
        cells[#cells + 1] = cell:match("^%s*(.-)%s*$")
    end
    -- A trailing | produces a final empty string — drop it.
    if cells[#cells] == "" then cells[#cells] = nil end
    return cells
end

local function is_delimiter_row(line)
    -- Only |, -, :, and whitespace, and at least one -.
    return line:match("^%s*|") ~= nil
        and line:match("%-") ~= nil
        and line:match("[^|%-%s:]") == nil
end

local function render_table(buf, item)
    local lines = vim.api.nvim_buf_get_lines(buf, item.start_row, item.end_row + 1, false)
    if #lines == 0 then return end

    -- Classify each buffer line.
    -- parsed[i] = { raw, buf_row, is_delim, cells }
    local parsed = {}
    for i, line in ipairs(lines) do
        parsed[i] = {
            raw     = line,
            buf_row = item.start_row + i - 1,
            is_delim = is_delimiter_row(line),
            cells    = is_delimiter_row(line) and {} or parse_cells(line),
        }
    end

    -- Column widths (max cell display-width across all data rows, min 3).
    local col_widths = {}
    local ncols = 0
    for _, row in ipairs(parsed) do
        if not row.is_delim then
            ncols = math.max(ncols, #row.cells)
            for j, cell in ipairs(row.cells) do
                local w = vim.fn.strdisplaywidth(cell)
                col_widths[j] = math.max(col_widths[j] or 3, w)
            end
        end
    end
    if ncols == 0 then return end
    -- Ensure every column has at least a minimum width entry.
    for j = 1, ncols do col_widths[j] = col_widths[j] or 3 end

    local B = "MdRenderTableBorder"
    local H = "MdRenderTableHeader"
    local C = "MdRenderTableCell"

    -- Build a horizontal rule segment list: ┌─┬─┐  /  ├─┼─┤  /  └─┴─┘
    local function hline(l, m, r)
        local segs = { { l, B } }
        for j = 1, ncols do
            segs[#segs + 1] = { string.rep("─", col_widths[j] + 2), B }
            segs[#segs + 1] = { j < ncols and m or r, B }
        end
        return segs
    end

    -- Build a data-row segment list: │ cell │ cell │
    local function data_line(cells, cell_hl)
        local segs = {}
        for j = 1, ncols do
            local cell = cells[j] or ""
            local pad  = col_widths[j] - vim.fn.strdisplaywidth(cell)
            segs[#segs + 1] = { "│", B }
            segs[#segs + 1] = { " " .. cell .. string.rep(" ", pad + 1), cell_hl }
        end
        segs[#segs + 1] = { "│", B }
        return segs
    end

    -- Top border above the first row.
    set_mark(buf, parsed[1].buf_row, 0, {
        virt_lines       = { hline("┌", "┬", "┐") },
        virt_lines_above = true,
    })

    -- Each row: conceal the raw text, inject formatted virtual text.
    local header_done = false
    for _, row in ipairs(parsed) do
        local segs
        if row.is_delim then
            segs = hline("├", "┼", "┤")
        elseif not header_done then
            header_done = true
            segs = data_line(row.cells, H)
        else
            segs = data_line(row.cells, C)
        end

        set_mark(buf, row.buf_row, 0, {
            end_col       = #row.raw,
            conceal       = "",
            virt_text     = segs,
            virt_text_pos = "inline",
        })
        set_mark(buf, row.buf_row, 0, { line_hl_group = "MdRenderTableFill" })
    end

    -- Bottom border below the last row.
    set_mark(buf, parsed[#parsed].buf_row, 0, {
        virt_lines = { hline("└", "┴", "┘") },
    })
end



M.clear = function(buf, win)
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
    -- Clear all manual folds in the window (re-render will recreate them)
    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_call, win, function() vim.cmd("normal! zE") end)
    end
end

M.render = function(buf, items, win)
    local win_width = win and vim.api.nvim_win_get_width(win) or 80

    for _, item in ipairs(items) do
        local ok, err = pcall(function()
            if item.type == "output_block" then
                render_output(buf, item)
            elseif item.type == "build_block" then
                render_build(buf, item, win)
            elseif item.type == "code_block" then
                if item.editable then
                    render_editable(buf, item, win_width)
                else
                    render_plain_code(buf, item)
                end
            elseif item.type == "table" then
                render_table(buf, item)
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
