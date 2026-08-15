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

-- Maki: after a reboot the WiFi interface comes up several seconds before the
-- DNS resolver is usable. NetworkMgr:isOnline() is already true at that point,
-- so a sync started then fails every queued file. Probe DNS and back off.
local DNS_RETRY_DELAY = 30      -- seconds between readiness probes
local DNS_MAX_RETRIES = 6       -- ~3 minutes of grace after connect
-- Coalesce the duplicate NetworkConnected events KOReader emits on associate.
local NETWORK_EVENT_DEBOUNCE = 10

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
    self.pending_syncs = self.opds_settings:readSetting("pending_syncs", {})
    self.sync_in_progress = false

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
        pending_syncs = self.pending_syncs,
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
    if self.sync_in_progress then
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

    -- Check if enough time has passed since last sync
    local now = os.time()
    local time_since_last = now - (self.settings.last_sync_time or 0)
    local min_interval = self.settings.sync_interval_hours * 3600

    if time_since_last < min_interval then
        logger.info("OPDS: Last sync too recent, skipping")
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

    self.sync_in_progress = true
    logger.info("OPDS: Starting auto-sync")

    -- Create browser instance if it doesn't exist
    if not self.opds_browser then
        self.opds_browser = OPDSBrowser:new{
            servers = self.servers,
            downloads = self.downloads,
            settings = self.settings,
            pending_syncs = self.pending_syncs,
            title = _("OPDS catalog"),
            is_popout = false,
            is_borderless = true,
            title_bar_fm_style = true,
            _manager = self,
        }
    end

    if self.opds_browser then
        self.opds_browser.sync_force = false
        self.opds_browser:checkSyncDownload(nil, true) -- Pass true for auto_sync
    end

    self.sync_in_progress = false
end

function OPDS:saveSettings()
    if self.updated then
        self.opds_settings:saveSetting("servers", self.servers)
        self.opds_settings:saveSetting("downloads", self.downloads)
        self.opds_settings:saveSetting("settings", self.settings)
        self.opds_settings:saveSetting("pending_syncs", self.pending_syncs)
        self.opds_settings:flush()
        self.updated = false
    end
end

function OPDS:onCloseWidget()
    UIManager:unschedule(self.periodic_sync_task)
    if self.dns_retry_task then UIManager:unschedule(self.dns_retry_task) end
    self:saveSettings()
end

return OPDS
