--[[--
My Annotation Exporter – main plugin file.

A lightweight KOReader plugin to export highlights and annotations to
JSON, Markdown or plain text. Works both inside a book (Reader) and
from the file manager (for all books in history).

Features:
  - Zero network, zero external dependencies
  - Lazy-loads formatters only when needed
  - Every filesystem access is wrapped in pcall (no crashes)
  - Supports modern `annotations` table and legacy `highlight` table
  - Registerable as Dispatcher actions (gesture / profiles compatible)

@module koplugin.myexport
--]]--

local DataStorage     = require("datastorage")
local Dispatcher      = require("dispatcher")
local InfoMessage     = require("ui/widget/infomessage")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local ffiUtil         = require("ffi/util")
local logger          = require("logger")
local T               = ffiUtil.template
local _               = require("gettext")

-- Plugin class
local MyExport = WidgetContainer:extend{
    name        = "myexport",
    -- default output directory: koreader/clipboard/
    default_dir = DataStorage:getFullDataDir() .. "/clipboard",
}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function MyExport:init()
    self.settings = G_reader_settings:readSetting("myexport") or {}
    self.parser   = require("parser")
    self.ui.menu:registerToMainMenu(self)
    -- KOReader pattern: dispatcher registration via DispatcherRegisterActions event
    self:onDispatcherRegisterActions()
end

-- ---------------------------------------------------------------------------
-- Dispatcher actions
-- 6 separate events, category="none" (simple fire-and-forget).
-- ---------------------------------------------------------------------------

function MyExport:onDispatcherRegisterActions()
    Dispatcher:registerAction("myexport_current_json", {
        category = "none", event = "MyExportCurrentJson",
        title    = _("MyExport: export current book as JSON"),
        reader   = true,
    })
    Dispatcher:registerAction("myexport_current_md", {
        category = "none", event = "MyExportCurrentMd",
        title    = _("MyExport: export current book as Markdown"),
        reader   = true,
    })
    Dispatcher:registerAction("myexport_current_txt", {
        category = "none", event = "MyExportCurrentTxt",
        title    = _("MyExport: export current book as plain text"),
        reader   = true,
    })
    Dispatcher:registerAction("myexport_all_json", {
        category    = "none", event = "MyExportAllJson",
        title       = _("MyExport: export all books as JSON"),
        reader      = true, filemanager = true,
    })
    Dispatcher:registerAction("myexport_all_md", {
        category    = "none", event = "MyExportAllMd",
        title       = _("MyExport: export all books as Markdown"),
        reader      = true, filemanager = true,
    })
    Dispatcher:registerAction("myexport_all_txt", {
        category    = "none", event = "MyExportAllTxt",
        title       = _("MyExport: export all books as plain text"),
        reader      = true, filemanager = true,
    })
end

-- Event handlers called by the Dispatcher
function MyExport:onMyExportCurrentJson()  self:doExport("json",     "current") end
function MyExport:onMyExportCurrentMd()    self:doExport("markdown", "current") end
function MyExport:onMyExportCurrentTxt()   self:doExport("text",     "current") end
function MyExport:onMyExportAllJson()      self:doExport("json",     "all")     end
function MyExport:onMyExportAllMd()        self:doExport("markdown", "all")     end
function MyExport:onMyExportAllTxt()       self:doExport("text",     "all")     end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- True when inside an open book with at least one annotation.
function MyExport:hasCurrentDoc()
    if not self.document then return false end
    if self.ui.annotation and type(self.ui.annotation.annotations) == "table" then
        return #self.ui.annotation.annotations > 0
    end
    if self.ui.highlight and type(self.ui.highlight.highlight) == "table" then
        return next(self.ui.highlight.highlight) ~= nil
    end
    return false
end

local function fileExists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

local function ensureDir(dir)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
end

local function writeFile(path, content)
    local ok, err = pcall(function()
        ensureDir(path:match("(.+)/[^/]+$") or ".")
        local f = assert(io.open(path, "w"), "cannot open " .. path)
        f:write(content)
        f:close()
    end)
    return ok, ok and path or tostring(err)
end

local EXT = { json = "json", markdown = "md", text = "txt" }

function MyExport:buildFilePath(dir, basename, ext)
    basename = basename:gsub("[/\\:*?\"<>|]", "_"):sub(1, 120)
    local path = dir .. "/" .. basename .. "." .. ext
    if self.settings.overwrite then return path end
    if not fileExists(path) then return path end
    local n = 1
    repeat
        path = dir .. "/" .. basename .. "_" .. n .. "." .. ext
        n = n + 1
    until not fileExists(path) or n > 999
    return path
end

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

function MyExport:addToMainMenu(menu_items)
    menu_items.myexport = {
        text = _("Export annotations"),
        sub_item_table = {
            {
                text         = _("Export current book"),
                enabled_func = function() return self:hasCurrentDoc() end,
                sub_item_table = {
                    { text = _("JSON (.json)"),    callback = function() self:doExport("json",     "current") end },
                    { text = _("Markdown (.md)"),  callback = function() self:doExport("markdown", "current") end },
                    { text = _("Plain text (.txt)"),callback = function() self:doExport("text",    "current") end },
                },
            },
            {
                text = _("Export all books (history)"),
                sub_item_table = {
                    { text = _("JSON (.json)"),    callback = function() self:doExport("json",     "all") end },
                    { text = _("Markdown (.md)"),  callback = function() self:doExport("markdown", "all") end },
                    { text = _("Plain text (.txt)"),callback = function() self:doExport("text",    "all") end },
                },
                separator = true,
            },
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text           = _("Choose export folder"),
                        keep_menu_open = true,
                        callback       = function() self:chooseFolder() end,
                    },
                    {
                        text         = _("Include page number"),
                        checked_func = function() return self.settings.incl_page ~= false end,
                        callback     = function()
                            self.settings.incl_page = not (self.settings.incl_page ~= false)
                            self:saveSettings()
                        end,
                    },
                    {
                        text         = _("Include timestamp"),
                        checked_func = function() return self.settings.incl_time ~= false end,
                        callback     = function()
                            self.settings.incl_time = not (self.settings.incl_time ~= false)
                            self:saveSettings()
                        end,
                    },
                    {
                        text         = _("Overwrite existing files"),
                        checked_func = function() return self.settings.overwrite == true end,
                        callback     = function()
                            self.settings.overwrite = not self.settings.overwrite
                            self:saveSettings()
                        end,
                    },
                },
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

function MyExport:saveSettings()
    G_reader_settings:saveSetting("myexport", self.settings)
end

function MyExport:chooseFolder()
    filemanagerutil.showChooseDialog(
        _("Current export folder:"),
        function(path)
            self.settings.output_dir = path
            self:saveSettings()
        end,
        self.settings.output_dir,
        self.default_dir
    )
end

-- ---------------------------------------------------------------------------
-- Core export
-- ---------------------------------------------------------------------------

function MyExport:doExport(format, scope)
    -- 1. Parse
    local ok, clippings = pcall(function()
        if scope == "current" then
            return self.parser:parseCurrentDoc(self.ui)
        else
            return self.parser:parseHistory()
        end
    end)
    if not ok then
        logger.warn("myexport parse error:", clippings)
        UIManager:show(InfoMessage:new{ text = T(_("Export failed:\n%1"), tostring(clippings)) })
        return
    end

    local count = 0
    for _, book in pairs(clippings) do
        if #book > 0 then count = count + 1 end
    end
    if count == 0 then
        UIManager:show(InfoMessage:new{ text = _("No annotations to export.") })
        return
    end

    -- 2. Non-blocking feedback
    UIManager:show(InfoMessage:new{ text = _("Exporting annotations…"), timeout = 1 })

    -- 3. Deferred work
    UIManager:nextTick(function()
        local ok2, fmt = pcall(require, "formatter/" .. format)
        if not ok2 then
            UIManager:show(InfoMessage:new{
                text = T(_("Cannot load formatter '%1'."), format) })
            return
        end

        local options = {
            incl_page  = self.settings.incl_page ~= false,
            incl_time  = self.settings.incl_time ~= false,
            incl_style = true,
        }
        local ok3, content = pcall(function() return fmt:format(clippings, options) end)
        if not ok3 then
            logger.warn("myexport format error:", content)
            UIManager:show(InfoMessage:new{
                text = T(_("Formatting error:\n%1"), tostring(content)) })
            return
        end

        local dir  = self.settings.output_dir or self.default_dir
        local ext  = EXT[format] or format
        local base
        if count == 1 then
            for _, book in pairs(clippings) do
                base = (book.title or "export"):sub(1, 80)
                break
            end
        else
            base = "all-books-" .. os.date("%Y%m%d-%H%M%S")
        end
        local path    = self:buildFilePath(dir, base, ext)
        local ok4, result = writeFile(path, content)
        UIManager:show(InfoMessage:new{
            text = ok4
                and T(_("Exported to:\n%1"), result)
                or  T(_("Write error:\n%1"), result),
        })
        if not ok4 then logger.warn("myexport write error:", result) end
    end)
end

return MyExport
