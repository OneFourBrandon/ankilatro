local M = {}

local emphasis = {
    ["***"] = "bold_italic", ["___"] = "bold_italic",
    ["**"] = "bold", ["__"] = "bold",
    ["*"] = "italic", ["_"] = "italic", ["~~"] = "strike",
}

local function inline(text, styles, emit, depth, link)
    if depth == 8 then emit(text, styles, link); return end
    local pos, start = 1, 1
    while pos <= #text do
        local char = text:sub(pos, pos)
        local last, content, style, target
        if char == "\\" and text:sub(pos + 1, pos + 1):match("[%p]") then
            last, content = pos + 1, text:sub(pos + 1, pos + 1)
        elseif char == "`" then
            local ticks = text:match("^`+", pos)
            local first = pos + #ticks
            local close = text:find(ticks, first, true)
            while close and (text:sub(close - 1, close - 1) == "`" or text:sub(close + #ticks, close + #ticks) == "`") do
                close = text:find(ticks, close + 1, true)
            end
            if close then last, content, style = close + #ticks - 1, text:sub(first, close - 1), "code" end
        elseif char == "[" then
            local label, url, finish = text:match("^%[([^%[%]]+)%]%(([^%s%)]+)%)()", pos)
            if finish then last, content, style, target = finish - 1, label, "link", url end
        elseif char == "*" or char == "_" or char == "~" then
            local marker = text:match("^" .. char .. "+", pos)
            local first = pos + #marker
            if emphasis[marker] and not text:sub(first, first):match("%s") and
                (char ~= "_" or pos == 1 or not text:sub(pos - 1, pos - 1):match("[%w_]")) then
                local close = text:find(marker, first, true)
                while close do
                    local after = text:sub(close + #marker, close + #marker)
                    local before = text:sub(close - 1, close - 1)
                    if close > first and not before:match("[%s\\]") and
                        (before ~= char or not after:match("%w")) and
                        after ~= char and (char ~= "_" or not after:match("%w")) then
                        last, content, style = close + #marker - 1, text:sub(first, close - 1), emphasis[marker]
                        break
                    end
                    close = text:find(marker, close + 1, true)
                end
            end
            if not last then
                pos = first - 1
            end
        end

        if last then
            if start < pos then emit(text:sub(start, pos - 1), styles, link) end
            local nested = style and (styles .. " " .. style) or styles
            if style and style ~= "code" then
                inline(content, nested, emit, depth + 1, target or link)
            else
                emit(content, nested, link)
            end
            start, pos = last + 1, last
        end
        pos = pos + 1
    end
    if start <= #text then emit(text:sub(start), styles, link) end
end

-- Emit formatted runs and line breaks. Math regions are supplied as opaque
-- placeholders by the caller so TeX punctuation is never parsed as Markdown.
function M.runs(text, emit, line_break)
    local fence
    local first = true
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = line:gsub("\r$", "")
        local ticks = line:match("^%s*(```+)")
        if ticks and (not fence or (#ticks >= fence and line:match("^%s*`+%s*$"))) then
            if fence then fence = nil else fence = #ticks end
        else
            if not first then line_break() end
            first = false
            if fence then
                emit(line, "code")
            else
                local heading, title = line:match("^%s*(#+)%s+(.+)$")
                local quote = line:match("^%s*>%s?(.*)$")
                local bullet = line:match("^%s*[-+*]%s+(.+)$")
                local number, item = line:match("^%s*(%d+[.)])%s+(.+)$")
                if heading and #heading <= 6 then
                    inline(title:gsub("%s+#+%s*$", ""), "heading bold", emit, 0)
                elseif quote then
                    emit("> ", "quote")
                    inline(quote, "quote italic", emit, 0)
                elseif bullet then
                    emit("• ", "")
                    inline(bullet, "", emit, 0)
                elseif number then
                    emit(number .. " ", "")
                    inline(item, "", emit, 0)
                elseif line:match("^%s*%-%-%-+%s*$") or line:match("^%s*%*%*%*+%s*$") or line:match("^%s*___+%s*$") then
                    emit("────────", "quote")
                else
                    inline(line, "", emit, 0)
                end
            end
        end
    end
end

return M
