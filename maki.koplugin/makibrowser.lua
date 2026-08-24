local BD = require("ui/bidi")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local Cache = require("cache")
local CheckButton = require("ui/widget/checkbutton")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local DownloadMgr = require("ui/downloadmgr")
local Notification = require("ui/widget/notification")
local OPDSParser = require("makiparser")
local Marker = require("makimarker")
local OPDSPSE = require("makipse")
local MakiHTTP = require("makihttp")
local MakiBulk = require("makibulk")
local MakiNames = require("makinames")
local SpinWidget = require("ui/widget/spinwidget")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local http = require("socket.http")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local time = require("ui/time")
local url = require("socket.url")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = ffiUtil.template

-- cache catalog parsed from feed xml
local CatalogCache = Cache:new{
    -- Make it 20 slots, with no storage space constraints
    slots = 20,
}

-- Maki: decode percent-escapes (%20, %23, …) in a string.
local function percent_decode(s)
    if not s then return s end
    return (s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

-- Maki: sanitize a single path segment for filesystem use.
-- Used by both the long-press bulk walker and the single-tap download path.
local function sanitize_segment(name)
    if not name or name == "" then return "Untitled" end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("[/\\%z%c]", "_")
    name = name:gsub("[<>:\"|%?%*]", "_")
    if name == "" or name == "." or name == ".." then return "Untitled" end
    return name
end

local OPDSBrowser = Menu:extend{
    catalog_type         = "application/atom%+xml",
    search_type          = "application/opensearchdescription%+xml",
    search_template_type = "application/atom%+xml",
    acquisition_rel      = "^http://opds%-spec%.org/acquisition",
    borrow_rel           = "http://opds-spec.org/acquisition/borrow",
    stream_rel           = "http://vaemendis.net/opds-pse/stream",
    facet_rel            = "http://opds-spec.org/facet",
    image_rel            = {
        ["http://opds-spec.org/image"] = true,
        ["http://opds-spec.org/cover"] = true, -- ManyBooks.net, not in spec
        ["x-stanza-cover-image"] = true,
    },
    thumbnail_rel        = {
        ["http://opds-spec.org/image/thumbnail"] = true,
        ["http://opds-spec.org/thumbnail"] = true, -- ManyBooks.net, not in spec
        ["x-stanza-cover-image-thumbnail"] = true,
    },

    root_catalog_title    = nil,
    root_catalog_username = nil,
    root_catalog_password = nil,
    facet_groups          = nil, -- Stores OPDS facet groups

    title_shrink_font_to_fit = true,
}

function OPDSBrowser:init()
    self.item_table = self:genItemTableFromRoot()
    self.catalog_title = nil
    self.title_bar_left_icon = "appbar.menu"
    self.onLeftButtonTap = function()
        self:showOPDSMenu()
    end
    self.facet_groups = nil -- Initialize facet groups storage
    Menu.init(self) -- call parent's init()
end

function OPDSBrowser:showOPDSMenu()
    local dialog
    local auto_sync_status = self._manager.settings.auto_sync and _("On") or _("Off")
    local last_sync = self._manager.settings.last_sync_time
    local last_sync_text = last_sync > 0 and os.date("%Y-%m-%d %H:%M", last_sync) or _("Never")
    dialog = ButtonDialog:new{
        buttons = {
            {{
                    text = _("Add catalog"),
                    callback = function()
                        UIManager:close(dialog)
                        self:addEditCatalog()
                    end,
                    align = "left",
            }},
            {},
            {{
                text = _("Auto-sync: ") .. auto_sync_status,
                callback = function()
                    UIManager:close(dialog)
                    self._manager.settings.auto_sync = not self._manager.settings.auto_sync
                    self._manager.updated = true
                    if self._manager.settings.auto_sync then
                        self._manager:schedulePeriodicSync()
                        self._manager:registerAutoSyncEvents()
                    else
                        UIManager:unschedule(self._manager.periodic_sync_task)
                        self._manager:registerAutoSyncEvents()
                    end
                    UIManager:show(InfoMessage:new{
                        text = self._manager.settings.auto_sync and _("Auto-sync enabled") or _("Auto-sync disabled"),
                    })
                end,
                align = "left",
            }},
            {{
                text = _("Last sync: ") .. last_sync_text,
                enabled = false,
                align = "left",
            }},
            {},
            {{
                    text = _("Sync all catalogs"),
                    callback = function()
                        UIManager:close(dialog)
                        NetworkMgr:runWhenConnected(function()
                            self._manager:launchSync{ manual = true }
                        end)
                    end,
                    align = "left",
            }},
            {{
                    text = _("Force sync all catalogs"),
                    callback = function()
                        UIManager:close(dialog)
                        NetworkMgr:runWhenConnected(function()
                            self._manager:launchSync{ manual = true, ignore_ledger = true }
                        end)
                    end,
                    align = "left",
            }},
            {{
                    text = _("Seed markers (one-off)"),
                    callback = function()
                        UIManager:close(dialog)
                        NetworkMgr:runWhenConnected(function()
                            require("tools/seed_markers").run(self._manager)
                        end)
                    end,
                    align = "left",
            }},
            {{
                    text = _("Set max number of files to sync"),
                    callback = function()
                        self:setMaxSyncDownload()
                    end,
                    align = "left",
            }},
            {{
                    text = _("Set sync folder"),
                    callback = function()
                        self:setSyncDir()
                    end,
                    align = "left",
            }},
            {{
                    text = _("Set file types to sync"),
                    callback = function()
                        self:setSyncFiletypes()
                    end,
                    align = "left",
            }},
        },
        shrink_unneeded_width = true,
        anchor = function()
            return self.title_bar.left_button.image.dimen
        end,
    }
    UIManager:show(dialog)
end
function OPDSBrowser:setExcludedAuthors()
    -- Find current server
    local current_server = nil
    for _, server in ipairs(self.servers) do
        if server.title == self.root_catalog_title then
            current_server = server
            break
        end
    end

    if not current_server then
        UIManager:show(InfoMessage:new{text = _("No catalog selected")})
        return
    end

    local current_excluded = table.concat(current_server.excluded_authors or {}, ", ")
    local dialog
    dialog = InputDialog:new{
        title = _("Excluded Authors"),
        description = _("Comma-separated list of authors to exclude"),
        input_hint = _("Author One, Author Two"),
        input = current_excluded,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local input_text = dialog:getInputText()
                        current_server.excluded_authors = {}
                        for author in util.gsplit(input_text, ",") do
                            table.insert(current_server.excluded_authors, util.trim(author))
                        end
                        self._manager.updated = true
                        UIManager:close(dialog)
                        if self.paths and #self.paths > 0 and self.paths[#self.paths] then
                            self:updateCatalog(self.paths[#self.paths].url, true)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function OPDSBrowser:setExcludedCategories()
    -- Find current server
    local current_server = nil
    for _, server in ipairs(self.servers) do
        if server.title == self.root_catalog_title then
            current_server = server
            break
        end
    end

    if not current_server then
        UIManager:show(InfoMessage:new{text = _("No catalog selected")})
        return
    end

    local current_excluded = table.concat(current_server.excluded_categories or {}, ", ")
    local dialog
    dialog = InputDialog:new{
        title = _("Excluded Categories"),
        description = _("Comma-separated list of categories to exclude"),
        input_hint = _("Fiction, Non-Fiction"),
        input = current_excluded,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local input_text = dialog:getInputText()
                        current_server.excluded_categories = {}
                        for category in util.gsplit(input_text, ",") do
                            table.insert(current_server.excluded_categories, util.trim(category))
                        end
                        self._manager.updated = true
                        UIManager:close(dialog)
                        if self.paths and #self.paths > 0 and self.paths[#self.paths] then
                            self:updateCatalog(self.paths[#self.paths].url, true)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function OPDSBrowser:setIncludedAuthors()
    -- Find current server
    local current_server = nil
    for _, server in ipairs(self.servers) do
        if server.title == self.root_catalog_title then
            current_server = server
            break
        end
    end

    if not current_server then
        UIManager:show(InfoMessage:new{text = _("No catalog selected")})
        return
    end

    local current_included = table.concat(current_server.included_authors or {}, ", ")
    local dialog
    dialog = InputDialog:new{
        title = _("Included Authors"),
        description = _("Comma-separated list of authors to include"),
        input_hint = _("Author One, Author Two"),
        input = current_included,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local input_text = dialog:getInputText()
                        current_server.included_authors = {}
                        for author in util.gsplit(input_text, ",") do
                            table.insert(current_server.included_authors, util.trim(author))
                        end
                        self._manager.updated = true
                        UIManager:close(dialog)
                        if self.paths and #self.paths > 0 and self.paths[#self.paths] then
                            self:updateCatalog(self.paths[#self.paths].url, true)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function OPDSBrowser:setIncludedCategories()
    -- Find current server
    local current_server = nil
    for _, server in ipairs(self.servers) do
        if server.title == self.root_catalog_title then
            current_server = server
            break
        end
    end

    if not current_server then
        UIManager:show(InfoMessage:new{text = _("No catalog selected")})
        return
    end

    local current_included = table.concat(current_server.included_categories or {}, ", ")
    local dialog
    dialog = InputDialog:new{
        title = _("Included Categories"),
        description = _("Comma-separated list of categories to include"),
        input_hint = _("Fiction, Non-Fiction"),
        input = current_included,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local input_text = dialog:getInputText()
                        current_server.included_categories = {}
                        for category in util.gsplit(input_text, ",") do
                            table.insert(current_server.included_categories, util.trim(category))
                        end
                        self._manager.updated = true
                        UIManager:close(dialog)
                        if self.paths and #self.paths > 0 and self.paths[#self.paths] then
                            self:updateCatalog(self.paths[#self.paths].url, true)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Shows facet menu for OPDS catalogs with facets/search support
function OPDSBrowser:showFacetMenu()
    local buttons = {}
    local dialog
    local catalog_url = self.paths[#self.paths].url

    -- Add sub-catalog to bookmarks option first
    table.insert(buttons, {{
        text = "\u{f067} " .. _("Add catalog"),
        callback = function()
            UIManager:close(dialog)
            self:addSubCatalog(catalog_url)
        end,
        align = "left",
    }})
    table.insert(buttons, {}) -- separator

    -- Add filter settings
    table.insert(buttons, {{
        text = "\u{f0b0} " .. _("Set excluded authors"),
        callback = function()
            UIManager:close(dialog)
            self:setExcludedAuthors()
        end,
        align = "left",
    }})
    table.insert(buttons, {{
        text = "\u{f0b0} " .. _("Set excluded categories"),
        callback = function()
            UIManager:close(dialog)
            self:setExcludedCategories()
        end,
        align = "left",
    }})
    table.insert(buttons, {{
        text = "\u{f0b0} " .. _("Set included authors"),
        callback = function()
            UIManager:close(dialog)
            self:setIncludedAuthors()
        end,
        align = "left",
    }})
    table.insert(buttons, {{
        text = "\u{f0b0} " .. _("Set included categories"),
        callback = function()
            UIManager:close(dialog)
            self:setIncludedCategories()
        end,
        align = "left",
    }})
    table.insert(buttons, {}) -- separator

    -- Add search option if available
    if self.search_url then
        table.insert(buttons, {{
            text = "\u{f002} " .. _("Search"),
            callback = function()
                UIManager:close(dialog)
                self:searchCatalog(self.search_url)
            end,
            align = "left",
        }})
        table.insert(buttons, {}) -- separator
    end

    -- Add facet groups
    if self.facet_groups then
        for group_name, facets in ffiUtil.orderedPairs(self.facet_groups) do
            table.insert(buttons, {
                { text = "\u{f0b0} " .. group_name, enabled = false, align = "left" }
            })

            for __, link in ipairs(facets) do
                local facet_text = link.title
                if link["thr:count"] then
                    facet_text = T(_("%1 (%2)"), facet_text, link["thr:count"])
                end
                if link["opds:activeFacet"] == "true" then
                    facet_text = "✓ " .. facet_text
                end
                table.insert(buttons, {{
                    text = facet_text,
                    callback = function()
                        UIManager:close(dialog)
                        self:updateCatalog(url.absolute(catalog_url, link.href))
                    end,
                    align = "left",
                }})
            end
            table.insert(buttons, {}) -- separator between groups
        end
    end

    dialog = ButtonDialog:new{
        buttons = buttons,
        shrink_unneeded_width = true,
        anchor = function()
            return self.title_bar.left_button.image.dimen
        end,
    }
    UIManager:show(dialog)
end


local function buildRootEntry(server)
    local icons = ""
    if server.username then
        icons = "\u{f2c0}"
    end
    if server.sync then
        icons = "\u{f46a} " .. icons
    end
    return {
        text       = server.title,
        mandatory  = icons,
        url        = server.url,
        username   = server.username,
        password   = server.password,
        raw_names  = server.raw_names, -- use server raw filenames for download
        searchable = server.url and server.url:match("%%s") and true or false,
        sync       = server.sync,
        sync_dir   = server.sync_dir,  -- Add this line
        home_url   = server.home_url,   -- optional start point (long-press a
        home_title = server.home_title, -- folder inside → "Set as start point")
        excluded_authors = server.excluded_authors,
        excluded_categories = server.excluded_categories,
        included_authors = server.included_authors,
        included_categories = server.included_categories,
    }
end

-- Builds the root list of catalogs
function OPDSBrowser:genItemTableFromRoot()
    local item_table = {
        {
            text = _("Downloads"),
            mandatory = #self.downloads,
        },
    }
    for _, server in ipairs(self.servers) do
        table.insert(item_table, buildRootEntry(server))
    end
    return item_table
end

-- Shows dialog to edit properties of the new/existing catalog
function OPDSBrowser:addEditCatalog(item)
    local fields = {
        {
            hint = _("Catalog name"),
        },
        {
            hint = _("Catalog URL"),
        },
        {
            hint = _("Username (optional)"),
        },
        {
            hint = _("Password (optional)"),
            text_type = "password",
        },
        {
            hint = _("Excluded Authors (optional)"),
        },
        {
            hint = _("Excluded Categories (optional)"),
        },
        {
            hint = _("Included Authors (optional)"),
        },
        {
            hint = _("Included Categories (optional)"),
        },
    }
    local title
    if item then
        title = _("Edit OPDS catalog")
        fields[1].text = item.text
        fields[2].text = item.url
        fields[3].text = item.username
        fields[4].text = item.password
        fields[5].text = table.concat(item.excluded_authors or {}, ", ")
        fields[6].text = table.concat(item.excluded_categories or {}, ", ")
        fields[7].text = table.concat(item.included_authors or {}, ", ")
        fields[8].text = table.concat(item.included_categories or {}, ", ")
    else
        title = _("Add OPDS catalog")
    end

    local dialog, check_button_raw_names, check_button_sync_catalog, button_sync_dir
    dialog = MultiInputDialog:new{
        title = title,
        fields = fields,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local new_fields = dialog:getFields()
                        new_fields[9] = check_button_raw_names.checked or nil
                        new_fields[10] = check_button_sync_catalog.checked or nil
                        new_fields[11] = button_sync_dir.sync_dir or nil
                        self:editCatalogFromInput(new_fields, item)
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }

    -- Existing check buttons...
    check_button_raw_names = CheckButton:new{
        text = _("Use server filenames"),
        checked = item and item.raw_names,
        parent = dialog,
    }
    check_button_sync_catalog = CheckButton:new{
        text = _("Sync catalog"),
        checked = item and item.sync,
        parent = dialog,
    }

    -- Add sync directory button
    button_sync_dir = Button:new{
        text = item and item.sync_dir and _("Sync folder: ") .. item.sync_dir or _("Set sync folder"),
        callback = function()
            local force_chooser_dir_for_per_catalog
            if Device:isAndroid() then
                force_chooser_dir_for_per_catalog = Device.home_dir
            end

            -- Use item.sync_dir or self.settings.sync_dir as initial path
            local initial_path = item and item.sync_dir or self.settings.sync_dir or G_reader_settings:readSetting("download_dir")

            DownloadMgr:new{
                onConfirm = function(inbox)
                    if inbox then -- Check if user selected a directory and not cancelled
                        button_sync_dir.sync_dir = inbox
                        button_sync_dir:setText(_("Sync folder: ") .. inbox)
                        self._manager.updated = true -- Mark manager as updated for settings persistence
                    end
                end,
            }:chooseDir(initial_path or force_chooser_dir_for_per_catalog)
        end,
    }

    dialog:addWidget(check_button_raw_names)
    dialog:addWidget(check_button_sync_catalog)
    dialog:addWidget(button_sync_dir)
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Shows dialog to add a subcatalog to the root list
function OPDSBrowser:addSubCatalog(item_url)
    local dialog
    dialog = InputDialog:new{
        title = _("Add OPDS catalog"),
        input = self.root_catalog_title .. " - " .. self.catalog_title,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local name = dialog:getInputText()
                        if name ~= "" then
                            UIManager:close(dialog)
                            local fields = {name, item_url,
                                self.root_catalog_username, self.root_catalog_password, self.root_catalog_raw_names}
                            self:editCatalogFromInput(fields, nil, true) -- no init, stay in the subcatalog
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Saves catalog properties from input dialog
function OPDSBrowser:editCatalogFromInput(fields, item, no_refresh)
    local new_server = {
        title     = fields[1],
        url       = fields[2]:match("^%a+://") and fields[2] or "http://" .. fields[2],
        username  = fields[3] ~= "" and fields[3] or nil,
        password  = fields[4] ~= "" and fields[4] or nil,
        excluded_authors = {},
        excluded_categories = {},
        included_authors = {},
        included_categories = {},
        raw_names = fields[9],
        sync      = fields[10],
        sync_dir  = fields[11],
    }

    -- Parse excluded authors
    if fields[5] and fields[5] ~= "" then
        for author in util.gsplit(fields[5], ",") do
            table.insert(new_server.excluded_authors, util.trim(author))
        end
    end

    -- Parse excluded categories
    if fields[6] and fields[6] ~= "" then
        for category in util.gsplit(fields[6], ",") do
            table.insert(new_server.excluded_categories, util.trim(category))
        end
    end

    -- Parse included authors
    if fields[7] and fields[7] ~= "" then
        for author in util.gsplit(fields[7], ",") do
            table.insert(new_server.included_authors, util.trim(author))
        end
    end

    -- Parse included categories
    if fields[8] and fields[8] ~= "" then
        for category in util.gsplit(fields[8], ",") do
            table.insert(new_server.included_categories, util.trim(category))
        end
    end

    local new_item = buildRootEntry(new_server)
    local new_idx, itemnumber
    if item then
        new_idx = item.idx
        itemnumber = -1
    else
        new_idx = #self.servers + 2
        itemnumber = new_idx
    end
    self.servers[new_idx - 1] = new_server -- first item is "Downloads"
    self.item_table[new_idx] = new_item
    if not no_refresh then
        self:switchItemTable(nil, self.item_table, itemnumber)
    end
    self._manager.updated = true
end

-- Deletes catalog from the root list
function OPDSBrowser:deleteCatalog(item)
    table.remove(self.servers, item.idx - 1)
    table.remove(self.item_table, item.idx)
    self:switchItemTable(nil, self.item_table, -1)
    self._manager.updated = true
end

-- Fetches feed from server
function OPDSBrowser:fetchFeed(item_url, headers_only)
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local request = {
        url      = item_url,
        method   = headers_only and "HEAD" or "GET",
        -- Explicitly specify that we don't support compressed content.
        -- Some servers will still break RFC2616 14.3 and send crap instead.
        headers  = {
            ["Accept-Encoding"] = "identity",
        },
        sink     = ltn12.sink.table(sink),
        user     = self.root_catalog_username,
        password = self.root_catalog_password,
    }
    logger.dbg("Request:", socketutil.redact_request(request))
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if headers_only then
        return headers
    end
    if code == 200 then
        local xml = table.concat(sink)
        return xml ~= "" and xml
    end

    local text, icon
    if headers and code == 301 then
        text = T(_("The catalog has been permanently moved. Please update catalog URL to '%1'."), BD.url(headers.location))
    elseif headers and code == 302
        and item_url:match("^https")
        and headers.location:match("^http[^s]") then
        text = T(_("Insecure HTTPS → HTTP downgrade attempted by redirect from:\n\n'%1'\n\nto\n\n'%2'.\n\nPlease inform the server administrator that many clients disallow this because it could be a downgrade attack."),
            BD.url(item_url), BD.url(headers.location))
            icon = "notice-warning"
    else
        local error_message = {
            ["401"] = _("Authentication required for catalog. Please add a username and password."),
            ["403"] = _("Failed to authenticate. Please check your username and password."),
            ["404"] = _("Catalog not found."),
            ["406"] = _("Cannot get catalog. Server refuses to serve uncompressed content."),
        }
        text = code and error_message[tostring(code)] or T(_("Cannot get catalog. Server response status: %1."), status or code)
    end
    -- Maki: `self.sync` marks a headless browser (the forked sync child, the
    -- seed tool). Nothing there may build or show a widget, so report the
    -- failure to the log and let the caller's `nil` return do the talking.
    if self.sync then
        logger.warn(string.format("Maki: failed to fetch catalog `%s`: %s", item_url, text))
        return
    end
    UIManager:show(InfoMessage:new{
        text = text,
        icon = icon,
    })
    logger.dbg(string.format("OPDS: Failed to fetch catalog `%s`: %s", item_url, text))
end

-- Parses feed to catalog
function OPDSBrowser:parseFeed(item_url)
    local headers = self:fetchFeed(item_url, true)
    local feed_last_modified = headers and headers["last-modified"]
    local feed
    if feed_last_modified then
        local hash = "opds|catalog|" .. item_url .. "|" .. feed_last_modified
        feed = CatalogCache:check(hash)
        if feed then
            logger.dbg("Cache hit for", hash)
        else
            logger.dbg("Cache miss for", hash)
            feed = self:fetchFeed(item_url)
            if feed then
                logger.dbg("Caching", hash)
                CatalogCache:insert(hash, feed)
            end
        end
    else
        feed = self:fetchFeed(item_url)
    end
    if feed then
        return OPDSParser:parse(feed)
    end
end

-- Derive the on-disk filename from a response's headers (Content-Disposition
-- in its various encodings, redirect Location, URL basename fallback), then
-- normalise manga chapter names via makinames. Split out of getServerFileName
-- so the bulk downloader can feed it headers obtained over its keepalive
-- connection instead of paying a fresh TLS handshake per HEAD.
function OPDSBrowser.fileNameFromHeaders(headers, item_url, filetype)
    local filename

    if headers then
        logger.dbg("OPDSBrowser: server file headers", socketutil.redact_headers(headers))
        local disposition = headers["content-disposition"]
        if disposition then
            -- Maki: prefer RFC 5987 `filename*=UTF-8''<percent-encoded>` over
            -- the legacy `filename="..."` form. Komga (and others) emit both:
            --   filename="=?UTF-8?Q?Official=5FChapter_2.cbz?="; filename*=UTF-8''Official_Chapter%202.cbz
            -- The RFC 5987 value is plain percent-encoded UTF-8 — no RFC 2047
            -- email-header gymnastics needed.
            filename = disposition:match("filename%*=[^']*''([^;]+)")
            if filename then
                filename = percent_decode(filename)
            else
                -- Fall back to filename="..." or filename=...
                filename = disposition:match('filename="([^"]+)"')
                if not filename then
                    filename = disposition:match("filename=([^;]+)")
                end
                -- Decode RFC 2047 encoded-word (=?charset?Q?text?= / ...?B?text?=)
                -- so we don't end up with file system names like
                -- "=_UTF-8_Q_Official=5FChapter_2.cbz_=" (what happens when the
                -- raw encoded-word reaches util.getSafeFilename and `?` gets
                -- stripped as an illegal FAT32 char).
                if filename then
                    local cs, enc, payload = filename:match("^=%?([^?]+)%?([QqBb])%?(.-)%?=$")
                    if cs and enc and payload then
                        local lower_enc = enc:lower()
                        if lower_enc == "q" then
                            payload = payload:gsub("_", " ")
                            payload = payload:gsub("=(%x%x)", function(h)
                                return string.char(tonumber(h, 16))
                            end)
                            filename = payload
                        elseif lower_enc == "b" then
                            local ok, b = pcall(require, "base64")
                            if ok and b and b.decode then
                                local decoded = b.decode(payload)
                                if decoded then filename = decoded end
                            end
                        end
                    end
                end
            end
        end

        -- If not found, try from redirect URL (location)
        if not filename and headers["location"] then
            filename = percent_decode(headers["location"]:gsub(".*/", ""))
        end
    end

    -- If still no filename, extract from original URL (remove path and query
    -- params). Maki: the URL basename is percent-encoded — decode it, or a
    -- failed HEAD request leaves names like "Unknown_%23%2091.cbz" on disk.
    if not filename then
        filename = percent_decode(item_url:gsub(".*/", ""):gsub("?.*", ""))
    end

    if filename and filetype then
        local current_suffix = util.getFileNameSuffix(filename)
        -- Add extension if missing
        if not current_suffix then
            filename = filename .. "." .. filetype:lower()
        end
    end

    return MakiNames.normalizeChapter(filename)
end

function OPDSBrowser:getServerFileName(item_url, filetype)
    local headers = self:fetchFeed(item_url, true)
    return OPDSBrowser.fileNameFromHeaders(headers, item_url, filetype)
end

-- Generates link to search in catalog
function OPDSBrowser:getSearchTemplate(osd_url)
    -- parse search descriptor
    local search_descriptor = self:parseFeed(osd_url)
    if search_descriptor and search_descriptor.OpenSearchDescription and search_descriptor.OpenSearchDescription.Url then
        for _, candidate in ipairs(search_descriptor.OpenSearchDescription.Url) do
            if candidate.type and candidate.template and candidate.type:find(self.search_template_type) then
                return candidate.template:gsub("{searchTerms}", "%%s")
            end
        end
    end
end

-- Generates menu items from the fetched list of catalog entries
function OPDSBrowser:genItemTableFromURL(item_url)
    local ok, catalog = pcall(self.parseFeed, self, item_url)
    if not ok then
        logger.info("Cannot get catalog info from", item_url, catalog)
        UIManager:show(InfoMessage:new{
            text = T(_("Cannot get catalog info from %1"), (item_url and BD.url(item_url) or "nil")),
        })
        catalog = nil
    end
    return self:genItemTableFromCatalog(catalog, item_url)
end

-- Generates catalog item table and processes OPDS facets/search links
function OPDSBrowser:genItemTableFromCatalog(catalog, item_url)
    local item_table = {}
    self.facet_groups = nil -- Reset facets
    self.search_url = nil   -- Reset search URL

    if not catalog then
        return item_table
    end

    local feed = catalog.feed or catalog
    self.facet_groups = {} -- Initialize table to store facet groups

    local function build_href(href)
        return url.absolute(item_url, href)
    end

    local has_opensearch = false
    local hrefs = {}
    if feed.link then
        for __, link in ipairs(feed.link) do
            if link.type ~= nil then
                if link.type:find(self.catalog_type) then
                    if link.rel and link.href then
                        hrefs[link.rel] = build_href(link.href)
                    end
                end
                if not self.sync then
                    -- OpenSearch
                    if link.type:find(self.search_type) then
                        if link.href then
                            self.search_url = build_href(self:getSearchTemplate(build_href(link.href)))
                            has_opensearch = true
                        end
                    end
                    -- Calibre search (also matches the actual template for OpenSearch!)
                    if link.type:find(self.search_template_type) and link.rel and link.rel:find("search") then
                        if link.href and not has_opensearch then
                            self.search_url = build_href(link.href:gsub("{searchTerms}", "%%s"))
                        end
                    end
                    -- Process OPDS facets
                    if link.rel == self.facet_rel then
                        local group_name = link["opds:facetGroup"] or _("Filters")
                        if not self.facet_groups[group_name] then
                            self.facet_groups[group_name] = {}
                        end
                        table.insert(self.facet_groups[group_name], link)
                    end
                end
            end
        end
    end
    item_table.hrefs = hrefs

    for __, entry in ipairs(feed.entry or {}) do
        local item = {}
        item.acquisitions = {}
        if entry.link then
            for ___, link in ipairs(entry.link) do
                local link_href = build_href(link.href)
                if link.type and link.type:find(self.catalog_type)
                        and (not link.rel
                             or link.rel == "subsection"
                             or link.rel == "http://opds-spec.org/subsection"
                             or link.rel == "http://opds-spec.org/sort/popular"
                             or link.rel == "http://opds-spec.org/sort/new") then
                    item.url = link_href
                end
                -- Some catalogs do not use the rel attribute to denote
                -- a publication. Arxiv uses title. Specifically, it uses
                -- a title attribute that contains pdf. (title="pdf")
                if link.rel or link.title then
                    if link.rel == self.borrow_rel then
                        table.insert(item.acquisitions, {
                            type = "borrow",
                        })
                    elseif link.rel and link.rel:match(self.acquisition_rel) then
                        table.insert(item.acquisitions, {
                            type  = link.type,
                            href  = link_href,
                            title = link.title,
                        })
                    elseif link.rel == self.stream_rel then
                        -- https://vaemendis.net/opds-pse/
                        -- «count» MUST provide the number of pages of the document
                        -- namespace may be not "pse"
                        local count, last_read
                        for k, v in pairs(link) do
                            if k:sub(-6) == ":count" then
                                count = tonumber(v)
                            elseif k:sub(-9) == ":lastRead" then
                                last_read = tonumber(v)
                            end
                        end
                        if count then
                            table.insert(item.acquisitions, {
                                type  = link.type,
                                href  = link_href,
                                title = link.title,
                                count = count,
                                last_read = last_read and last_read > 0 and last_read or nil
                            })
                        end
                    elseif self.thumbnail_rel[link.rel] then
                        item.thumbnail = link_href
                    elseif self.image_rel[link.rel] then
                        item.image = link_href
                    elseif link.rel ~= "alternate" and DocumentRegistry:hasProvider(nil, link.type) then
                        table.insert(item.acquisitions, {
                            type  = link.type,
                            href  = link_href,
                            title = link.title,
                        })
                    end
                    -- This statement grabs the catalog items that are
                    -- indicated by title="pdf" or whose type is
                    -- "application/pdf"
                    if link.title == "pdf" or link.type == "application/pdf"
                        and link.rel ~= "subsection" then
                        -- Check for the presence of the pdf suffix and add it
                        -- if it's missing.
                        local original_href = link.href
                        local parsed = url.parse(original_href)
                        if not parsed then parsed = { path = original_href } end
                        local path = parsed.path or ""
                        -- Calibre web OPDS download links end with "/<filetype>/"
                        if not util.stringEndsWith(path, "/pdf/") then
                            local appended = false
                            if util.getFileNameSuffix(path) ~= "pdf" then
                                if path == "" then
                                    path = ".pdf"
                                else
                                    path = path .. ".pdf"
                                end
                                appended = true
                            end
                            if appended then
                                parsed.path = path
                                local new_href = url.build(parsed)
                                table.insert(item.acquisitions, {
                                    type = link.title,
                                    href = build_href(new_href),
                                })
                            end
                        end
                    end
                end
            end
        end
        local title = _("Unknown")
        if type(entry.title) == "string" then
            title = entry.title
        elseif type(entry.title) == "table" then
            if type(entry.title.type) == "string" and entry.title.div ~= "" then
                title = entry.title.div
            end
        end
        item.text = title
        local author = _("Unknown Author")
        if type(entry.author) == "table" and entry.author.name then
            author = entry.author.name
            if type(author) == "table" then
                if #author > 0 then
                    author = table.concat(author, ", ")
                else
                    -- we may get an empty table on https://gallica.bnf.fr/opds
                    author = nil
                end
            end
            if author then
                item.text = title .. " - " .. author
            end
        end
        item.title = title
        item.author = author
        item.content = entry.content or entry.summary

        local current_server
        for _, server in ipairs(self.servers) do
            if server.title == self.root_catalog_title then
                current_server = server
                break
            end
        end

        if current_server then
            -- Handle includes first
            if current_server.included_authors and #current_server.included_authors > 0 then
                local author_found = false
                local lower_author = (author or ""):lower()
                for _, included_author in ipairs(current_server.included_authors) do
                    if lower_author:find((included_author or ""):lower(), 1, true) then
                        author_found = true
                        break
                    end
                end
                if not author_found then goto continue_entry end
            end

            if current_server.included_categories and #current_server.included_categories > 0 and entry.category then
                local category_found = false
                for _, included_category in ipairs(current_server.included_categories) do
                    local lower_included_category = (included_category or ""):lower()
                    for _, category_entry in ipairs(entry.category) do
                        if category_entry.term and category_entry.term:lower():find(lower_included_category, 1, true) then
                            category_found = true
                            break
                        end
                    end
                    if category_found then break end
                end
                if not category_found then goto continue_entry end
            elseif current_server.included_categories and #current_server.included_categories > 0 and (not entry.category or #entry.category == 0) then
                -- if include categories are set, but the entry has no categories, it should be excluded.
                goto continue_entry
            end

            -- Then handle excludes
            if current_server.excluded_authors and #current_server.excluded_authors > 0 then
                local lower_author = (author or ""):lower()
                for _, excluded_author in ipairs(current_server.excluded_authors) do
                    if lower_author:find((excluded_author or ""):lower(), 1, true) then
                        goto continue_entry
                    end
                end
            end

            if current_server.excluded_categories and #current_server.excluded_categories > 0 and entry.category then
                for _, excluded_category in ipairs(current_server.excluded_categories) do
                    local lower_excluded_category = (excluded_category or ""):lower()
                    for _, category_entry in ipairs(entry.category) do
                        if category_entry.term and category_entry.term:lower():find(lower_excluded_category, 1, true) then
                            goto continue_entry
                        end
                    end
                end
            end
        end

        table.insert(item_table, item)
        ::continue_entry::
    end

    if next(self.facet_groups) == nil then self.facet_groups = nil end -- Clear if empty

    return item_table
end

-- Requests and shows updated list of catalog entries
function OPDSBrowser:updateCatalog(item_url, paths_updated)
    local menu_table = self:genItemTableFromURL(item_url)
    if #menu_table > 0 or self.facet_groups or self.search_url then
        if not paths_updated then
            table.insert(self.paths, {
                url   = item_url,
                title = self.catalog_title,
            })
        end
        self:switchItemTable(self.catalog_title, menu_table)

        -- Set appropriate title bar icon based on content
        if self.facet_groups or self.search_url then
            self:setTitleBarLeftIcon("appbar.menu")
            self.onLeftButtonTap = function()
                self:showFacetMenu()
            end
        else
            self:setTitleBarLeftIcon("plus")
            self.onLeftButtonTap = function()
                self:addSubCatalog(item_url)
            end
        end

        if self.page_num <= 1 then
            -- Request more content, but don't change the page
            self:onNextPage(true)
        end
    end
end

-- Requests and adds more catalog entries to fill out the page
function OPDSBrowser:appendCatalog(item_url)
    local menu_table = self:genItemTableFromURL(item_url)
    if #menu_table > 0 then
        for __, item in ipairs(menu_table) do
            table.insert(self.item_table, item)
        end
        self.item_table.hrefs = menu_table.hrefs
        self:switchItemTable(self.catalog_title, self.item_table, -1)
        return true
    end
end

-- Shows dialog to search in catalog
function OPDSBrowser:searchCatalog(item_url)
    local dialog
    dialog = InputDialog:new{
        title = _("Search OPDS catalog"),
        -- @translators: This is an input hint for something to search for in an OPDS catalog, namely a famous author everyone knows. It probably doesn't need to be localized, but this is just here in case another name or book title would be more appropriate outside of a European context.
        input_hint = _("Alexandre Dumas"),
        description = _("%s in url will be replaced by your input"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        UIManager:close(dialog)
                        self.catalog_title = _("Search results")
                        local search_str = util.urlEncode(dialog:getInputText())
                        -- Use function replacement to avoid % being treated as capture refs
                        item_url = item_url:gsub("%%s", function() return search_str end)
                        self:updateCatalog(item_url)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Shows dialog to download / stream a book
function OPDSBrowser:showDownloads(item)
    local acquisitions = item.acquisitions
    local filename, filename_orig = self:getFileName(item)

    local function createTitle(path, file) -- title for ButtonDialog
        return T(_("Download folder:\n%1\n\nDownload filename:\n%2\n\nDownload file type:"),
            BD.dirpath(path), file or _("<server filename>"))
    end

    local buttons = {} -- buttons for ButtonDialog
    local stream_buttons -- page stream buttons
    local download_buttons = {} -- file type download buttons
    for i, acquisition in ipairs(acquisitions) do -- filter out unsupported file types
        if acquisition.count then
            stream_buttons = {
                {
                    {
                        -- @translators "Stream" here refers to being able to read documents from an OPDS server without downloading them completely, on a page by page basis.
                        text = "\u{23EE} " .. _("Page stream"), -- prepend BLACK LEFT-POINTING DOUBLE TRIANGLE WITH BAR
                        callback = function()
                            OPDSPSE:streamPages(acquisition.href, acquisition.count, false, self.root_catalog_username, self.root_catalog_password)
                            UIManager:close(self.download_dialog)
                        end,
                    },
                    {
                        -- @translators "Stream" here refers to being able to read documents from an OPDS server without downloading them completely, on a page by page basis.
                        text = _("Stream from page") .. " \u{23E9}", -- append BLACK RIGHT-POINTING DOUBLE TRIANGLE
                        callback = function()
                            OPDSPSE:streamPages(acquisition.href, acquisition.count, true, self.root_catalog_username, self.root_catalog_password)
                            UIManager:close(self.download_dialog)
                        end,
                    },
                },
            }

            if acquisition.last_read then
                table.insert(stream_buttons, {
                    {
                        -- @translators "Stream" here refers to being able to read documents from an OPDS server without downloading them completely, on a page by page basis.
                        text = "\u{25B6} " .. _("Resume stream from page") .. " " .. acquisition.last_read, -- prepend BLACK RIGHT-POINTING TRIANGLE
                        callback = function()
                            OPDSPSE:streamPages(acquisition.href, acquisition.count, false, self.root_catalog_username, self.root_catalog_password, acquisition.last_read)
                            UIManager:close(self.download_dialog)
                        end,
                    },
                })
            end
        elseif acquisition.type == "borrow" then
            table.insert(download_buttons, {
                text = _("Borrow"),
                enabled = false,
            })
        else
            local filetype = self.getFiletype(acquisition)
            if filetype then -- supported file type
                local text = url.unescape(acquisition.title or string.upper(filetype))
                table.insert(download_buttons, {
                    text = text .. "\u{2B07}", -- append DOWNWARDS BLACK ARROW
                    callback = function()
                        UIManager:close(self.download_dialog)
                        local local_path = self:getLocalDownloadPath(nil, filename, filetype, acquisition.href)
                        self:checkDownloadFile(local_path, acquisition.href, self.root_catalog_username, self.root_catalog_password, self.file_downloaded_callback)
                    end,
                    hold_callback = function()
                        UIManager:close(self.download_dialog)
                        table.insert(self.downloads, {
                            file     = self:getLocalDownloadPath(nil, filename, filetype, acquisition.href),
                            url      = acquisition.href,
                            info     = type(item.content) == "string" and util.htmlToPlainTextIfHtml(item.content) or "",
                            catalog  = self.root_catalog_title,
                            username = self.root_catalog_username,
                            password = self.root_catalog_password,
                        })
                        self._manager.updated = true
                        Notification:notify(_("Book added to download list"), Notification.SOURCE_OTHER)
                    end,
                })
            end
        end
    end

    local buttons_nb = #download_buttons
    if buttons_nb > 0 then
        if buttons_nb == 1 then -- one wide button
            table.insert(buttons, download_buttons)
        else
            if buttons_nb % 2 == 1 then -- we need even number of buttons
                table.insert(download_buttons, {text = ""})
            end
            for i = 1, buttons_nb, 2 do -- two buttons in a row
                table.insert(buttons, {download_buttons[i], download_buttons[i+1]})
            end
        end
        table.insert(buttons, {}) -- separator
    end
    if stream_buttons then
        for _, button_list in ipairs(stream_buttons) do
            table.insert(buttons, button_list)
        end
        table.insert(buttons, {}) -- separator
    end
    table.insert(buttons, { -- action buttons
        {
            text = _("Choose folder"),
            callback = function()
                require("ui/downloadmgr"):new{
                    onConfirm = function(path)
                        logger.dbg("Download folder set to", path)
                        G_reader_settings:saveSetting("download_dir", path)
                        self.download_dialog:setTitle(createTitle(path, filename))
                    end,
                }:chooseDir(self:getCurrentDownloadDir())
            end,
        },
        {
            text = _("Change filename"),
            callback = function()
                local dialog
                dialog = InputDialog:new{
                    title = _("Enter filename"),
                    input = filename or filename_orig,
                    input_hint = filename_orig,
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                id = "close",
                                callback = function()
                                    UIManager:close(dialog)
                                end,
                            },
                            {
                                text = _("Set filename"),
                                is_enter_default = true,
                                callback = function()
                                    filename = dialog:getInputValue()
                                    if filename == "" then
                                        filename = filename_orig
                                    end
                                    UIManager:close(dialog)
                                    self.download_dialog:setTitle(createTitle(self:getCurrentDownloadDir(), filename))
                                end,
                            },
                        }
                    },
                }
                UIManager:show(dialog)
                dialog:onShowKeyboard()
            end,
        },
    })
    local cover_link = item.image or item.thumbnail
    table.insert(buttons, {
        {
            text = _("Book cover"),
            enabled = cover_link and true or false,
            callback = function()
                OPDSPSE:streamPages(cover_link, 1, false, self.root_catalog_username, self.root_catalog_password)
            end,
        },
        {
            text = _("Book information"),
            enabled = type(item.content) == "string",
            callback = function()
                UIManager:show(TextViewer:new{
                    title = item.text,
                    title_multilines = true,
                    text = util.htmlToPlainTextIfHtml(item.content),
                    text_type = "book_info",
                })
            end,
        },
    })

    self.download_dialog = ButtonDialog:new{
        title = createTitle(self:getCurrentDownloadDir(), filename),
        buttons = buttons,
    }
    UIManager:show(self.download_dialog)
end

-- Helper function to get the filetype from an acquisitions table
function OPDSBrowser.getFiletype(link)
    local filetype = util.getFileNameSuffix(link.href)
    if not DocumentRegistry:hasProvider("dummy." .. filetype) then
        filetype = nil
    end
    if not filetype and DocumentRegistry:hasProvider(nil, link.type) then
        filetype = DocumentRegistry:mimeToExt(link.type)
    end
    return filetype
end

-- Returns user selected or last opened folder
function OPDSBrowser:getCurrentDownloadDir(item)
    -- Explicit per-item override wins.
    if item and item.sync_dir then return item.sync_dir end

    -- Maki: when the user is inside a catalog, mirror the navigation breadcrumb
    -- into the download path. Single-tap download of a chapter inside
    -- "Komga: Manga > Chainsaw Man" lands in <sync_dir>/Chainsaw Man/ — matches
    -- the long-press "Download all here" layout. paths[1] is the root catalog
    -- itself (we don't want it as a folder) so we start at paths[2].
    if self.root_catalog_title and self.paths and #self.paths > 0 then
        local server
        for _, s in ipairs(self.servers or {}) do
            if s.title == self.root_catalog_title then server = s break end
        end
        local server_dir = server and server.sync_dir
        if server_dir and server_dir ~= "" then
            local parts = { server_dir }
            for i = 2, #self.paths do
                local title = self.paths[i] and self.paths[i].title
                if title and title ~= "" then
                    table.insert(parts, sanitize_segment(title))
                end
            end
            return (table.concat(parts, "/"):gsub("//+", "/"))
        end
    end

    -- Global sync folder, or last-resort fallbacks so we never return nil.
    if self.settings and self.settings.sync_dir and self.settings.sync_dir ~= "" then
        return self.settings.sync_dir
    end
    if self.download_dir and self.download_dir ~= "" then return self.download_dir end
    local home = G_reader_settings:readSetting("home_dir")
    if home and home ~= "" then return home end
    return "/"  -- BD.dirpath at least handles this without nil-indexing
end

function OPDSBrowser:getLocalDownloadPath(server, filename, filetype, remote_url)
    local download_dir = self:getCurrentDownloadDir(server)
    -- Maki: breadcrumb-aware download dirs nest (e.g. <sync>/Chainsaw Man/).
    -- mkdir -p so io.open succeeds when the series folder doesn't exist yet.
    util.makePath(download_dir)
    filename = filename and filename .. "." .. filetype:lower() or self:getServerFileName(remote_url, filetype)
    filename = util.getSafeFilename(filename, download_dir)
    filename = (download_dir ~= "/" and download_dir or "") .. '/' .. filename
    return util.fixUtf8(filename, "_")
end

-- Downloads a book (with "File already exists" dialog)
function OPDSBrowser:checkDownloadFile(local_path, remote_url, username, password, caller_callback)
    local function download()
        UIManager:scheduleIn(1, function()
            self:downloadFile(local_path, remote_url, username, password, caller_callback)
        end)
        UIManager:show(InfoMessage:new{
            text = _("Downloading…"),
            timeout = 1,
        })
    end
    if lfs.attributes(local_path) then
        UIManager:show(ConfirmBox:new{
            text = T(_("The file %1 already exists. Do you want to overwrite it?"), BD.filepath(local_path)),
            ok_text = _("Overwrite"),
            ok_callback = function()
                download()
            end,
        })
    else
        download()
    end
end

-- Maki: `quiet` suppresses the per-file error dialog. Bulk/auto paths pass it
-- and report one aggregate result instead — otherwise a dead network stacks
-- one undismissable InfoMessage per queued file.
-- Returns true on success, or false + a short reason on failure.
function OPDSBrowser:downloadFile(local_path, remote_url, username, password, caller_callback, quiet)
    logger.dbg("Downloading file", local_path, "from", remote_url)
    local code, headers, status
    local parsed = url.parse(remote_url)
    if parsed.scheme == "http" or parsed.scheme == "https" then
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        code, headers, status = socket.skip(1, http.request {
            url      = remote_url,
            headers  = {
                ["Accept-Encoding"] = "identity",
            },
            sink     = ltn12.sink.file(io.open(local_path, "w")),
            user     = username,
            password = password,
        })
        socketutil:reset_timeout()
    else
        if not quiet then
            UIManager:show(InfoMessage:new {
                text = T(_("Invalid protocol:\n%1"), parsed.scheme),
            })
        end
        return false, T(_("invalid protocol: %1"), tostring(parsed.scheme))
    end
    if code == 200 then
        logger.dbg("File downloaded to", local_path)
        if caller_callback then
            caller_callback(local_path)
        end
        return true
    elseif code == 302 and remote_url:match("^https") and headers.location:match("^http[^s]") then
        util.removeFile(local_path)
        if not quiet then
            UIManager:show(InfoMessage:new{
                text = T(_("Insecure HTTPS → HTTP downgrade attempted by redirect from:\n\n'%1'\n\nto\n\n'%2'.\n\nPlease inform the server administrator that many clients disallow this because it could be a downgrade attack."), BD.url(remote_url), BD.url(headers.location)),
                icon = "notice-warning",
            })
        end
        return false, _("insecure HTTPS → HTTP redirect")
    else
        util.removeFile(local_path)
        local reason = tostring(status or code or "network unreachable")
        logger.dbg("OPDSBrowser:downloadFile: Request failed:", reason)
        logger.dbg("OPDSBrowser:downloadFile: Response headers:", headers)
        if not quiet then
            UIManager:show(InfoMessage:new {
                text = T(_("Could not save file to:\n%1\n%2"),
                    BD.filepath(local_path), reason),
            })
        end
        return false, reason
    end
end

-- Menu action on item tap (Download a book / Show subcatalog / Search in catalog)
function OPDSBrowser:onMenuSelect(item)
    if item.acquisitions and item.acquisitions[1] then -- book
        logger.dbg("Downloads available:", item)
        self:showDownloads(item)
    else -- catalog or Search item
        if #self.paths == 0 then -- root list
            if item.idx == 1 then
                if #self.downloads > 0 then
                    self:showDownloadList()
                end
                return true
            end
            self.root_catalog_title     = item.text
            self.root_catalog_username  = item.username
            self.root_catalog_password  = item.password
            self.root_catalog_raw_names = item.raw_names
        end
        local connect_callback
        if item.searchable then
            connect_callback = function()
                self:searchCatalog(item.url)
            end
        elseif #self.paths == 0 and item.home_url then
            -- A start point is set for this catalog (e.g. the Manga
            -- library): open it directly instead of the server root feed.
            -- The root feed is seeded onto the path stack so the up-arrow
            -- still walks start point → root feed → server list.
            connect_callback = function()
                self.paths = { { url = item.url, title = item.text } }
                self.catalog_title = item.home_title or item.text
                self:updateCatalog(item.home_url)
                if #self.paths == 1 then
                    -- Start point unreachable or empty (library renamed?):
                    -- fall back to the server root feed.
                    self.paths = {}
                    self.catalog_title = item.text
                    self:updateCatalog(item.url)
                end
            end
        else
            self.catalog_title = item.text or self.catalog_title or self.root_catalog_title
            connect_callback = function()
                self:updateCatalog(item.url)
            end
        end
        NetworkMgr:runWhenConnected(connect_callback)
    end
    return true
end

-- Menu action on item long-press
-- Root list:    Force sync / Sync / Edit / Delete (existing behavior).
-- Inside catalog, navigation entry: Maki "Download all here" — bulk-download every
-- acquisition under this folder into <sync_dir>/<folder name>/<sub.../>file.
function OPDSBrowser:onMenuHold(item)
    -- At root: keep existing catalog-management dialog.
    if #self.paths == 0 then
        if item.idx == 1 then return true end -- Downloads item, skip
        local dialog
        dialog = ButtonDialog:new{
            title = item.text,
            title_align = "center",
            buttons = {
                {
                    {
                        text = _("Force sync"),
                        callback = function()
                            UIManager:close(dialog)
                            NetworkMgr:runWhenConnected(function()
                                self._manager:launchSync{ manual = true, server_index = item.idx - 1, ignore_ledger = true }
                            end)
                        end,
                    },
                    {
                        text = _("Sync"),
                        callback = function()
                            UIManager:close(dialog)
                            NetworkMgr:runWhenConnected(function()
                                self._manager:launchSync{ manual = true, server_index = item.idx - 1 }
                            end)
                        end,
                    },
                },
                {},
                {
                    {
                        text = _("Delete"),
                        callback = function()
                            UIManager:show(ConfirmBox:new{
                                text = _("Delete OPDS catalog?"),
                                ok_text = _("Delete"),
                                ok_callback = function()
                                    UIManager:close(dialog)
                                    self:deleteCatalog(item)
                                end,
                            })
                        end,
                    },
                    {
                        text = _("Edit"),
                        callback = function()
                            UIManager:close(dialog)
                            self:addEditCatalog(item)
                        end,
                    },
                },
            },
        }
        UIManager:show(dialog)
        return true
    end

    -- Inside a catalog. Only offer bulk download for navigation/folder entries.
    if item.acquisitions and item.acquisitions[1] then
        return true -- book entry; nothing to long-press for
    end
    if not item.url then return true end

    local dialog
    local rows = {{
        {
            text = _("Download all here"),
            callback = function()
                UIManager:close(dialog)
                NetworkMgr:runWhenConnected(function()
                    self:downloadAllHere(item)
                end)
            end,
        },
    }}
    -- Start point: opening the catalog from the server list jumps straight
    -- to this feed (e.g. the Manga library) instead of the root feed.
    local server = self:getCurrentServer()
    if server then
        local is_home = server.home_url == item.url
        rows[#rows + 1] = {
            {
                text = is_home and _("Unset as start point")
                                or _("Set as start point"),
                callback = function()
                    UIManager:close(dialog)
                    if is_home then
                        server.home_url, server.home_title = nil, nil
                    else
                        server.home_url = item.url
                        server.home_title = item.title or item.text
                    end
                    self._manager.updated = true
                    self._manager:saveSettings()
                    UIManager:show(Notification:new{
                        text = is_home
                            and T(_("'%1' opens at its root feed again."), server.title)
                            or  T(_("'%1' now opens at '%2'."),
                                  server.title, item.title or item.text),
                    })
                end,
            },
        }
    end
    dialog = ButtonDialog:new{
        title = item.title or item.text,
        title_align = "center",
        buttons = rows,
    }
    UIManager:show(dialog)
    return true
end

-- Menu action on return-arrow tap (go to one-level upper catalog)
function OPDSBrowser:onReturn()
    table.remove(self.paths)
    local path = self.paths[#self.paths]
    if path then
        -- return to last path
        self.catalog_title = path.title
        self:updateCatalog(path.url, true)
    else
        -- return to root path, we simply reinit opdsbrowser
        self:init()
    end
    return true
end

-- Menu action on return-arrow long-press (return to root path)
function OPDSBrowser:onHoldReturn()
    self:init()
    return true
end

-- Menu action on next-page chevron tap (request and show more catalog entries)
function OPDSBrowser:onNextPage(fill_only)
    -- self.page_num comes from menu.lua
    local page_num = self.page_num
    -- fetch more entries until we fill out one page or reach the end
    while page_num == self.page_num do
        local hrefs = self.item_table.hrefs
        if hrefs and hrefs.next then
            if not self:appendCatalog(hrefs.next) then
                break  -- reach end of paging
            end
        else
            break
        end
    end
    if not fill_only then
        -- We also *do* want to paginate, so call the base class.
        Menu.onNextPage(self)
    end
    return true
end

function OPDSBrowser:showDownloadList()
    self.download_list = Menu:new{
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuSelect = self.showDownloadListItemDialog,
        _manager = self,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = self.showDownloadListMenu
    }
    self.download_list.close_callback = function()
        UIManager:close(self.download_list)
        self.download_list = nil
        if self.download_list_updated then
            self.download_list_updated = nil
            self.item_table[1].mandatory = #self.downloads
            self:updateItems(1, true)
        end
    end
    self:updateDownloadListItemTable()
    UIManager:show(self.download_list)
end

function OPDSBrowser:showDownloadListMenu()
    local dialog
    dialog = ButtonDialog:new{
        buttons = {
            {{
                    text = _("Download all"),
                    callback = function()
                        UIManager:close(dialog)
                        self._manager:confirmDownloadDownloadList()
                    end,
                    align = "left",
            }},
            {{
                    text = _("Remove all"),
                    callback = function()
                        UIManager:close(dialog)
                        self._manager:confirmClearDownloadList()
                    end,
                    align = "left",
            }},
        },
        shrink_unneeded_width = true,
        anchor = function()
            return self.title_bar.left_button.image.dimen
        end,
    }
    UIManager:show(dialog)
end

function OPDSBrowser:updateDownloadListItemTable(item_table)
    if item_table == nil then
        item_table = {}
        for i, item in ipairs(self.downloads) do
            item_table[i] = {
                text      = item.file:gsub(".*/", ""),
                mandatory = item.catalog,
            }
        end
    end
    local title = T(_("Downloads (%1)"), #item_table)
    self.download_list:switchItemTable(title, item_table)
end

function OPDSBrowser:confirmDownloadDownloadList()
    UIManager:show(ConfirmBox:new{
        text = _("Download all books?\nExisting files will be overwritten."),
        ok_text = _("Download"),
        ok_callback = function()
            NetworkMgr:runWhenConnected(function()
                Trapper:wrap(function()
                    self:downloadDownloadList()
                end)
            end)
        end,
    })
end

function OPDSBrowser:confirmClearDownloadList()
    UIManager:show(ConfirmBox:new{
        text = _("Remove all downloads?"),
        ok_text = _("Remove"),
        ok_callback = function()
            for i in ipairs(self.downloads) do
                self.downloads[i] = nil
            end
            self.download_list_updated = true
            self._manager.updated = true
            self.download_list:close_callback()
        end,
    })
end

function OPDSBrowser:showDownloadListItemDialog(item)
    local dl_item = self._manager.downloads[item.idx]
    local textviewer
    local function remove_item()
        textviewer:onClose()
        table.remove(self._manager.downloads, item.idx)
        table.remove(self.item_table, item.idx)
        self._manager:updateDownloadListItemTable(self.item_table)
        self._manager.download_list_updated = true
        self._manager._manager.updated = true
    end
    local buttons_table = {
        {
            {
                text = _("Remove"),
                callback = function()
                    remove_item()
                end,
            },
            {
                text = _("Download"),
                callback = function()
                    local function file_downloaded_callback(local_path)
                        remove_item()
                        self._manager.file_downloaded_callback(local_path)
                    end
                    NetworkMgr:runWhenConnected(function()
                        self._manager:checkDownloadFile(dl_item.file, dl_item.url, dl_item.username, dl_item.password, file_downloaded_callback)
                    end)
                end,
            },
        },
        {}, -- separator
        {
            {
                text = _("Remove all"),
                callback = function()
                    textviewer:onClose()
                    self._manager:confirmClearDownloadList()
                end,
            },
            {
                text = _("Download all"),
                callback = function()
                    textviewer:onClose()
                    self._manager:confirmDownloadDownloadList()
                end,
            },
        },
    }
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local text = table.concat({
        TextBoxWidget.PTF_HEADER,
        TextBoxWidget.PTF_BOLD_START, _("Folder"), TextBoxWidget.PTF_BOLD_END, "\n",
        util.splitFilePathName(dl_item.file), "\n", "\n",
        TextBoxWidget.PTF_BOLD_START, _("File"), TextBoxWidget.PTF_BOLD_END, "\n",
        item.text, "\n", "\n",
        TextBoxWidget.PTF_BOLD_START, _("Description"), TextBoxWidget.PTF_BOLD_END, "\n",
        dl_item.info,
    })
    textviewer = TextViewer:new{
        title = dl_item.catalog,
        text = text,
        text_type = "book_info",
        buttons_table = buttons_table,
    }
    UIManager:show(textviewer)
    return true
end

-- Download whole download list
function OPDSBrowser:downloadDownloadList()
    local info = InfoMessage:new{ text = _("Downloading… (tap to cancel)") }
    UIManager:show(info)
    UIManager:forceRePaint()
    local completed, downloaded = Trapper:dismissableRunInSubprocess(function()
        local dl = {}
        for _, item in ipairs(self.downloads) do
            -- quiet: we're in a forked subprocess and there is a summary
            -- below; per-file dialogs from here would stack unboundedly.
            if self:downloadFile(item.file, item.url, item.username, item.password, nil, true) then
                dl[item.file] = true
            end
        end
        return dl
    end, info)
    if completed then
        UIManager:close(info)
    end
    local dl_count = #self.downloads
    for i = dl_count, 1, -1 do
        local item = self.downloads[i]
        if downloaded and downloaded[item.file] then
            table.remove(self.downloads, i)
        else -- if subprocess has been interrupted, check for the downloaded file
            local attr = lfs.attributes(item.file)
            if attr then
                if attr.size > 0 then
                    table.remove(self.downloads, i)
                else -- incomplete download
                    os.remove(item.file)
                end
            end
        end
    end
    dl_count = dl_count - #self.downloads
    if dl_count > 0 then
        self:updateDownloadListItemTable()
        self.download_list_updated = true
        self._manager.updated = true
        UIManager:show(Notification:new{ text = T(N_("1 book downloaded", "%1 books downloaded", dl_count), dl_count) })
    end
end

function OPDSBrowser:setMaxSyncDownload()
    local current_max_dl = self.settings.sync_max_dl or 50
    local spin = SpinWidget:new{
        title_text = "Set maximum sync size",
        info_text = "Set the max number of books to download at a time",
        value = current_max_dl,
        value_min = 0,
        value_max = 1000,
        value_step = 10,
        value_hold_step = 50,
        default_value = 50,
        wrap = true,
        ok_text = "Save",
        callback = function(spin)
            self.settings.sync_max_dl = spin.value
            self._manager.updated = true
        end,
    }
    UIManager:show(spin)
end

function OPDSBrowser:setSyncDir()
    local force_chooser_dir
    if Device:isAndroid() then
        force_chooser_dir = Device.home_dir
    end

    require("ui/downloadmgr"):new{
        onConfirm = function(inbox)
            logger.info("set opds sync folder", inbox)
            self.settings.sync_dir = inbox
            self._manager.updated = true
        end,
    }:chooseDir(force_chooser_dir)
end

-- Set string for desired filetypes
function OPDSBrowser:setSyncFiletypes(filetype_list)
    local input = self.settings.filetypes
    local dialog
    dialog = InputDialog:new{
        title = _("File types to sync"),
        description = _("A comma separated list of desired filetypes"),
        input_hint = _("epub, mobi"),
        input = input,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local str = dialog:getInputText()
                        self.settings.filetypes = str ~= "" and str or nil
                        self._manager.updated = true
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Helper function to get filename and set nil if using raw names
function OPDSBrowser:getFileName(item)
    local filename = item.title
    if item.author then
        filename = item.author .. " - " .. filename
    end
    local filename_orig = filename
    if self.root_catalog_raw_names then
        filename = nil
    end
    return util.replaceAllInvalidChars(filename), util.replaceAllInvalidChars(filename_orig)
end

function OPDSBrowser:updateFieldInCatalog(item, name, value)
    item[name] = value
    self._manager.updated = true
end

-- ─── Maki: bulk download with breadcrumb-based folder structure ─────────────

-- Find the currently-entered root server config by title.
function OPDSBrowser:getCurrentServer()
    if not self.root_catalog_title then return nil end
    for _, server in ipairs(self.servers) do
        if server.title == self.root_catalog_title then return server end
    end
    return nil
end

-- Recursively walk an OPDS feed, collecting downloadable acquisitions plus the
-- breadcrumb (folder names) that describe where each one should go on disk.
-- Stops walking once `limit` items have been collected.
function OPDSBrowser:walkFeedForBulk(item_url, breadcrumb, results, limit, on_progress, feed_root)
    feed_root = feed_root or item_url
    if #results >= limit or results._cancelled then return end

    -- Tell the caller what we're about to scan. on_progress can return false
    -- to abort (the user tapped the InfoMessage and confirmed cancel).
    if on_progress then
        local where = breadcrumb[#breadcrumb] or self.root_catalog_title or "catalog"
        local go = on_progress(#results, where)
        if go == false then results._cancelled = true; return end
    end

    local item_table = self:genItemTableFromURL(item_url)
    if not item_table then return end

    for _, item in ipairs(item_table) do
        if #results >= limit or results._cancelled then return end
        if item.acquisitions and item.acquisitions[1] then
            -- Acquisition entry: pick the first viable file link.
            for _, acq in ipairs(item.acquisitions) do
                if acq.href and acq.type and acq.type ~= "borrow" then
                    local filetype = OPDSBrowser.getFiletype(acq)
                    if filetype then
                        table.insert(results, {
                            url        = acq.href,
                            title      = item.title or item.text or "Untitled",
                            filetype   = filetype,
                            breadcrumb = breadcrumb,
                            feed       = feed_root,
                        })
                        -- Tick the counter as items are collected, not just
                        -- once per feed page — otherwise a single-series
                        -- download sits on "0 file(s) found" for the whole
                        -- scan.
                        if on_progress then
                            local go = on_progress(#results,
                                breadcrumb[#breadcrumb] or self.root_catalog_title or "catalog")
                            if go == false then results._cancelled = true; return end
                        end
                        break
                    end
                end
            end
        elseif item.url then
            -- Navigation entry: recurse into the sub-feed with the entry's
            -- title appended to the breadcrumb so its contents nest below it.
            local new_crumb = {}
            for _, c in ipairs(breadcrumb) do table.insert(new_crumb, c) end
            table.insert(new_crumb, sanitize_segment(item.title or item.text))
            self:walkFeedForBulk(item.url, new_crumb, results, limit, on_progress, item.url)
        end
    end
    -- Follow rel=next pagination for the same level.
    if item_table.hrefs and item_table.hrefs.next and #results < limit and not results._cancelled then
        self:walkFeedForBulk(item_table.hrefs.next, breadcrumb, results, limit, on_progress, feed_root)
    end
end

-- Long-press → "Download all here" entry point.
-- `item` is a navigation entry; we walk its subtree and download every file
-- into <server_sync_dir>/<item.title>/<…sub-breadcrumb…>/file.ext.
function OPDSBrowser:downloadAllHere(item)
    local server = self:getCurrentServer()
    local base_dir = (server and server.sync_dir) or self.settings.sync_dir
    if not base_dir or base_dir == "" then
        UIManager:show(InfoMessage:new{
            text = _("No sync folder set for this catalog.\n\nLong-press the catalog at the root list and choose 'Set sync folder', or set a global sync folder under Maki settings."),
        })
        return
    end

    local seed_title = sanitize_segment(item.title or item.text)
    local start_url = item.url
    local breadcrumb = { seed_title }

    UIManager:show(ConfirmBox:new{
        text = T(_("Bulk-download everything inside '%1' into:\n%2/%3/"),
                 item.title or item.text, base_dir, seed_title),
        ok_text = _("Download"),
        ok_callback = function()
            Trapper:wrap(function()
                self:runBulkDownload(start_url, breadcrumb, base_dir)
            end)
        end,
    })
end

-- ── Bulk download ────────────────────────────────────────────────────────
-- The bulk fetch runs in parallel worker subprocesses (same fork mechanism
-- as Trapper:dismissableRunInSubprocess). The old implementation was
-- UI-bound, not network-bound: every file cost one Trapper:info in the
-- "Preparing" HEAD pass and another in the download loop, and each of those
-- is a full e-ink repaint plus a mandatory 0.1s dismiss-check yield —
-- ~0.5s/file of pure overhead before any bytes moved. Now the workers run
-- flat out and the parent only repaints a small progress dialog every
-- BULK_UI_INTERVAL seconds.

local BULK_WORKERS = 3        -- parallel download subprocesses
local BULK_UI_INTERVAL = 2.5  -- min seconds between progress repaints

-- Resolve the server-side filename for one plan item (HEAD over the
-- keepalive connection), skip it if already on disk, otherwise download to
-- `part_path` and rename into place. Returns "ok"/"skip"/"fail", filename.
-- UI-free: runs inside worker subprocesses.
function OPDSBrowser:_bulkFetchOne(ka, p, part_path)
    util.makePath(p.dir)
    local filename
    local headers = ka and ka:headURL(p.url)
    if headers then
        filename = OPDSBrowser.fileNameFromHeaders(headers, p.url, p.filetype)
    else
        filename = self:getServerFileName(p.url, p.filetype)
    end
    filename = util.getSafeFilename(filename, p.dir)
    local target = util.fixUtf8(p.dir .. "/" .. filename, "_")
    if lfs.attributes(target) then
        return "skip", filename
    end
    local ok
    if ka then
        ok = ka:downloadURL(p.url, part_path)
        if ok == nil then -- host mismatch: fall back to the plain client
            ok = self:downloadFile(part_path, p.url, self.root_catalog_username,
                                   self.root_catalog_password, nil, true)
        end
    else
        ok = self:downloadFile(part_path, p.url, self.root_catalog_username,
                               self.root_catalog_password, nil, true)
    end
    if ok and lfs.attributes(part_path) and os.rename(part_path, target) then
        return "ok", filename
    end
    pcall(os.remove, part_path)
    return "fail", filename
end

-- Fetch every plan item with BULK_WORKERS forked subprocesses. The parent
-- polls per-worker manifest files for progress, keeps the UI responsive
-- (tap → confirm-cancel), and repaints at most every BULK_UI_INTERVAL.
-- Returns results (idx → {status, name}), cancelled — or nil if fork is
-- unavailable (caller falls back to the sequential path).
function OPDSBrowser:_bulkFetchParallel(plan)
    if #plan < 2 then return nil end
    -- Never fork inside an Android app process: our exiting workers race
    -- ART's "process reaper" thread over waitpid()/mutex state and the whole
    -- app SIGABRTs (observed on the Boox Go 10.3: "FORTIFY:
    -- pthread_mutex_lock called on a destroyed mutex" in tid "process
    -- reaper"). Android takes the sequential keepalive path instead; true
    -- parallelism is reserved for POSIX platforms (Kindle etc.).
    if Device:isAndroid() then return nil end
    local _coroutine = coroutine.running()
    if not _coroutine then return nil end
    local n_workers = math.min(BULK_WORKERS, #plan)
    local tmp_dir = DataStorage:getDataDir() .. "/cache"
    util.makePath(tmp_dir)
    local stamp = tostring(os.time())
    local base_url = plan[1].url:match("^(https://[^/]+)") or ""
    local username, password = self.root_catalog_username, self.root_catalog_password

    local manifests, workers = {}, {}
    for k = 1, n_workers do
        manifests[k] = string.format("%s/maki-bulk-%s-%d.tsv", tmp_dir, stamp, k)
        pcall(os.remove, manifests[k])
        local manifest_path = manifests[k]
        local slice = MakiBulk.workerSlice(#plan, n_workers, k)
        local worker_id = k
        local pid = ffiUtil.runInSubProcess(function()
            local mf = io.open(manifest_path, "a")
            if not mf then return end
            local ka = MakiHTTP.Client:new{
                base_url = base_url,
                username = username,
                password = password,
            }
            for _, idx in ipairs(slice) do
                local p = plan[idx]
                local part = p.dir .. "/.maki-part-" .. worker_id
                mf:write("part\t", idx, "\t", part, "\n")
                mf:flush()
                local ok_run, status, name = pcall(self._bulkFetchOne, self, ka, p, part)
                if not ok_run then
                    logger.warn("Maki bulk worker error:", status)
                    status, name = "fail", nil
                end
                mf:write(status, "\t", idx, "\t", name or "", "\n")
                mf:flush()
            end
            if ka then ka:close() end
            mf:close()
        end)
        if not pid then
            for _, w in ipairs(workers) do ffiUtil.terminateSubProcess(w.pid) end
            for _, m in ipairs(manifests) do pcall(os.remove, m) end
            return nil
        end
        workers[#workers + 1] = { pid = pid }
    end

    local total = #plan
    local info_widget
    local function show_progress(text)
        if info_widget then UIManager:close(info_widget) end
        info_widget = InfoMessage:new{
            text = text,
            dismiss_callback = function()
                info_widget = nil -- the tap already closed it
                coroutine.resume(_coroutine, "dismiss")
            end,
            flush_events_on_show = true,
        }
        UIManager:show(info_widget)
        UIManager:forceRePaint()
    end
    local function read_manifests()
        local results, orphans = {}, {}
        for _, m in ipairs(manifests) do
            local f = io.open(m, "r")
            if f then
                MakiBulk.parseManifest(f:read("*a"), results, orphans)
                f:close()
            end
        end
        return results, orphans
    end
    local function progress_text(results)
        local done, new_n, have_n, fail_n = 0, 0, 0, 0
        for _, r in pairs(results) do
            done = done + 1
            if r.status == "ok" then new_n = new_n + 1
            elseif r.status == "skip" then have_n = have_n + 1
            else fail_n = fail_n + 1 end
        end
        return T(_("Downloading %1 / %2 (%3 at a time)\n%4 new · %5 already present · %6 failed\nTap to cancel"),
                 done, total, n_workers, new_n, have_n, fail_n), done
    end

    local cancelled = false
    local results = {}
    show_progress(T(_("Downloading %1 file(s), %2 at a time…\nTap to cancel"), total, n_workers))
    local last_paint_s = time.to_s(time.now())
    local last_done = -1
    while true do
        local tick = function() coroutine.resume(_coroutine, "tick") end
        UIManager:scheduleIn(0.5, tick)
        local reason = coroutine.yield()
        if reason == "dismiss" then
            UIManager:unschedule(tick)
            -- Workers keep downloading while the user decides.
            local confirm = ConfirmBox:new{
                text = _("Stop the bulk download?"),
                ok_text = _("Stop"),
                cancel_text = _("Continue"),
                ok_callback = function() coroutine.resume(_coroutine, "stop") end,
                cancel_callback = function() coroutine.resume(_coroutine, "go") end,
                flush_events_on_show = true,
            }
            UIManager:show(confirm)
            local answer = coroutine.yield()
            UIManager:close(confirm)
            if answer == "stop" then
                cancelled = true
                for _, w in ipairs(workers) do
                    if not w.done then ffiUtil.terminateSubProcess(w.pid) end
                end
                break
            end
            show_progress((progress_text(read_manifests())))
            last_paint_s = time.to_s(time.now())
        else
            results = read_manifests()
            local all_done = true
            for _, w in ipairs(workers) do
                if not w.done and ffiUtil.isSubProcessDone(w.pid) then w.done = true end
                if not w.done then all_done = false end
            end
            if all_done then break end
            local text, done = progress_text(results)
            if done ~= last_done
               and time.to_s(time.now()) - last_paint_s >= BULK_UI_INTERVAL then
                show_progress(text)
                last_paint_s = time.to_s(time.now())
                last_done = done
            end
        end
    end

    -- Final manifest read (workers may have written after our last poll),
    -- then clean up temp part files and manifests.
    local orphans
    results, orphans = read_manifests()
    for _, part in ipairs(orphans) do pcall(os.remove, part) end
    for _, m in ipairs(manifests) do pcall(os.remove, m) end
    if cancelled then
        -- Terminated workers still need reaping so they don't linger as
        -- zombies; poll in the background, no hurry.
        local collect
        collect = function()
            local pending = false
            for _, w in ipairs(workers) do
                if not w.done then
                    if ffiUtil.isSubProcessDone(w.pid) then w.done = true
                    else pending = true end
                end
            end
            if pending then UIManager:scheduleIn(2, collect) end
        end
        UIManager:scheduleIn(2, collect)
    end
    if info_widget then UIManager:close(info_widget) end
    UIManager:forceRePaint()
    return results, cancelled
end

-- Sequential fallback for platforms where fork is unavailable. Same
-- per-item logic; progress via Trapper:info, throttled to one repaint per
-- BULK_UI_INTERVAL (fast_refresh keeps even those cheap).
function OPDSBrowser:_bulkFetchSequential(plan)
    local ka = MakiHTTP.Client:new{
        base_url = plan[1] and plan[1].url:match("^(https://[^/]+)") or "",
        username = self.root_catalog_username,
        password = self.root_catalog_password,
    }
    local results = {}
    local cancelled = false
    local last_paint_s = 0
    for i, p in ipairs(plan) do
        local now_s = time.to_s(time.now())
        if now_s - last_paint_s >= BULK_UI_INTERVAL then
            local go = Trapper:info(T(_("Downloading %1 / %2\n%3"), i, #plan, p.title or ""),
                                    last_paint_s > 0)
            if go == false then
                cancelled = true
                break
            end
            last_paint_s = now_s
        end
        local part = p.dir .. "/.maki-part-0"
        local ok_run, status, name = pcall(self._bulkFetchOne, self, ka, p, part)
        if not ok_run then status, name = "fail", nil end
        results[i] = { status = status, name = name }
    end
    if ka then ka:close() end
    return results, cancelled
end

-- Scan the subtree, plan target folders, then fetch everything in parallel.
-- Must be called inside Trapper:wrap.
function OPDSBrowser:runBulkDownload(start_url, breadcrumb, base_dir)
    local LIMIT = 5000

    -- Scan phase. Repaints are rationed: each Trapper:info is a full e-ink
    -- repaint plus a 0.1s dismiss-check yield, so never more than one a
    -- second no matter how fast entries are found.
    Trapper:info(_("Scanning catalog…"))
    local found = {}
    local last_label, last_painted, last_paint_s = nil, -1, 0
    local function scan_progress(count, where)
        local due = (where ~= last_label) or count <= 2 or (count - last_painted >= 10)
        local now_s = time.to_s(time.now())
        if due and now_s - last_paint_s >= 1 then
            last_label = where
            last_painted = count
            last_paint_s = now_s
            return Trapper:info(T(_("Scanning: %1\n%2 file(s) found"), where, count))
        end
        return true
    end
    self:walkFeedForBulk(start_url, breadcrumb, found, LIMIT, scan_progress)

    if found._cancelled then
        Trapper:reset()
        return
    end
    if #found == 0 then
        Trapper:reset()
        UIManager:show(InfoMessage:new{ text = _("No downloadable files found here.") })
        return
    end

    -- Plan target folders. Filenames are resolved per file by the workers
    -- themselves (one HEAD over their own keepalive connection, immediately
    -- before the GET) — there is no serial "Preparing" pass any more.
    local plan = {}
    for _, r in ipairs(found) do
        local parts = { base_dir }
        for _, c in ipairs(r.breadcrumb) do
            table.insert(parts, c)
        end
        table.insert(plan, {
            url      = r.url,
            dir      = table.concat(parts, "/"):gsub("//+", "/"),
            feed     = r.feed,
            title    = r.breadcrumb[#r.breadcrumb],
            filetype = r.filetype,
        })
    end

    Trapper:reset() -- close the scan dialog; the fetch drives its own widget
    local results, cancelled = self:_bulkFetchParallel(plan)
    if not results then
        results, cancelled = self:_bulkFetchSequential(plan)
        Trapper:reset()
    end

    -- Tally + record what each series folder now holds so auto-sync can
    -- follow it. Skipped files count as present for the marker: the ledger
    -- should reflect the folder, not just this run's transfers.
    local downloaded, skipped, failed = 0, 0, 0
    local by_dir = {}
    for idx, r in pairs(results or {}) do
        local p = plan[idx]
        if r.status == "ok" then downloaded = downloaded + 1
        elseif r.status == "skip" then skipped = skipped + 1
        else failed = failed + 1 end
        if p and r.name and (r.status == "ok" or r.status == "skip") then
            local b = by_dir[p.dir]
            if not b then
                b = { feed = p.feed, title = p.title, items = {} }
                by_dir[p.dir] = b
            end
            b.items[#b.items + 1] = { url = p.url, name = r.name }
        end
    end
    local server = self:getCurrentServer()
    if server then
        local now = os.time()
        for dir, b in pairs(by_dir) do
            local marker = Marker.read(dir) or { fetched = {} }
            marker.catalog = server.url
            marker.feed = b.feed
            marker.title = marker.title or b.title
            for _, it in ipairs(b.items) do
                Marker.markFetched(marker, it.url, it.name, now)
            end
            local ok, err = Marker.write(dir, marker)
            if not ok then logger.warn("Maki: marker write failed", dir, err) end
        end
    end

    UIManager:show(InfoMessage:new{
        text = T(_("Maki: bulk download %1.\n%2 downloaded\n%3 already present\n%4 failed\nInto: %5"),
                 cancelled and _("cancelled") or _("finished"),
                 downloaded, skipped, failed, base_dir),
        timeout = 6,
    })
    self._manager.updated = true
end

return OPDSBrowser
