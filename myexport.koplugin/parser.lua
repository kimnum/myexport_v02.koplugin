--[[--
Parser for KOReader highlights and annotations.

Reads annotations from the currently open document or from the reading history.
Supports both the modern `annotations` table and the legacy `highlight`/`bookmarks`
tables found in older .sdr files. Every filesystem access is wrapped in pcall to
prevent crashes caused by missing or corrupted sidecar files.

@module koplugin.myexport.parser
--]]--

local BookList     = require("ui/widget/booklist")
local logger       = require("logger")
local T            = require("ffi/util").template
local _            = require("gettext")

local Parser = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function trim(s)
    if type(s) ~= "string" then return "" end
    return s:match("^%s*(.-)%s*$") or ""
end

--- Parse a datetime string as used by KOReader ("YYYY-MM-DD HH:MM:SS").
-- Returns a Unix timestamp, or nil if parsing fails.
local function parseTime(dt)
    if not dt then return nil end
    local y, mo, d, h, mi, s = dt:match("(%d%d%d%d)-(%d%d)-(%d%d) (%d%d):(%d%d):(%d%d)")
    if y then
        return os.time({ year=y, month=mo, day=d, hour=h, min=mi, sec=s })
    end
    return nil
end

--- Try to extract title and author from document properties + filepath.
local function getTitleAuthor(filepath, props)
    props = props or {}
    local title  = trim(props.title)
    local author = trim(props.authors or props.author)

    if title == "" then
        -- fallback: use filename without extension
        local basename = filepath:match(".+/(.+)$") or filepath
        title = basename:match("^(.+)%.[^%.]+$") or basename
    end
    if author == "" then author = _("Unknown Author") end
    return title, author
end

--- Build the canonical booknotes table from the modern `annotations` list.
local function parseAnnotations(annotations, book)
    if type(annotations) ~= "table" then return end
    for _, item in ipairs(annotations) do
        if item.drawer then          -- only real highlights (not pure bookmarks)
            local clipping = {
                sort    = "highlight",
                page    = item.pageref or item.pageno,
                time    = parseTime(item.datetime),
                text    = trim(item.text),
                note    = item.note and trim(item.note) or nil,
                chapter = item.chapter,
                drawer  = item.drawer,
                color   = item.color,
            }
            -- skip empty entries
            if clipping.text ~= "" or clipping.note then
                table.insert(book, { clipping })
            end
        end
    end
end

--- Build the canonical booknotes table from the legacy `highlight`/`bookmarks` tables.
local function parseLegacyHighlights(highlights, bookmarks, book)
    if type(highlights) ~= "table" then return end
    bookmarks = bookmarks or {}

    -- Build a quick lookup: bookmark datetime → note text
    local bm_notes = {}
    for _, bm in ipairs(bookmarks) do
        if bm.datetime and bm.text then
            bm_notes[bm.datetime] = bm.text
        end
    end

    for page, items in pairs(highlights) do
        for _, item in ipairs(items) do
            local clipping = {
                sort    = "highlight",
                page    = page,
                time    = parseTime(item.datetime),
                text    = trim(item.text),
                note    = nil,
                chapter = item.chapter,
                drawer  = item.drawer,
                color   = item.color,
            }
            -- attach note from matching bookmark, if any
            if item.datetime and bm_notes[item.datetime] then
                local bm_text = bm_notes[item.datetime]
                -- avoid duplicating the highlight text itself
                if bm_text ~= clipping.text then
                    clipping.note = bm_text
                end
            end
            if clipping.text ~= "" then
                table.insert(book, { clipping })
            end
        end
    end
end

--- Populate a booknotes table from a book's sidecar settings.
-- @param book  the table to fill (must already have .file, .title, .author set)
-- @param doc_settings  DocSettings object for the book
local function fillBookFromSettings(book, doc_settings)
    local ok, annotations = pcall(function()
        return doc_settings:readSetting("annotations")
    end)
    if ok and annotations then
        parseAnnotations(annotations, book)
        return
    end

    -- fallback to legacy tables
    local ok2, highlights = pcall(function()
        return doc_settings:readSetting("highlight")
    end)
    local ok3, bookmarks = pcall(function()
        return doc_settings:readSetting("bookmarks")
    end)
    if ok2 and highlights then
        parseLegacyHighlights(highlights, ok3 and bookmarks or {}, book)
    end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Parse annotations from the currently open document (inside the Reader).
-- @param ui  the ReaderUI instance
-- @return table  clippings = { [title] = booknotes }
function Parser:parseCurrentDoc(ui)
    local clippings = {}
    if not ui or not ui.document then
        logger.warn("myexport: parseCurrentDoc called with nil ui/document")
        return clippings
    end

    local filepath = ui.document.file
    local props    = ui.doc_props or {}
    local title, author = getTitleAuthor(filepath, props)

    local book = {
        file   = filepath,
        title  = title,
        author = author,
        pages  = ui.view and ui.view.footer and ui.view.footer.pages or nil,
    }

    -- modern API
    if ui.annotation and ui.annotation.annotations then
        parseAnnotations(ui.annotation.annotations, book)
    elseif ui.highlight and ui.highlight.highlight then
        -- very old KOReader API
        parseLegacyHighlights(ui.highlight.highlight, ui.bookmark and ui.bookmark.bookmarks or {}, book)
    end

    if #book > 0 then
        clippings[title] = book
    end
    return clippings
end

--- Parse annotations for all books in reading history.
-- Books whose sidecar cannot be read are silently skipped.
-- @return table  clippings = { [title] = booknotes }
function Parser:parseHistory()
    local clippings = {}
    local ok, hist = pcall(function()
        return require("readhistory").hist
    end)
    if not ok or not hist then
        logger.warn("myexport: cannot read history")
        return clippings
    end

    for _, item in ipairs(hist) do
        if not item.dim and item.file then
            local file = item.file
            -- Check whether a sidecar exists at all
            local has_sdr = pcall(function()
                return BookList.hasBookBeenOpened(file)
            end)
            if has_sdr then
                local ok2, doc_settings = pcall(function()
                    return BookList.getDocSettings(file)
                end)
                if ok2 and doc_settings then
                    local ok3, props = pcall(function()
                        return doc_settings:readSetting("doc_props") or {}
                    end)
                    local props_val = ok3 and props or {}
                    local title, author = getTitleAuthor(file, props_val)
                    local book = {
                        file   = file,
                        title  = title,
                        author = author,
                        pages  = nil,
                    }
                    local fill_ok, fill_err = pcall(fillBookFromSettings, book, doc_settings)
                    if not fill_ok then
                        logger.warn("myexport: error reading", file, fill_err)
                    end
                    if #book > 0 then
                        clippings[title] = book
                    end
                end
            end
        end
    end
    return clippings
end

return Parser
