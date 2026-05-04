-- lsp.lua: proxy LSP requests from the markdown buffer to per-block shadow buffers.
--
-- Because each editable block maps 1:1 to its shadow file (same lines, no offset),
-- position translation is simple: local_row = cursor_row - fence_start_row - 1.

local M = {}

local shadow = require("mdrender.shadow")

-- ── Hover ─────────────────────────────────────────────────────────────────────

M.hover = function(md_buf)
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local col = vim.api.nvim_win_get_cursor(0)[2]

    local block_id, local_row = shadow.block_at_row(md_buf, row)
    if not block_id then
        vim.notify("No editable block at cursor", vim.log.levels.INFO)
        return
    end

    local sbuf = shadow.ensure_buf(md_buf, block_id)
    if not sbuf or not vim.api.nvim_buf_is_valid(sbuf) then
        vim.notify("mdrender: could not create shadow buffer", vim.log.levels.WARN)
        return
    end

    local params = {
        textDocument = vim.lsp.util.make_text_document_params(sbuf),
        position     = { line = local_row, character = col },
    }

    local function do_hover()
        local clients = vim.lsp.get_clients({ bufnr = sbuf })
        if #clients == 0 then
            vim.notify("mdrender: LSP initializing, try again shortly", vim.log.levels.INFO)
            return
        end
        vim.lsp.buf_request_all(sbuf, "textDocument/hover", params, function(results)
            local contents = {}
            for _, resp in pairs(results) do
                local result = resp and resp.result
                if result and result.contents then
                    vim.list_extend(
                        contents,
                        vim.lsp.util.convert_input_to_markdown_lines(result.contents)
                    )
                    contents[#contents + 1] = "---"
                end
            end
            if #contents == 0 then
                vim.notify("No information available", vim.log.levels.INFO)
                return
            end
            contents[#contents] = nil
            vim.lsp.util.open_floating_preview(
                contents, "markdown",
                { focus_id = "mdrender/hover", border = "rounded" }
            )
        end)
    end

    local clients = vim.lsp.get_clients({ bufnr = sbuf })
    if #clients == 0 then
        -- Buffer just created; retry once after a short delay for LSP to attach
        vim.defer_fn(do_hover, 800)
    else
        do_hover()
    end
end

-- ── Diagnostics ───────────────────────────────────────────────────────────────

local diag_ns = vim.api.nvim_create_namespace("mdrender_diagnostics")

M.forward_diagnostics = function(md_buf)
    if not vim.api.nvim_buf_is_valid(md_buf) then return end

    local state = shadow._state[md_buf]
    if not state then
        -- Clear any leftover diagnostics (e.g. all editable blocks were removed)
        vim.diagnostic.set(diag_ns, md_buf, {}, {})
        return
    end

    local mapped = {}
    for id, bstate in pairs(state.blocks) do
        local sbuf = bstate.buf
        if vim.api.nvim_buf_is_valid(sbuf) then
            local diags = vim.diagnostic.get(sbuf)
            for _, d in ipairs(diags) do
                -- Map shadow buffer row back to markdown buffer row
                local md_row = d.lnum + bstate.fence_start_row + 1
                mapped[#mapped + 1] = {
                    bufnr    = md_buf,
                    lnum     = md_row,
                    end_lnum = d.end_lnum and (d.end_lnum + bstate.fence_start_row + 1) or nil,
                    col      = d.col,
                    end_col  = d.end_col,
                    severity = d.severity,
                    message  = d.message,
                    source   = d.source or "rust-analyzer",
                    -- tag the block_id so we can tell where it came from
                    user_data = { mdrender_block_id = id },
                }
            end
        end
    end

    vim.diagnostic.set(diag_ns, md_buf, mapped, {})
end

-- ── Go-to-definition ─────────────────────────────────────────────────────────

M.definition = function(md_buf)
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local col = vim.api.nvim_win_get_cursor(0)[2]

    local block_id, local_row = shadow.block_at_row(md_buf, row)
    if not block_id then
        -- Fall back to default if not in a block
        vim.lsp.buf.definition()
        return
    end

    local sbuf = shadow.ensure_buf(md_buf, block_id)
    if not sbuf then return end

    local params = {
        textDocument = vim.lsp.util.make_text_document_params(sbuf),
        position     = { line = local_row, character = col },
    }

    vim.lsp.buf_request(sbuf, "textDocument/definition", params, function(err, result)
        if err or not result then return end
        local loc = vim.islist(result) and result[1] or result
        if loc then
            vim.lsp.util.jump_to_location(loc, "utf-16", false)
        end
    end)
end

return M
