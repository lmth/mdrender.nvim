local M = {}

local parser   = require("mdrender.parser")
local renderer = require("mdrender.renderer")
local hl       = require("mdrender.highlights")
local shadow   = require("mdrender.shadow")
local lsp      = require("mdrender.lsp")
local runner   = require("mdrender.runner")

-- Per-buffer state: timers and per-window saved conceallevel
---@type table<integer, {timer: any, wins: table<integer, {cl:integer, cc:string}>}>
local buf_state = {}

local function get_win(buf)
    local wins = vim.fn.win_findbuf(buf)
    return wins and wins[1] or nil
end

local function attach_window(win)
    local prev_cl = vim.wo[win].conceallevel
    local prev_cc = vim.wo[win].concealcursor
    local prev_fm = vim.wo[win].foldmethod
    vim.wo[win].conceallevel = 3
    vim.wo[win].concealcursor = "n"
    vim.wo[win].foldmethod = "manual"
    return { cl = prev_cl, cc = prev_cc, fm = prev_fm }
end

local function detach_window(win, saved)
    if vim.api.nvim_win_is_valid(win) then
        vim.wo[win].conceallevel  = saved.cl
        vim.wo[win].concealcursor = saved.cc
        vim.wo[win].foldmethod    = saved.fm
    end
end

local function do_render(buf)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local items = parser.parse(buf)
    local win   = get_win(buf)
    renderer.clear(buf, win)
    renderer.render(buf, items, win)
    shadow.sync(buf, items)
    -- Forward diagnostics from shadow bufs to this buffer
    vim.schedule(function() lsp.forward_diagnostics(buf) end)
end

local function schedule_render(buf)
    local state = buf_state[buf]
    if not state then return end

    if state.timer then
        state.timer:stop()
        state.timer:close()
        state.timer = nil
    end

    local timer = vim.uv.new_timer()
    state.timer = timer
    timer:start(300, 0, vim.schedule_wrap(function()
        if state.timer == timer then state.timer = nil end
        timer:close()
        do_render(buf)
    end))
end

local function attach(buf)
    if buf_state[buf] then return end

    local win_saved = {}
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        win_saved[win] = attach_window(win)
    end

    buf_state[buf] = { timer = nil, wins = win_saved }

    local map_opts = { buffer = buf, silent = true }

    -- K: hover via shadow buffer LSP (direct, no otter proxy)
    vim.keymap.set("n", "K", function()
        lsp.hover(buf)
    end, vim.tbl_extend("force", map_opts, { desc = "Hover (mdrender)" }))

    -- gd: go-to-definition via shadow buffer
    vim.keymap.set("n", "gd", function()
        lsp.definition(buf)
    end, vim.tbl_extend("force", map_opts, { desc = "Go to definition (mdrender)" }))

    -- <leader>r: run the block under the cursor
    vim.keymap.set("n", "<leader>r", function()
        runner.run(buf)
    end, vim.tbl_extend("force", map_opts, { desc = "Run editable block (mdrender)" }))

    local group = vim.api.nvim_create_augroup("mdrender_buf_" .. buf, { clear = true })

    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group    = group,
        buffer   = buf,
        callback = function()
            local row = vim.api.nvim_win_get_cursor(0)[1] - 1
            local block_id = shadow.block_at_row(buf, row)
            if block_id then shadow.ensure_buf(buf, block_id) end
        end,
    })

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group    = group,
        buffer   = buf,
        callback = function() schedule_render(buf) end,
    })

    vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
        group    = group,
        buffer   = buf,
        callback = function()
            local win = vim.api.nvim_get_current_win()
            if vim.api.nvim_win_get_buf(win) == buf and not buf_state[buf].wins[win] then
                buf_state[buf].wins[win] = attach_window(win)
            end
        end,
    })

    -- Forward diagnostics whenever any buffer's diagnostics change
    vim.api.nvim_create_autocmd("DiagnosticChanged", {
        group    = group,
        callback = function(ev)
            -- Only act if the changed buffer is one of our shadow buffers
            local state = shadow._state[buf]
            if not state then return end
            for _, bstate in pairs(state.blocks) do
                if bstate.buf == ev.buf then
                    vim.schedule(function() lsp.forward_diagnostics(buf) end)
                    return
                end
            end
        end,
    })

    vim.api.nvim_create_autocmd("BufUnload", {
        group    = group,
        buffer   = buf,
        once     = true,
        callback = function() M.detach(buf) end,
    })

    do_render(buf)
end

M.detach = function(buf)
    local state = buf_state[buf]
    if not state then return end

    if state.timer then
        state.timer:stop()
        state.timer:close()
    end

    for win, saved in pairs(state.wins) do
        detach_window(win, saved)
    end

    pcall(vim.keymap.del, "n", "K",        { buffer = buf })
    pcall(vim.keymap.del, "n", "gd",       { buffer = buf })
    pcall(vim.keymap.del, "n", "<leader>r", { buffer = buf })

    renderer.clear(buf)
    shadow.forget(buf)
    buf_state[buf] = nil

    pcall(vim.api.nvim_del_augroup_by_name, "mdrender_buf_" .. buf)
end

M.setup = function(config)
    config = config or {}

    hl.setup()

    vim.api.nvim_create_autocmd("ColorScheme", {
        group    = vim.api.nvim_create_augroup("mdrender_global", { clear = true }),
        callback = hl.setup,
    })

    local filetypes = config.filetypes or { "markdown", "quarto" }
    local ft_pat    = table.concat(filetypes, ",")

    vim.api.nvim_create_autocmd("FileType", {
        group   = vim.api.nvim_create_augroup("mdrender_attach", { clear = true }),
        pattern = ft_pat,
        callback = function(ev) attach(ev.buf) end,
    })
end

return M
