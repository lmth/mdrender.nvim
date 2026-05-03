local M = {}

-- Track which (buf, languages) have already been activated to avoid
-- redundant otter.activate() calls.
---@type table<integer, string>
M._state = {}

-- Return sorted unique languages from editable code blocks.
local function editable_langs(items)
    local seen  = {}
    local langs = {}
    for _, item in ipairs(items) do
        if item.type == "code_block" and item.editable and item.lang ~= "" then
            if not seen[item.lang] then
                seen[item.lang] = true
                table.insert(langs, item.lang)
            end
        end
    end
    table.sort(langs)
    return langs
end

-- Activate otter for any editable languages found in `items`.
-- Safe to call repeatedly — skips if language set is unchanged.
M.activate = function(buf, items)
    local ok, otter = pcall(require, "otter")
    if not ok then return end  -- otter not installed, silently skip

    local langs = editable_langs(items)
    if #langs == 0 then return end

    local key = table.concat(langs, ",")
    if M._state[buf] == key then return end  -- nothing changed
    M._state[buf] = key

    -- otter.activate() uses nvim_get_current_buf() internally,
    -- so we must call it in the context of the target buffer.
    vim.api.nvim_buf_call(buf, function()
        pcall(otter.activate, langs, true, true, nil)
    end)
end

M.forget = function(buf)
    M._state[buf] = nil
end

return M
