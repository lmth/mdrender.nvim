local M = {}

local parser   = require("mdrender.parser")
local renderer = require("mdrender.renderer")
local hl       = require("mdrender.highlights")
local otter    = require("mdrender.otter_integration")

-- Per-buffer state: timers and per-window saved conceallevel
---@type table<integer, {timer: any, wins: table<integer, {cl:integer, cc:string}>}>
local buf_state = {}

local function get_win(buf)
    local wins = vim.fn.win_findbuf(buf)
    return wins and wins[1] or nil
end

local function attach_window(win)
    -- Save existing values so we can restore them precisely on detach
    local prev_cl = vim.wo[win].conceallevel
    local prev_cc = vim.wo[win].concealcursor
    vim.wo[win].conceallevel = 3
    vim.wo[win].concealcursor = "n"
    return { cl = prev_cl, cc = prev_cc }
end

local function detach_window(win, saved)
    if vim.api.nvim_win_is_valid(win) then
        vim.wo[win].conceallevel  = saved.cl
        vim.wo[win].concealcursor = saved.cc
    end
end

local function do_render(buf)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local items = parser.parse(buf)
    renderer.clear(buf)
    renderer.render(buf, items, get_win(buf))
    otter.activate(buf, items)
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
    if buf_state[buf] then return end  -- already attached

    local win_saved = {}
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        win_saved[win] = attach_window(win)
    end

    buf_state[buf] = { timer = nil, wins = win_saved }

    -- Override filetype-default K and gd so otter-ls handles them
    local map_opts = { buffer = buf, silent = true }
    vim.keymap.set("n", "K",  vim.lsp.buf.hover,       vim.tbl_extend("force", map_opts, { desc = "Hover (otter)" }))
    vim.keymap.set("n", "gd", vim.lsp.buf.definition,  vim.tbl_extend("force", map_opts, { desc = "Go to definition (otter)" }))
    vim.keymap.set("n", "gr", vim.lsp.buf.references,  vim.tbl_extend("force", map_opts, { desc = "References (otter)" }))

    local group = vim.api.nvim_create_augroup("mdrender_buf_" .. buf, { clear = true })

    -- Re-render on text change (debounced)
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group  = group,
        buffer = buf,
        callback = function() schedule_render(buf) end,
    })

    -- Apply conceallevel when this buffer is opened in a new window
    vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
        group  = group,
        buffer = buf,
        callback = function()
            local win = vim.api.nvim_get_current_win()
            if vim.api.nvim_win_get_buf(win) == buf and not buf_state[buf].wins[win] then
                buf_state[buf].wins[win] = attach_window(win)
            end
        end,
    })

    -- Detach when buffer is unloaded
    vim.api.nvim_create_autocmd("BufUnload", {
        group  = group,
        buffer = buf,
        once   = true,
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

    pcall(vim.keymap.del, "n", "K",  { buffer = buf })
    pcall(vim.keymap.del, "n", "gd", { buffer = buf })
    pcall(vim.keymap.del, "n", "gr", { buffer = buf })

    renderer.clear(buf)
    otter.forget(buf)
    buf_state[buf] = nil

    pcall(vim.api.nvim_del_augroup_by_name, "mdrender_buf_" .. buf)
end

M.setup = function(config)
    config = config or {}

    hl.setup()

    -- Re-apply highlight groups when colorscheme changes
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
