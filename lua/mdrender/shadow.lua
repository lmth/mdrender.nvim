-- shadow.lua: manages per-block shadow .rs files and the .mdrust/ Cargo workspace.
--
-- For each markdown buffer with editable rust blocks:
--   <md_dir>/.mdrust/<md-stem>/
--     Cargo.toml          (plugin-managed)
--     <block_id>.rs       (one per editable rust block)
--
-- Files are written to disk eagerly on every render so rust-analyzer can read
-- them. Neovim buffers (which trigger rustaceanvim attachment) are created
-- lazily via ensure_buf(), called when the cursor first enters a block.

local M = {}

-- md_buf → { dir: string, blocks: { id → { path, fence_start_row, fence_end_row, buf? } } }
M._state = {}

-- ── Disk helpers ─────────────────────────────────────────────────────────────

local function write_file(path, lines)
    local f = io.open(path, "w")
    if not f then return end
    f:write(table.concat(lines, "\n"))
    if #lines > 0 then f:write("\n") end
    f:close()
end

-- Write only if content changed; returns true when the file was updated.
local function sync_file(path, lines)
    local expected = table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
    local f = io.open(path, "r")
    if f then
        local existing = f:read("*a")
        f:close()
        if existing == expected then return false end
    end
    local wf = io.open(path, "w")
    if wf then wf:write(expected); wf:close() end
    return true
end

local CARGO_HEADER = [[
[package]
name = "mdrust"
version = "0.1.0"
edition = "2021"

]]

local function write_cargo_toml(dir, block_ids)
    local parts = { CARGO_HEADER }
    for _, id in ipairs(block_ids) do
        parts[#parts + 1] = string.format(
            '[[bin]]\nname = "%s"\npath = "%s.rs"\n\n', id, id
        )
    end
    local f = io.open(dir .. "/Cargo.toml", "w")
    if f then f:write(table.concat(parts)); f:close() end
end

-- ── Block content ─────────────────────────────────────────────────────────────

local function get_block_lines(md_buf, item)
    if not item.fence_start_row or not item.fence_end_row then return {} end
    local first = item.fence_start_row + 1
    local last  = item.fence_end_row
    if first >= last then return {} end
    return vim.api.nvim_buf_get_lines(md_buf, first, last, false)
end

-- ── Public API ───────────────────────────────────────────────────────────────

-- Called on every render. Writes .rs files + Cargo.toml to disk.
-- Does NOT create Neovim buffers — use ensure_buf() for that.
M.sync = function(md_buf, items)
    local md_path = vim.api.nvim_buf_get_name(md_buf)
    if md_path == "" then return end

    local md_dir  = vim.fn.fnamemodify(md_path, ":h")
    local md_stem = vim.fn.fnamemodify(md_path, ":t:r")
    md_stem = md_stem:gsub("[^%w%-]", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
    if md_stem == "" then md_stem = "unnamed" end
    local dir = md_dir .. "/.mdrust/" .. md_stem

    local editable = {}
    for _, item in ipairs(items) do
        if item.type == "code_block" and item.editable
                and item.lang == "rust" and item.block_id then
            editable[#editable + 1] = item
        end
    end

    if #editable == 0 then
        if M._state[md_buf] then M.forget(md_buf) end
        return
    end

    if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end

    local state = M._state[md_buf] or { dir = dir, blocks = {} }
    M._state[md_buf] = state
    state.dir = dir

    local current_ids = {}
    for _, item in ipairs(editable) do current_ids[item.block_id] = true end

    -- Remove stale blocks
    for id, bstate in pairs(state.blocks) do
        if not current_ids[id] then
            if bstate.buf and vim.api.nvim_buf_is_valid(bstate.buf) then
                pcall(vim.api.nvim_buf_delete, bstate.buf, { force = true })
            end
            os.remove(bstate.path)
            state.blocks[id] = nil
        end
    end

    local ordered_ids = {}
    for _, item in ipairs(editable) do
        local id    = item.block_id
        local path  = dir .. "/" .. id .. ".rs"
        local lines = get_block_lines(md_buf, item)

        if state.blocks[id] then
            -- Update file on disk; also update in-memory buffer if it exists
            if sync_file(path, lines) then
                local bstate = state.blocks[id]
                if bstate.buf and vim.api.nvim_buf_is_valid(bstate.buf) then
                    vim.api.nvim_buf_set_lines(bstate.buf, 0, -1, false, lines)
                end
            end
            state.blocks[id].fence_start_row = item.fence_start_row
            state.blocks[id].fence_end_row   = item.fence_end_row
        else
            write_file(path, lines)
            state.blocks[id] = {
                path            = path,
                buf             = nil,   -- created lazily by ensure_buf()
                fence_start_row = item.fence_start_row,
                fence_end_row   = item.fence_end_row,
            }
        end
        ordered_ids[#ordered_ids + 1] = id
    end

    write_cargo_toml(dir, ordered_ids)
end

-- Create the Neovim buffer for a block (if not already done).
-- This triggers rustaceanvim to attach to the shadow file.
-- Safe to call multiple times; no-op if buffer already exists.
M.ensure_buf = function(md_buf, block_id)
    local state = M._state[md_buf]
    if not state then return nil end
    local bstate = state.blocks[block_id]
    if not bstate then return nil end

    if bstate.buf and vim.api.nvim_buf_is_valid(bstate.buf) then
        return bstate.buf
    end

    local buf = vim.fn.bufadd(bstate.path)
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_option(buf, "buftype",   "")
    vim.api.nvim_buf_set_option(buf, "bufhidden", "hide")
    vim.api.nvim_buf_set_option(buf, "swapfile",  false)
    vim.api.nvim_buf_set_option(buf, "buflisted", true)
    vim.api.nvim_buf_call(buf, function()
        -- FileType autocmd fires in buffer context → rustaceanvim attaches
        vim.cmd("set filetype=rust")
    end)
    bstate.buf = buf
    return buf
end

-- Return (block_id, local_row) for a given markdown buffer row.
M.block_at_row = function(md_buf, row)
    local state = M._state[md_buf]
    if not state then return nil, nil end
    for id, bstate in pairs(state.blocks) do
        local s = bstate.fence_start_row
        local e = bstate.fence_end_row
        if s and e and row > s and row < e then
            return id, row - s - 1
        end
    end
    return nil, nil
end

M.shadow_buf = function(md_buf, block_id)
    local state = M._state[md_buf]
    if not state or not block_id then return nil end
    local bstate = state.blocks[block_id]
    return bstate and bstate.buf or nil
end

M.mdrust_dir = function(md_buf)
    local state = M._state[md_buf]
    return state and state.dir or nil
end

M.forget = function(md_buf)
    local state = M._state[md_buf]
    if not state then return end
    for _, bstate in pairs(state.blocks) do
        if bstate.buf and vim.api.nvim_buf_is_valid(bstate.buf) then
            pcall(vim.api.nvim_buf_delete, bstate.buf, { force = true })
        end
    end
    M._state[md_buf] = nil
end

return M
