--[[--
JSON formatter for myexport plugin.

Serializes a table of booknotes to a JSON string.
Uses an inline, dependency-free JSON serializer — no rapidjson required.

@module koplugin.myexport.formatter.json
--]]--

local JsonFormatter = {}

-- ---------------------------------------------------------------------------
-- Minimal JSON serializer
-- ---------------------------------------------------------------------------

local function escape_str(s)
    s = tostring(s)
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"',  '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    -- escape control characters
    s = s:gsub("[%z\1-\31]", function(c)
        return string.format("\\u%04x", c:byte())
    end)
    return s
end

local serialize  -- forward declaration

local function serialize_table(t, indent)
    -- Detect array vs object: an array has only consecutive integer keys from 1
    local is_array = true
    local max_n = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
            is_array = false
            break
        end
        if k > max_n then max_n = k end
    end
    if is_array and max_n ~= #t then is_array = false end

    local pad  = string.rep("  ", indent)
    local pad1 = string.rep("  ", indent + 1)

    if is_array then
        if #t == 0 then return "[]" end
        local parts = {}
        for _, v in ipairs(t) do
            table.insert(parts, pad1 .. serialize(v, indent + 1))
        end
        return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
    else
        local keys = {}
        for k in pairs(t) do
            if type(k) == "string" or type(k) == "number" then
                table.insert(keys, k)
            end
        end
        table.sort(keys, function(a, b)
            return tostring(a) < tostring(b)
        end)
        if #keys == 0 then return "{}" end
        local parts = {}
        for _, k in ipairs(keys) do
            local v = t[k]
            if v ~= nil then
                table.insert(parts,
                    pad1 .. '"' .. escape_str(k) .. '": ' .. serialize(v, indent + 1))
            end
        end
        if #parts == 0 then return "{}" end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
    end
end

serialize = function(v, indent)
    indent = indent or 0
    local t = type(v)
    if t == "nil"     then return "null"
    elseif t == "boolean" then return tostring(v)
    elseif t == "number"  then
        if v ~= v then return "null" end  -- NaN
        return string.format(v == math.floor(v) and "%d" or "%.10g", v)
    elseif t == "string"  then return '"' .. escape_str(v) .. '"'
    elseif t == "table"   then return serialize_table(v, indent)
    else                       return '"' .. escape_str(tostring(v)) .. '"'
    end
end

-- ---------------------------------------------------------------------------
-- Formatter logic
-- ---------------------------------------------------------------------------

--- Format a list of booknotes into a JSON string.
-- @param clippings  table: { [title] = booknotes } or list of booknotes
-- @return string    pretty-printed JSON
function JsonFormatter:format(clippings)
    -- Collect booknotes into an ordered list
    local books = {}
    for _, book in pairs(clippings) do
        table.insert(books, book)
    end
    -- Sort by title for deterministic output
    table.sort(books, function(a, b)
        return (a.title or "") < (b.title or "")
    end)

    local function format_book(book)
        local entries = {}
        for _, chapter_group in ipairs(book) do
            for _, clipping in ipairs(chapter_group) do
                local entry = {
                    page      = clipping.page,
                    timestamp = clipping.time,
                    style     = clipping.drawer,
                    chapter   = clipping.chapter,
                    text      = clipping.text,
                    note      = clipping.note,
                }
                -- remove nil fields (serialize will emit "null" for nil;
                -- we prefer to omit them entirely)
                local clean = {}
                for k, v in pairs(entry) do
                    if v ~= nil and v ~= "" then
                        clean[k] = v
                    end
                end
                table.insert(entries, clean)
            end
        end
        return {
            title   = book.title,
            author  = book.author,
            file    = book.file,
            entries = entries,
        }
    end

    local output
    if #books == 1 then
        output = format_book(books[1])
        output.exported_at = os.date("%Y-%m-%dT%H:%M:%S")
    else
        local docs = {}
        for _, book in ipairs(books) do
            table.insert(docs, format_book(book))
        end
        output = {
            exported_at = os.date("%Y-%m-%dT%H:%M:%S"),
            documents   = docs,
        }
    end

    return serialize(output, 0) .. "\n"
end

return JsonFormatter
