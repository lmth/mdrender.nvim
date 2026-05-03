local M = {}
local bit = require("bit")

local function get_hl(name)
    return vim.api.nvim_get_hl(0, { name = name, link = false })
end

-- Linear RGB blend: alpha=1.0 → pure fg, alpha=0.0 → pure bg
local function blend(fg, bg, alpha)
    local function ch(a, b) return math.min(255, math.max(0, math.floor(a * alpha + b * (1 - alpha)))) end
    local fr = bit.band(bit.rshift(fg, 16), 0xff)
    local fg_ = bit.band(bit.rshift(fg, 8), 0xff)
    local fb  = bit.band(fg, 0xff)
    local br  = bit.band(bit.rshift(bg, 16), 0xff)
    local bg_ = bit.band(bit.rshift(bg, 8), 0xff)
    local bb  = bit.band(bg, 0xff)
    return bit.bor(bit.lshift(ch(fr, br), 16), bit.bor(bit.lshift(ch(fg_, bg_), 8), ch(fb, bb)))
end

M.setup = function()
    local normal_bg = get_hl("Normal").bg or 0x1e1e2e

    -- Headings: one hl group per level with a tinted background
    local heading_fgs = {
        get_hl("@markup.heading.1.markdown").fg or get_hl("Title").fg     or 0xe06c75,
        get_hl("@markup.heading.2.markdown").fg or get_hl("Function").fg  or 0xe5c07b,
        get_hl("@markup.heading.3.markdown").fg or get_hl("Statement").fg or 0x61afef,
        get_hl("@markup.heading.4.markdown").fg or get_hl("Type").fg      or 0x56b6c2,
        get_hl("@markup.heading.5.markdown").fg or get_hl("String").fg    or 0x98c379,
        get_hl("@markup.heading.6.markdown").fg or get_hl("Comment").fg   or 0xabb2bf,
    }

    for i, fg in ipairs(heading_fgs) do
        vim.api.nvim_set_hl(0, "MdRenderHeading"     .. i, { fg = fg, bg = blend(fg, normal_bg, 0.10), bold = true })
        vim.api.nvim_set_hl(0, "MdRenderHeadingSign" .. i, { fg = fg, bg = normal_bg })
    end

    -- Plain code block background
    local comment_fg = get_hl("Comment").fg or 0x5c6370
    local code_bg    = blend(comment_fg, normal_bg, 0.08)
    vim.api.nvim_set_hl(0, "MdRenderCode",      { bg = code_bg })
    vim.api.nvim_set_hl(0, "MdRenderCodeLabel", { fg = comment_fg, bg = code_bg, italic = true })

    -- Editable code block
    local border_fg = get_hl("FloatBorder").fg or comment_fg
    local func_fg   = get_hl("Function").fg    or 0x61afef
    local edit_bg   = blend(border_fg, normal_bg, 0.15)
    vim.api.nvim_set_hl(0, "MdRenderEditBorder", { fg = border_fg })
    vim.api.nvim_set_hl(0, "MdRenderEditLabel",  { fg = func_fg, bold = true })
    vim.api.nvim_set_hl(0, "MdRenderEditFill",   { bg = edit_bg })
end

return M
