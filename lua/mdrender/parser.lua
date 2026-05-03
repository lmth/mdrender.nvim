local M = {}

-- Recursively walk a TSNode tree, calling cb(node) for each node.
-- Skips children of fenced_code_block (no headings inside code).
local function walk(node, cb)
    cb(node)
    if node:type() ~= "fenced_code_block" then
        for child in node:iter_children() do
            walk(child, cb)
        end
    end
end

---@return table[]
M.parse = function(buf)
    local items = {}

    local ok, ts_parser = pcall(vim.treesitter.get_parser, buf, "markdown")
    if not ok or not ts_parser then return items end

    local trees = ts_parser:parse(true)
    if not trees or not trees[1] then return items end

    walk(trees[1]:root(), function(node)
        local ntype = node:type()

        -- ── Fenced code blocks ─────────────────────────────────────────────
        if ntype == "fenced_code_block" then
            local fence_start_row, fence_end_row
            local info_str = ""
            local lang     = ""

            for child in node:iter_children() do
                local ct = child:type()
                if ct == "fenced_code_block_delimiter" then
                    local r = child:start()
                    if fence_start_row == nil then
                        fence_start_row = r
                    else
                        fence_end_row = r
                    end
                elseif ct == "info_string" then
                    info_str = vim.treesitter.get_node_text(child, buf) or ""
                    -- Scan whitespace-delimited tokens
                    for token in info_str:gmatch("%S+") do
                        local t = token:lower()
                        if t ~= "editable" and lang == "" then
                            lang = t  -- first non-"editable" token is the language
                        end
                    end
                end
            end

            -- Skip unclosed blocks
            if fence_start_row == nil then return end

            local _, col_start = node:start()

            -- Check if "editable" appears as a token in the info string
            local editable = false
            for token in info_str:gmatch("%S+") do
                if token:lower() == "editable" then editable = true end
            end

            table.insert(items, {
                type            = "code_block",
                lang            = lang,
                editable        = editable,
                fence_start_row = fence_start_row,
                fence_end_row   = fence_end_row,   -- nil if block is unclosed
                col_start       = col_start,
            })

        -- ── ATX headings (#, ##, …) ────────────────────────────────────────
        elseif ntype == "atx_heading" then
            local sr, sc = node:start()
            local level          = 1
            local marker_end_col = sc + 1   -- fallback: one '#' char
            local text_col       = sc + 2   -- fallback: after '# '

            for child in node:iter_children() do
                local m = child:type():match("^atx_h(%d)_marker$")
                if m then
                    level = tonumber(m)
                    local _, _, _, ec = child:range()
                    marker_end_col = ec
                    -- The space between marker and text is a separate node;
                    -- text_col is one past the marker end, the heading_content
                    -- node starts right after the space.
                    text_col = ec + 1
                    break
                end
            end

            table.insert(items, {
                type           = "heading",
                level          = level,
                row            = sr,
                col_start      = sc,
                marker_end_col = marker_end_col,  -- exclusive end of '##' run
                text_col       = text_col,         -- column where heading text starts
            })
        end
    end)

    return items
end

return M
