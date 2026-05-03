-- shadow.lua: manages per-block shadow .rs files and the .mdrust/ Cargo workspace.
--
-- For each markdown buffer with editable rust blocks:
--   <md_dir>/.mdrust/<md-stem>/
--     Cargo.toml          (plugin-managed)
--     <block_id>.rs       (one per editable rust block)
--
-- Using a per-file subdirectory avoids collisions when multiple markdown files
-- live in the same directory.
--
-- Each shadow file gets a hidden Neovim buffer so rustaceanvim attaches to it.
-- Content is kept in sync with the markdown buffer on every debounced render.

local M = {}

-- md_buf → { dir: string, blocks: { id → { buf, path, start_row, end_row } } }
M._state = {}

-- ── Cargo.toml management ────────────────────────────────────────────────────

local CARGO_HEADER = [[
[package]
name = "mdrust"
version = "0.1.0"
edition = "2021"

]]

local function write_cargo_toml(dir, block_ids)
    local lines = { CARGO_HEADER }
    for _, id in ipairs(block_ids) do
        lines[#lines + 1] = string.format(
            '[[bin]]\nname = "%s"\npath = "%s.rs"\n\n',
            id, id
        )
    end
    local path = dir .. "/Cargo.toml"
    local f = io.open(path, "w")
    if f then
        f:write(table.concat(lines))
        f:close()
    end
end

-- ── Shadow buffer management ─────────────────────────────────────────────────

-- Extract just the content lines (between fences) from the markdown buffer.
local function get_block_lines(md_buf, item)
    if not item.fence_start_row or not item.fence_end_row then return {} end
    local first = item.fence_start_row + 1
    local last  = item.fence_end_row   -- exclusive in nvim_buf_get_lines
    if first >= last then return {} end
    return vim.api.nvim_buf_get_lines(md_buf, first, last, false)
end

local function create_shadow_buf(path, lines)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_option(buf, "buftype", "")
    vim.api.nvim_buf_set_option(buf, "bufhidden", "hide")
    vim.api.nvim_buf_set_option(buf, "swapfile", false)
    vim.api.nvim_buf_set_option(buf, "filetype", "rust")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    -- Write to disk so rustaceanvim / cargo can read it
    vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent! write!")
    end)
    return buf
end

local function sync_shadow_buf(shadow_buf, path, lines)
    if not vim.api.nvim_buf_is_valid(shadow_buf) then return false end
    local current = vim.api.nvim_buf_get_lines(shadow_buf, 0, -1, false)
    -- Only write if content actually changed
    local changed = #current ~= #lines
    if not changed then
        for i, l in ipairs(lines) do
            if l ~= current[i] then changed = true; break end
        end
    end
    if changed then
        vim.api.nvim_buf_set_lines(shadow_buf, 0, -1, false, lines)
        vim.api.nvim_buf_call(shadow_buf, function()
            vim.cmd("silent! write!")
        end)
    end
    return changed
end

-- ── Public API ───────────────────────────────────────────────────────────────

-- Called on every render with the full parsed items list.
-- Creates/updates/removes shadow buffers and files as needed.
M.sync = function(md_buf, items)
    local md_path = vim.api.nvim_buf_get_name(md_buf)
    if md_path == "" then return end

    local md_dir  = vim.fn.fnamemodify(md_path, ":h")
    local md_stem = vim.fn.fnamemodify(md_path, ":t:r")
    md_stem = md_stem:gsub("[^%w%-]", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
    if md_stem == "" then md_stem = "unnamed" end
    local dir     = md_dir .. "/.mdrust/" .. md_stem

    -- Only handle rust editable blocks
    local editable = {}
    for _, item in ipairs(items) do
        if item.type == "code_block" and item.editable
                and item.lang == "rust" and item.block_id then
            editable[#editable + 1] = item
        end
    end

    if #editable == 0 then
        -- Nothing to do; clean up if we had state
        if M._state[md_buf] then M.forget(md_buf) end
        return
    end

    -- Ensure .mdrust/ directory exists
    if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
    end

    local state = M._state[md_buf] or { dir = dir, blocks = {} }
    M._state[md_buf] = state
    state.dir = dir

    -- Build set of current block IDs
    local current_ids = {}
    for _, item in ipairs(editable) do
        current_ids[item.block_id] = true
    end

    -- Remove stale blocks (blocks that no longer exist in the document)
    for id, bstate in pairs(state.blocks) do
        if not current_ids[id] then
            if vim.api.nvim_buf_is_valid(bstate.buf) then
                vim.api.nvim_buf_delete(bstate.buf, { force = true })
            end
            os.remove(bstate.path)
            state.blocks[id] = nil
        end
    end

    -- Create or update each block's shadow file
    local ordered_ids = {}
    for _, item in ipairs(editable) do
        local id    = item.block_id
        local path  = dir .. "/" .. id .. ".rs"
        local lines = get_block_lines(md_buf, item)

        if state.blocks[id] then
            -- Update existing
            sync_shadow_buf(state.blocks[id].buf, path, lines)
            state.blocks[id].fence_start_row = item.fence_start_row
            state.blocks[id].fence_end_row   = item.fence_end_row
        else
            -- New block
            local sbuf = create_shadow_buf(path, lines)
            state.blocks[id] = {
                buf             = sbuf,
                path            = path,
                fence_start_row = item.fence_start_row,
                fence_end_row   = item.fence_end_row,
            }
        end
        ordered_ids[#ordered_ids + 1] = id
    end

    -- Regenerate Cargo.toml whenever block set changes
    write_cargo_toml(dir, ordered_ids)
end

-- Return (block_id, local_row) for a given row in the markdown buffer.
-- Returns nil if the row is not inside an editable block.
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

-- Return the shadow buffer for a given block_id (or nil).
M.shadow_buf = function(md_buf, block_id)
    local state = M._state[md_buf]
    if not state or not block_id then return nil end
    local bstate = state.blocks[block_id]
    return bstate and bstate.buf or nil
end

-- Return the Cargo dir for a given markdown buffer (or nil).
M.mdrust_dir = function(md_buf)
    local state = M._state[md_buf]
    return state and state.dir or nil
end

M.forget = function(md_buf)
    local state = M._state[md_buf]
    if not state then return end
    for _, bstate in pairs(state.blocks) do
        if vim.api.nvim_buf_is_valid(bstate.buf) then
            pcall(vim.api.nvim_buf_delete, bstate.buf, { force = true })
        end
    end
    M._state[md_buf] = nil
end

return M
