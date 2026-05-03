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

-- Ensure the otter shadow file is registered in ~/Cargo.toml as a [[bin]]
-- target so rust-analyzer can analyze it. Safe to call multiple times.
local function register_rust_shadow(buf)
    local buf_path = vim.api.nvim_buf_get_name(buf)
    local shadow_path = buf_path .. ".otter.rs"
    local cargo_path = vim.fn.expand("~/Cargo.toml")
    if vim.fn.filereadable(cargo_path) == 0 then return end

    local content = table.concat(vim.fn.readfile(cargo_path), "\n")
    -- derive a valid Rust identifier from the shadow path
    local rel = vim.fn.fnamemodify(shadow_path, ":t:r")  -- basename minus .rs
    local bin_name = rel:gsub("[^%w]", "_")

    if content:find(bin_name, 1, true) then return end  -- already registered

    local entry = string.format(
        '\n[[bin]]\nname = "%s"\npath = "%s"\n',
        bin_name,
        vim.fn.fnamemodify(shadow_path, ":t")
    )
    local f = io.open(cargo_path, "a")
    if f then
        f:write(entry)
        f:close()
        -- Restart rust-analyzer so it picks up the new target
        vim.defer_fn(function()
            for _, c in ipairs(vim.lsp.get_clients()) do
                if c.name == "rust_analyzer" then
                    c:stop()
                end
            end
        end, 200)
    end
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

    -- Ensure rust shadow files are registered in ~/Cargo.toml
    for _, lang in ipairs(langs) do
        if lang == "rust" then
            register_rust_shadow(buf)
            break
        end
    end
end

M.forget = function(buf)
    M._state[buf] = nil
end

return M
