local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local LuaSettings = require("luasettings")
local OPDSBrowser = require("makibrowser")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local socket = require("socket")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template
local logger = require("logger")
local ffiutil = require("ffi/util")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local dump = require("dump")
local MakiSync = require("makisync")
local lfs = require("libs/libkoreader-lfs")

-- Maki: after a reboot the WiFi interface comes up several seconds before the
-- DNS resolver is usable. NetworkMgr:isOnline() is already true at that point,
-- so a sync started then fails every queued file. Probe DNS and back off.
local DNS_RETRY_DELAY = 30      -- seconds between readiness probes
local DNS_MAX_RETRIES = 6       -- ~3 minutes of grace after connect
-- Coalesce the duplicate NetworkConnected events KOReader emits on associate.
local NETWORK_EVENT_DEBOUNCE = 10
-- How often the parent checks on the forked sync child.
local SYNC_POLL_SECONDS = 2

local OPDS = WidgetContainer:extend{
    name = "maki",
    opds_settings_file = DataStorage:getSettingsDir() .. "/maki.lua",
    settings = nil,
    servers = nil,
    downloads = nil,
    -- Add auto-sync task reference
    periodic_sync_task = nil,
    default_servers = {
        {
            title = "Project Gutenberg",
            url = "https://m.gutenberg.org/ebooks.opds/?format=opds",
        },
        {
            title = "Standard Ebooks",
            url = "https://standardebooks.org/feeds/opds",
        },
        {
            title = "ManyBooks",
            url = "http://manybooks.net/opds/index.php",
        },
        {
            title = "Internet Archive",
            url = "https://bookserver.archive.org/",
        },
        {
            title = "textos.info (Spanish)",
            url = "https://www.textos.info/catalogo.atom",
        },
        {
            title = "Gallica (French)",
            url = "https://gallica.bnf.fr/opds",
        },
    },
    -- Add default settings with auto-sync enabled
    default_settings = {
        sync_dir = nil,
        sync_max_dl = 50,
        filetypes = nil,
        -- Auto-sync settings with defaults
        auto_sync = true,           -- Enabled by default
        sync_interval_hours = 24,   -- Sync every 24 hours
        sync_on_network = true,     -- Sync when network connects
        sync_on_resume = true,      -- Sync when resuming from sleep
        last_sync_time = 0,         -- Track last sync time
    },
}

function OPDS:init()
    self.opds_settings = LuaSettings:open(self.opds_settings_file)
    if next(self.opds_settings.data) == nil then
        self.updated = true -- first run, force flush
    end
    self.servers = self.opds_settings:readSetting("servers", self.default_servers)
    self.downloads = self.opds_settings:readSetting("downloads", {})
    -- Initialize settings with defaults
    self.settings = self.opds_settings:readSetting("settings", self.default_settings)
    -- Ensure all default settings are present
    for k, v in pairs(self.default_settings) do
        if self.settings[k] == nil then
            self.settings[k] = v
            self.updated = true
        end
    end

    -- Initialize auto-sync
    self:initAutoSync()

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function OPDS:onDispatcherRegisterActions()
    Dispatcher:registerAction("maki_show_catalog",
        {category="none", event="ShowMakiCatalog", title=_("Maki catalog"), filemanager=true,}
    )
end

function OPDS:addToMainMenu(menu_items)
    if not self.ui.document then -- FileManager menu only
        menu_items.maki = {
            text = _("Maki (OPDS+)"),
            callback = function()
                self:onShowMakiCatalog()
            end,
        }
    end
end

function OPDS:onShowMakiCatalog()
    self.opds_browser = OPDSBrowser:new{
        servers = self.servers,
        downloads = self.downloads,
        settings = self.settings,
        title = _("OPDS catalog"),
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        _manager = self,
        file_downloaded_callback = function(file)
            self:showFileDownloadedDialog(file)
        end,
        close_callback = function()
            if self.opds_browser.download_list then
                self.opds_browser.download_list.close_callback()
            end
            UIManager:close(self.opds_browser)
            self.opds_browser = nil
            if self.last_downloaded_file then
                if self.ui.file_chooser then
                    local pathname = util.splitFilePathName(self.last_downloaded_file)
                    self.ui.file_chooser:changeToPath(pathname, self.last_downloaded_file)
                end
                self.last_downloaded_file = nil
            end
        end,
    }
    UIManager:show(self.opds_browser)
end

function OPDS:showFileDownloadedDialog(file)
    self.last_downloaded_file = file
    UIManager:show(ConfirmBox:new{
        text = T(_("File saved to:\n%1\nWould you like to read the downloaded book now?"), BD.filepath(file)),
        ok_text = _("Read now"),
        ok_callback = function()
            self.last_downloaded_file = nil
            self.opds_browser.close_callback()
            if self.ui.document then
                self.ui:switchDocument(file)
            else
                self.ui:openFile(file)
            end
        end,
    })
end

function OPDS:initAutoSync()
    -- Create periodic sync task
    self.periodic_sync_task = function()
        logger.info("OPDS: Running periodic sync check")
        self:performAutoSync()
        self:schedulePeriodicSync() 
    end

    -- Schedule initial sync
    if self.settings.auto_sync then
        self:schedulePeriodicSync()
        self:registerAutoSyncEvents()
    end
end

function OPDS:registerAutoSyncEvents()
    if self.settings.auto_sync then
        self.onNetworkConnected = self._onNetworkConnected
        self.onResume = self._onResume
    else
        self.onNetworkConnected = nil
        self.onResume = nil
    end
end

function OPDS:_onNetworkConnected()
    logger.info("OPDS: Network connected, checking auto-sync")
    if not self.settings.sync_on_network then return end
    -- Maki: KOReader fires NetworkConnected more than once per association.
    -- Without this, two syncs race each other on every boot.
    local now = os.time()
    if self.last_network_event and (now - self.last_network_event) < NETWORK_EVENT_DEBOUNCE then
        logger.info("OPDS: Ignoring duplicate NetworkConnected event")
        return
    end
    self.last_network_event = now
    self.dns_retries = 0
    UIManager:scheduleIn(0.5, function()
        self:performAutoSync()
    end)
end

function OPDS:_onResume()
    logger.info("OPDS: Resumed, checking auto-sync")
    if self.settings.sync_on_resume then
        self.dns_retries = 0
        UIManager:scheduleIn(2, function()
            self:performAutoSync()
        end)
    end
end

-- Maki: true if at least one sync-flagged server's hostname resolves. This is
-- the check NetworkMgr:isOnline() doesn't do — the interface being up says
-- nothing about whether the resolver has come back after a reboot.
function OPDS:syncHostsResolve()
    local checked = 0
    for _, srv in ipairs(self.servers) do
        if srv.sync and srv.url then
            local host = srv.url:match("^https?://([^/:]+)")
            if host then
                checked = checked + 1
                if socket.dns.toip(host) then return true end
                logger.info("OPDS: DNS not ready for", host)
            end
        end
    end
    if checked > 0 then return false end
    -- No sync host could be parsed — fall back to KOReader's generic probe
    -- rather than blocking the sync outright.
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr.canResolveHostnames then
        return NetworkMgr:canResolveHostnames()
    end
    return true
end

function OPDS:schedulePeriodicSync()
    UIManager:unschedule(self.periodic_sync_task)
    local interval_seconds = self.settings.sync_interval_hours * 3600
    UIManager:scheduleIn(interval_seconds, self.periodic_sync_task)
    logger.info("OPDS: Scheduled periodic sync in", interval_seconds, "seconds")
end

function OPDS:performAutoSync()
    if self.sync_pid then
        logger.info("OPDS: Sync already in progress, skipping")
        return
    end
    -- Maki: gate on per-server sync_dir, not the (often-unset) global one.
    local has_syncable = false
    for _, srv in ipairs(self.servers) do
        if srv.sync and (srv.sync_dir or self.settings.sync_dir) then
            has_syncable = true
            break
        end
    end
    if not has_syncable then
        logger.info("Maki: no sync-flagged server with a sync_dir, skipping auto-sync")
        return
    end

    -- Cap automatic runs to one successful run per interval.
    local due, why = MakiSync.shouldAutoSync(self.settings, os.time())
    if not due then
        logger.info("OPDS: auto-sync skipped:", why)
        return
    end

    -- Check network connectivity
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        logger.info("OPDS: Not online, skipping auto-sync")
        return
    end

    -- Maki: isOnline() isn't enough right after a reboot — the resolver lags
    -- the interface. Retry a few times before giving up quietly, rather than
    -- starting a sync that will fail on every single file.
    if not self:syncHostsResolve() then
        self.dns_retries = (self.dns_retries or 0) + 1
        -- A stable task reference, so a second trigger (resume + network
        -- connect) replaces the pending retry instead of stacking a new chain.
        self.dns_retry_task = self.dns_retry_task or function()
            self:performAutoSync()
        end
        UIManager:unschedule(self.dns_retry_task)
        if self.dns_retries <= DNS_MAX_RETRIES then
            logger.info("OPDS: DNS not ready, retry", self.dns_retries, "of",
                        DNS_MAX_RETRIES, "in", DNS_RETRY_DELAY, "s")
            UIManager:scheduleIn(DNS_RETRY_DELAY, self.dns_retry_task)
        else
            logger.warn("OPDS: DNS still unavailable after", DNS_MAX_RETRIES,
                        "retries, skipping auto-sync")
            self.dns_retries = 0
        end
        return
    end
    if self.dns_retry_task then UIManager:unschedule(self.dns_retry_task) end
    self.dns_retries = 0

    logger.info("OPDS: Starting auto-sync")
    self:launchSync{ manual = false }
end

-- Build the I/O dependency table makisync needs. Everything here is safe to
-- call from the forked child: no widgets, no UIManager.
function OPDS:_ensureBrowser()
    if not self.opds_browser then
        self.opds_browser = OPDSBrowser:new{
            servers = self.servers,
            downloads = self.downloads,
            settings = self.settings,
            title = _("OPDS catalog"),
            is_popout = false,
            is_borderless = true,
            title_bar_fm_style = true,
            _manager = self,
        }
    end
    return self.opds_browser
end

function OPDS:_syncDeps(progress_path)
    local browser = self:_ensureBrowser()
    local deps = {
        fetchFeed = function(feed_url)
            local ok, catalog = pcall(browser.parseFeed, browser, feed_url)
            if not ok or not catalog then return nil, tostring(catalog) end
            return browser:genItemTableFromCatalog(catalog, feed_url)
        end,
        fileName = function(item_url, filetype)
            local ok, name = pcall(browser.getServerFileName, browser, item_url, filetype)
            if not ok then return nil end
            return name
        end,
        filetype = function(acq) return OPDSBrowser.getFiletype(acq) end,
        download = function(item_url, path, username, password)
            util.makePath(path:match("^(.*)/[^/]+$"))
            local ok, why = browser:downloadFile(path, item_url, username, password, nil, true)
            if ok then return true end
            return false, why or "download failed"
        end,
        -- Credentials for fetchFeed/getServerFileName come from the browser's
        -- "current catalog" fields; runSync calls this before each server.
        useServer = function(srv)
            browser.root_catalog_username = srv.username
            browser.root_catalog_password = srv.password
            browser.root_catalog_title    = srv.title
        end,
        exists = function(p) return lfs.attributes(p) ~= nil end,
        remove = function(p) return os.remove(p) end,
        rename = function(a, b) return os.rename(a, b) end,
        now = os.time,
    }
    if progress_path then
        deps.progress = function(st)
            local f = io.open(progress_path, "w")
            if f then f:write(dump(st)); f:close() end
        end
    end
    return deps
end

-- opts: { manual = bool, server_index = n|nil, ignore_ledger = bool }
function OPDS:launchSync(opts)
    opts = opts or {}
    if self.sync_pid then
        if opts.manual then
            UIManager:show(InfoMessage:new{ text = _("Sync already running"), timeout = 3 })
        else
            logger.info("OPDS: Sync already in progress, skipping")
        end
        return
    end
    local progress_path
    if opts.manual then
        progress_path = DataStorage:getDataDir() .. "/cache/maki-progress.lua"
        os.remove(progress_path)
    end
    local deps = self:_syncDeps(progress_path)
    local servers, settings = self.servers, self.settings
    local run_opts = { server_index = opts.server_index, ignore_ledger = opts.ignore_ledger }

    local pid, fd = ffiutil.runInSubProcess(function(_pid, write_fd)
        local result = MakiSync.runSync(servers, settings, deps, run_opts)
        ffiutil.writeToFD(write_fd, dump(result), true)
    end, true)
    if not pid then
        logger.warn("Maki: could not fork sync:", fd)
        if opts.manual then
            UIManager:show(InfoMessage:new{ text = _("Maki: could not start sync"), timeout = 3 })
        end
        return
    end
    self.sync_pid, self.sync_fd = pid, fd
    self.sync_manual = opts.manual and true or false
    self.sync_progress_path = progress_path
    logger.info("Maki: sync started, pid", pid, "manual", self.sync_manual)

    if opts.manual then self:_showSyncProgress(_("Maki: starting sync…")) end
    self.sync_poll_task = self.sync_poll_task or function() self:_pollSync() end
    UIManager:scheduleIn(SYNC_POLL_SECONDS, self.sync_poll_task)
end

function OPDS:_showSyncProgress(text)
    if self.sync_widget then
        local w = self.sync_widget
        self.sync_widget = nil
        w.dismiss_callback = nil
        UIManager:close(w)
    end
    self.sync_widget = InfoMessage:new{
        text = text,
        dismiss_callback = function()
            self.sync_widget = nil
            self:cancelSync()
        end,
    }
    UIManager:show(self.sync_widget)
end

function OPDS:_closeSyncProgress()
    if self.sync_widget then
        local w = self.sync_widget
        self.sync_widget = nil
        w.dismiss_callback = nil
        UIManager:close(w)
    end
end

function OPDS:_pollSync()
    if not self.sync_pid then return end
    if not ffiutil.isSubProcessDone(self.sync_pid) then
        if self.sync_manual and self.sync_progress_path then
            local f = io.open(self.sync_progress_path, "r")
            if f then
                local src = f:read("*a"); f:close()
                local chunk = src and loadstring("return " .. src)
                local ok, st = pcall(chunk or function() end)
                if ok and type(st) == "table" and self.sync_widget then
                    self:_showSyncProgress(T(_("Maki: %1 (%2/%3)\n%4 downloaded — tap to cancel"),
                        st.title or "", st.series_index or 0, st.series_total or 0, st.downloaded or 0))
                end
            end
        end
        UIManager:scheduleIn(SYNC_POLL_SECONDS, self.sync_poll_task)
        return
    end

    local raw = self.sync_fd and ffiutil.readAllFromFD(self.sync_fd) or nil
    local result
    if raw and raw ~= "" then
        local chunk = loadstring("return " .. raw)
        local ok, r = pcall(chunk or function() end)
        if ok and type(r) == "table" then result = r end
    end
    result = result or { series = {}, downloaded = 0, failed = 0, adopted = 0,
                         aborted = true, reason = "no result from child" }
    local was_manual = self.sync_manual
    self.sync_pid, self.sync_fd, self.sync_manual = nil, nil, false
    if self.sync_progress_path then os.remove(self.sync_progress_path); self.sync_progress_path = nil end
    self:_closeSyncProgress()
    self:_finishSync(result, was_manual)
end

function OPDS:_finishSync(result, was_manual)
    logger.info("Maki: sync finished", "downloaded", result.downloaded, "failed", result.failed,
                "adopted", result.adopted, "aborted", tostring(result.aborted),
                "cancelled", tostring(result.cancelled), result.reason or "")
    if not result.aborted and not result.cancelled then
        self.settings.last_sync_time = os.time()
        self.updated = true
        self:saveSettings()
    end
    local series_with_new = 0
    for _, s in ipairs(result.series or {}) do
        if (s.downloaded or 0) > 0 then series_with_new = series_with_new + 1 end
    end
    if was_manual then
        UIManager:show(InfoMessage:new{
            text = T(_("Maki: %1 downloaded, %2 failed, %3 adopted%4"),
                     result.downloaded, result.failed, result.adopted,
                     result.cancelled and _("\n(cancelled)")
                        or (result.aborted and ("\n" .. tostring(result.reason)) or "")),
            timeout = 6,
        })
    elseif result.downloaded > 0 then
        Notification:notify(T(_("Maki: %1 new chapter(s) in %2 series"), result.downloaded, series_with_new))
    elseif result.aborted then
        logger.warn("Maki: auto-sync aborted:", result.reason)
    end
    if result.downloaded > 0 then self:_refreshFileManager() end
end

function OPDS:_refreshFileManager()
    if not (self.ui and self.ui.file_chooser) then return end
    local home = G_reader_settings:readSetting("home_dir")
    local target = home and home ~= "" and home or self.ui.file_chooser.path
    if target then self.ui.file_chooser:changeToPath(target) end
end

function OPDS:cancelSync()
    if not self.sync_pid then return end
    logger.info("Maki: cancelling sync pid", self.sync_pid)
    ffiutil.terminateSubProcess(self.sync_pid)
    -- the poller will reap it and report `cancelled`/partial results
end

function OPDS:onSuspend()
    if self.sync_pid then self:cancelSync() end
end

function OPDS:saveSettings()
    if self.updated then
        self.opds_settings:saveSetting("servers", self.servers)
        self.opds_settings:saveSetting("downloads", self.downloads)
        self.opds_settings:saveSetting("settings", self.settings)
        self.opds_settings:flush()
        self.updated = false
    end
end

function OPDS:onCloseWidget()
    if self.sync_pid then self:cancelSync() end
    if self.sync_poll_task then UIManager:unschedule(self.sync_poll_task) end
    UIManager:unschedule(self.periodic_sync_task)
    if self.dns_retry_task then UIManager:unschedule(self.dns_retry_task) end
    self:saveSettings()
end

return OPDS
