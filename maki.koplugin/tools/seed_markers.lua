-- tools/seed_markers.lua — one-off: write baseline .maki.lua markers for
-- series folders that predate markers. Run from Maki's settings menu.
local Trapper = require("ui/trapper")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Marker = require("makimarker")
local _ = require("gettext")
local T = require("ffi/util").template

local M = {}

local function sanitize_segment(name)
    if not name or name == "" then return "Untitled" end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("[/\\%z%c]", "_")
    name = name:gsub("[<>:\"|%?%*]", "_")
    if name == "" or name == "." or name == ".." then return "Untitled" end
    return name
end

local function has_marker(dir)
    return lfs.attributes(Marker.path(dir), "mode") == "file"
end

-- Fetch a feed (all pages). Returns items (flat) and whether any item is an acquisition.
local function fetch_all(browser, url)
    local items, has_acq, page = {}, false, url
    local guard = 0
    while page do
        guard = guard + 1
        if guard > 200 then break end
        local ok, catalog = pcall(browser.parseFeed, browser, page)
        if not ok or not catalog then return nil end
        local tbl = browser:genItemTableFromCatalog(catalog, page)
        for _ignore, it in ipairs(tbl) do
            items[#items + 1] = it
            if it.acquisitions and it.acquisitions[1] then has_acq = true end
        end
        page = tbl.hrefs and tbl.hrefs.next or nil
    end
    return items, has_acq
end

-- Walk navigation levels; call on_series(title, feed_url, items) for each series feed.
local function walk(browser, url, on_series, depth, progress)
    if depth > 4 then return end
    local items, has_acq = fetch_all(browser, url)
    if not items then return end
    if has_acq then return end -- caller handles series feeds
    for _ignore, it in ipairs(items) do
        if it.url and not (it.acquisitions and it.acquisitions[1]) then
            if progress and progress(it.title or it.text or "") == false then return end
            local sub, sub_acq = fetch_all(browser, it.url)
            if sub and sub_acq then
                on_series(it.title or it.text or "Untitled", it.url, sub)
            elseif sub then
                walk(browser, it.url, on_series, depth + 1, progress)
            end
        end
    end
end

function M.run(plugin)
    local browser = plugin:_ensureBrowser()
    Trapper:wrap(function()
        local matched, unmatched, skipped = {}, {}, {}
        local now = os.time()
        for _ignore, srv in ipairs(plugin.servers) do
            local sync_dir = srv.sync_dir or plugin.settings.sync_dir
            if srv.sync and sync_dir then
                browser.root_catalog_username = srv.username
                browser.root_catalog_password = srv.password
                browser.root_catalog_title    = srv.title
                local folders = {}
                for name in lfs.dir(sync_dir) do
                    local p = sync_dir .. "/" .. name
                    if name:sub(1, 1) ~= "." and lfs.attributes(p, "mode") == "directory" then
                        folders[name] = p
                    end
                end
                local seen = {}
                walk(browser, srv.url, function(title, feed_url, items)
                    local folder = sanitize_segment(title)
                    local dir = folders[folder]
                    if not dir then return end
                    seen[folder] = true
                    if has_marker(dir) then skipped[#skipped + 1] = folder; return end
                    local marker = { catalog = srv.url, feed = feed_url, title = title, fetched = {} }
                    for _i, it in ipairs(items) do
                        local a = it.acquisitions and it.acquisitions[1]
                        if a and a.href then marker.fetched[a.href] = { at = now } end
                    end
                    local ok, err = Marker.write(dir, marker)
                    if ok then matched[#matched + 1] = folder
                    else logger.warn("seed_markers: write failed", dir, err) end
                end, 0, function(where)
                    return Trapper:info(T(_("Seeding markers…\n%1"), where))
                end)
                for name in pairs(folders) do
                    if not seen[name] then unmatched[#unmatched + 1] = name end
                end
            end
        end
        Trapper:reset()
        table.sort(matched); table.sort(unmatched); table.sort(skipped)
        local text = T(_("Matched (%1):\n%2\n\nUnmatched folders (%3):\n%4\n\nAlready had marker (%5):\n%6"),
            #matched, table.concat(matched, "\n"), #unmatched, table.concat(unmatched, "\n"),
            #skipped, table.concat(skipped, "\n"))
        UIManager:show(TextViewer:new{ title = _("Maki: seed markers"), text = text })
    end)
end

return M
