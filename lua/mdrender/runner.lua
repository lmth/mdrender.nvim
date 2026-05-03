-- runner.lua: compile and run a shadow .rs file, write output to the markdown buffer.
--
-- Finds the editable block at the cursor, runs `cargo run --bin <id>` in the
-- .mdrust/ directory, and writes/updates an ```output id=<id>``` fence
-- immediately after the editable block's closing fence.

local M = {}

local shadow = require("mdrender.shadow")

-- ── Output fence helpers ─────────────────────────────────────────────────────

-- Find an existing ```output id=<id>``` fence that starts immediately after
-- the editable block's closing fence. Returns (start_row, end_row) of the
-- fence (inclusive, 0-indexed), or nil if not found.
local function find_output_fence(md_buf, block_id, editable_end_row)
    -- The output fence starts on editable_end_row + 1 at the earliest.
    local total = vim.api.nvim_buf_line_count(md_buf)
    local search_from = editable_end_row + 1
    if search_from >= total then return nil end

    -- Allow one blank line between editable end and output fence
    local start_row = search_from
    local line = vim.api.nvim_buf_get_lines(md_buf, start_row, start_row + 1, false)[1] or ""
    if line == "" then
        start_row = start_row + 1
        if start_row >= total then return nil end
        line = vim.api.nvim_buf_get_lines(md_buf, start_row, start_row + 1, false)[1] or ""
    end

    -- Check for ```output id=<id> opening fence
    local fence_pattern = "^%s*```+output%s+id=" .. vim.pesc(block_id) .. "%s*$"
    if not line:match(fence_pattern) then return nil end

    -- Find the closing fence
    for r = start_row + 1, total - 1 do
        local l = vim.api.nvim_buf_get_lines(md_buf, r, r + 1, false)[1] or ""
        if l:match("^%s*```+%s*$") then
            return start_row, r
        end
    end
    return nil
end

-- Build the lines that go inside (and including) the output fence.
local function build_output_fence(block_id, stdout, stderr, exit_code)
    local lines = {}
    lines[#lines + 1] = "```output id=" .. block_id
    -- Header line: exit status + timestamp
    local ts = os.date("%Y-%m-%d %H:%M:%S")
    if exit_code == 0 then
        lines[#lines + 1] = "-- exit 0  |  " .. ts
    else
        lines[#lines + 1] = "-- exit " .. exit_code .. "  |  " .. ts
    end
    if #stdout > 0 then
        for _, l in ipairs(stdout) do lines[#lines + 1] = l end
    end
    if #stderr > 0 then
        if #stdout > 0 then lines[#lines + 1] = "-- stderr:" end
        for _, l in ipairs(stderr) do lines[#lines + 1] = l end
    end
    if #stdout == 0 and #stderr == 0 then
        lines[#lines + 1] = "(no output)"
    end
    lines[#lines + 1] = "```"
    return lines
end

-- Insert or replace the output fence for a block.
local function write_output_fence(md_buf, block_id, editable_end_row, new_lines)
    local os_row, oe_row = find_output_fence(md_buf, block_id, editable_end_row)
    if os_row then
        -- Replace existing fence
        vim.api.nvim_buf_set_lines(md_buf, os_row, oe_row + 1, false, new_lines)
    else
        -- Insert after editable block (with a blank line separator)
        local insert_at = editable_end_row + 1
        local to_insert = { "" }
        vim.list_extend(to_insert, new_lines)
        vim.api.nvim_buf_set_lines(md_buf, insert_at, insert_at, false, to_insert)
    end
end

-- ── Runner ───────────────────────────────────────────────────────────────────

M.run = function(md_buf)
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-indexed

    -- Find which block the cursor is in (or on its fence)
    local state = shadow._state[md_buf]
    if not state then
        vim.notify("mdrender: no shadow state for this buffer", vim.log.levels.WARN)
        return
    end

    -- Also allow cursor on the fence lines themselves
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

    local dir = state.dir
    vim.notify("mdrender: running " .. block_id .. " …", vim.log.levels.INFO)

    -- Run asynchronously
    local stdout_lines = {}
    local stderr_lines = {}

    local function on_stdout(_, data)
        for _, l in ipairs(data or {}) do
            stdout_lines[#stdout_lines + 1] = l
        end
        -- jobstart appends a trailing "" sentinel; remove it
        if stdout_lines[#stdout_lines] == "" then
            stdout_lines[#stdout_lines] = nil
        end
    end
    local function on_stderr(_, data)
        for _, l in ipairs(data or {}) do
            stderr_lines[#stderr_lines + 1] = l
        end
        if stderr_lines[#stderr_lines] == "" then
            stderr_lines[#stderr_lines] = nil
        end
    end

    local job_id = vim.fn.jobstart(
        { "cargo", "run", "--bin", block_id },
        {
            cwd        = dir,
            stdout_buffered = true,
            stderr_buffered = true,
            on_stdout  = on_stdout,
            on_stderr  = on_stderr,
            on_exit    = function(_, exit_code)
                vim.schedule(function()
                    if not vim.api.nvim_buf_is_valid(md_buf) then return end
                    -- Re-resolve the block's end row in case the document was edited
                    -- while cargo was running
                    local current_state = shadow._state[md_buf]
                    if not current_state or not current_state.blocks[block_id] then
                        vim.notify("mdrender: block " .. block_id .. " no longer exists", vim.log.levels.WARN)
                        return
                    end
                    local current_end = current_state.blocks[block_id].fence_end_row
                    local fence_lines = build_output_fence(
                        block_id, stdout_lines, stderr_lines, exit_code
                    )
                    write_output_fence(md_buf, block_id, current_end, fence_lines)
                    if exit_code == 0 then
                        vim.notify("mdrender: " .. block_id .. " finished OK", vim.log.levels.INFO)
                    else
                        vim.notify(
                            "mdrender: " .. block_id .. " exited " .. exit_code,
                            vim.log.levels.WARN
                        )
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
