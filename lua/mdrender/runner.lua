-- runner.lua: compile and run a shadow .rs file, write output to the markdown buffer.
--
-- Writes two separate fences after the editable block:
--   ```output id=<id>   stdout (always written)
--   ```build  id=<id>   stderr / cargo build log (written only when non-empty)
--
-- The build fence is rendered collapsed by the renderer when exit_code == 0.

local M = {}

local shadow = require("mdrender.shadow")

-- ── Generic fence helpers ────────────────────────────────────────────────────

-- Find a fence of the form  ```<type> id=<id>  starting at or just after
-- search_from (allowing one blank line gap). Returns (start_row, end_row) or nil.
local function find_fence(md_buf, fence_type, block_id, search_from)
    local total = vim.api.nvim_buf_line_count(md_buf)
    if search_from >= total then return nil end

    local start_row = search_from
    local line = vim.api.nvim_buf_get_lines(md_buf, start_row, start_row + 1, false)[1] or ""
    if line == "" then
        start_row = start_row + 1
        if start_row >= total then return nil end
        line = vim.api.nvim_buf_get_lines(md_buf, start_row, start_row + 1, false)[1] or ""
    end

    local pattern = "^%s*```+" .. fence_type .. "%s+id=" .. vim.pesc(block_id) .. "%s*$"
    if not line:match(pattern) then return nil end

    for r = start_row + 1, total - 1 do
        local l = vim.api.nvim_buf_get_lines(md_buf, r, r + 1, false)[1] or ""
        if l:match("^%s*```+%s*$") then
            return start_row, r
        end
    end
    return nil
end

-- Insert or replace a fence. Returns the end_row of the written fence.
local function write_fence(md_buf, fence_type, block_id, after_row, new_lines)
    local fs_row, fe_row = find_fence(md_buf, fence_type, block_id, after_row + 1)
    if fs_row then
        vim.api.nvim_buf_set_lines(md_buf, fs_row, fe_row + 1, false, new_lines)
        return fs_row + #new_lines - 1
    else
        local insert_at = after_row + 1
        local to_insert = { "" }
        vim.list_extend(to_insert, new_lines)
        vim.api.nvim_buf_set_lines(md_buf, insert_at, insert_at, false, to_insert)
        return insert_at + #new_lines   -- blank line + new_lines; closing ``` is last
    end
end

-- Delete a fence (and its preceding blank line) if it exists.
local function delete_fence(md_buf, fence_type, block_id, after_row)
    local fs_row, fe_row = find_fence(md_buf, fence_type, block_id, after_row + 1)
    if not fs_row then return end
    local del_start = fs_row
    if fs_row > 0 then
        local prev = vim.api.nvim_buf_get_lines(md_buf, fs_row - 1, fs_row, false)[1] or ""
        if prev == "" then del_start = fs_row - 1 end
    end
    vim.api.nvim_buf_set_lines(md_buf, del_start, fe_row + 1, false, {})
end

-- ── Fence builders ───────────────────────────────────────────────────────────

local function build_output_fence(block_id, stdout, exit_code)
    local ts    = os.date("%Y-%m-%d %H:%M:%S")
    local lines = { "```output id=" .. block_id }
    lines[#lines + 1] = "-- exit " .. exit_code .. "  |  " .. ts
    if #stdout > 0 then
        for _, l in ipairs(stdout) do lines[#lines + 1] = l end
    else
        lines[#lines + 1] = "(no output)"
    end
    lines[#lines + 1] = "```"
    return lines
end

local function build_build_fence(block_id, stderr, exit_code)
    local ts    = os.date("%Y-%m-%d %H:%M:%S")
    local lines = { "```build id=" .. block_id }
    lines[#lines + 1] = "-- exit " .. exit_code .. "  |  " .. ts
    for _, l in ipairs(stderr) do lines[#lines + 1] = l end
    lines[#lines + 1] = "```"
    return lines
end

-- ── Runner ───────────────────────────────────────────────────────────────────

M.run = function(md_buf)
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1

    local state = shadow._state[md_buf]
    if not state then
        vim.notify("mdrender: no shadow state for this buffer", vim.log.levels.WARN)
        return
    end

    local block_id
    for id, bstate in pairs(state.blocks) do
        local s = bstate.fence_start_row
        local e = bstate.fence_end_row
        if s and e and row >= s and row <= e then
            block_id = id
            break
        end
    end

    if not block_id then
        vim.notify("mdrender: cursor not on an editable rust block", vim.log.levels.INFO)
        return
    end

    -- Ensure shadow buf exists so cargo can compile (file already on disk)
    shadow.ensure_buf(md_buf, block_id)

    local dir = state.dir
    vim.notify("mdrender: running " .. block_id .. " …", vim.log.levels.INFO)

    local stdout_lines = {}
    local stderr_lines = {}

    local function on_stdout(_, data)
        for _, l in ipairs(data or {}) do stdout_lines[#stdout_lines + 1] = l end
        if stdout_lines[#stdout_lines] == "" then stdout_lines[#stdout_lines] = nil end
    end
    local function on_stderr(_, data)
        for _, l in ipairs(data or {}) do stderr_lines[#stderr_lines + 1] = l end
        if stderr_lines[#stderr_lines] == "" then stderr_lines[#stderr_lines] = nil end
    end

    local job_id = vim.fn.jobstart(
        { "cargo", "run", "--bin", block_id },
        {
            cwd             = dir,
            stdout_buffered = true,
            stderr_buffered = true,
            on_stdout       = on_stdout,
            on_stderr       = on_stderr,
            on_exit         = function(_, exit_code)
                vim.schedule(function()
                    if not vim.api.nvim_buf_is_valid(md_buf) then return end

                    -- Re-resolve block position (document may have changed)
                    local cur_state = shadow._state[md_buf]
                    if not cur_state or not cur_state.blocks[block_id] then
                        vim.notify("mdrender: block " .. block_id .. " no longer exists", vim.log.levels.WARN)
                        return
                    end
                    local editable_end = cur_state.blocks[block_id].fence_end_row

                    -- Write output fence (stdout)
                    local out_lines = build_output_fence(block_id, stdout_lines, exit_code)
                    local out_end   = write_fence(md_buf, "output", block_id, editable_end, out_lines)

                    -- Write or delete build fence (stderr / cargo log)
                    if #stderr_lines > 0 then
                        local bld_lines = build_build_fence(block_id, stderr_lines, exit_code)
                        write_fence(md_buf, "build", block_id, out_end, bld_lines)
                    else
                        delete_fence(md_buf, "build", block_id, out_end)
                    end

                    if exit_code == 0 then
                        vim.notify("mdrender: " .. block_id .. " finished OK", vim.log.levels.INFO)
                    else
                        vim.notify("mdrender: " .. block_id .. " exited " .. exit_code, vim.log.levels.WARN)
                    end
                end)
            end,
        }
    )
    if job_id <= 0 then
        vim.notify("mdrender: failed to start cargo (job_id=" .. job_id .. ")", vim.log.levels.ERROR)
    end
end

return M
