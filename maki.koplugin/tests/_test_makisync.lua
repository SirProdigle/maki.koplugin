-- tests/_test_makisync.lua
-- Usage: cd maki.koplugin && lua tests/_test_makisync.lua

package.loaded["logger"] = { dbg = function() end, info = function() end,
    warn = function() end, err = function() end }
package.loaded["dump"] = function(v) -- tiny serializer, enough for markers
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t ~= "table" then return tostring(v) end
    local parts = {}
    for k, val in pairs(v) do
        local ks = type(k) == "string" and string.format("[%q]", k) or "[" .. tostring(k) .. "]"
        parts[#parts + 1] = ks .. "=" .. package.loaded["dump"](val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local S = dofile("makisync.lua")

local function dofile_string(src) return assert(loadstring and loadstring(src) or load(src))() end

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

-- Build deps over an in-memory disk set and a url→filename map.
local function mkdeps(disk, names, log)
    log = log or {}
    return {
        exists = function(p) return disk[p] == true end,
        remove = function(p) disk[p] = nil; log[#log + 1] = "rm " .. p; return true end,
        fileName = function(url, filetype)
            log[#log + 1] = "head " .. url
            return names[url]
        end,
        now = function() return 100 end,
    }, log
end

local function entry(url, title) return { url = url, title = title or url, filetype = "cbz" } end

-- ─── planSeries ──────────────────────────────────────────────────────────

test("planSeries: url in ledger is skipped without HEAD", function()
    local deps, log = mkdeps({}, {})
    local marker = { fetched = { u1 = { file = "a.cbz", at = 1 } } }
    local plan = S.planSeries({ entry("u1") }, "/m/S", marker, deps)
    assert(#plan.to_fetch == 0 and plan.adopted == 0 and plan.changed == false)
    assert(#log == 0, "no HEAD expected")
end)

test("planSeries: file on disk is adopted, not fetched", function()
    local deps = mkdeps({ ["/m/S/a.cbz"] = true }, { u1 = "a.cbz" })
    local marker = { fetched = {} }
    local plan = S.planSeries({ entry("u1") }, "/m/S", marker, deps)
    assert(#plan.to_fetch == 0 and plan.adopted == 1 and plan.changed == true)
    assert(marker.fetched.u1.file == "a.cbz" and marker.fetched.u1.at == 100)
end)

test("planSeries: missing file is fetched with derived path", function()
    local deps = mkdeps({}, { u1 = "a.cbz" })
    local plan = S.planSeries({ entry("u1", "Chapter 1") }, "/m/S", { fetched = {} }, deps)
    assert(#plan.to_fetch == 1)
    local f = plan.to_fetch[1]
    assert(f.url == "u1" and f.file == "a.cbz" and f.path == "/m/S/a.cbz" and f.title == "Chapter 1")
end)

test("planSeries: leftover .part is removed and entry fetched", function()
    local disk = { ["/m/S/a.cbz.part"] = true }
    local deps, log = mkdeps(disk, { u1 = "a.cbz" })
    local plan = S.planSeries({ entry("u1") }, "/m/S", { fetched = {} }, deps)
    assert(#plan.to_fetch == 1)
    assert(disk["/m/S/a.cbz.part"] == nil)
end)

test("planSeries: fileName nil → entry skipped entirely", function()
    local deps = mkdeps({}, {})
    local marker = { fetched = {} }
    local plan = S.planSeries({ entry("u1") }, "/m/S", marker, deps)
    assert(#plan.to_fetch == 0 and plan.adopted == 0 and plan.changed == false)
    assert(marker.fetched.u1 == nil)
end)

test("planSeries: entries without url are ignored", function()
    local deps = mkdeps({}, {})
    local plan = S.planSeries({ { title = "nav only" } }, "/m/S", { fetched = {} }, deps)
    assert(#plan.to_fetch == 0)
end)

test("planSeries: mixed feed — new, gap, deleted, present", function()
    local disk = { ["/m/S/c3.cbz"] = true }
    local deps, log = mkdeps(disk, { u1 = "c1.cbz", u2 = "c2.cbz", u3 = "c3.cbz", u4 = "c4.cbz" })
    local marker = { fetched = { u1 = { file = "c1.cbz", at = 1 } } } -- c1 deleted on purpose
    local plan = S.planSeries({ entry("u1"), entry("u2"), entry("u3"), entry("u4") }, "/m/S", marker, deps)
    local urls = {}
    for _, f in ipairs(plan.to_fetch) do urls[#urls + 1] = f.url end
    assert(table.concat(urls, ",") == "u2,u4", table.concat(urls, ","))
    assert(plan.adopted == 1)
    assert(#log == 3, "HEAD only for u2,u3,u4; got " .. #log)
end)

-- ─── shouldAutoSync ──────────────────────────────────────────────────────

test("shouldAutoSync: never synced → true", function()
    assert(S.shouldAutoSync({ sync_interval_hours = 24 }, 1000) == true)
end)

test("shouldAutoSync: within interval → false, too recent", function()
    local ok, why = S.shouldAutoSync({ sync_interval_hours = 24, last_sync_time = 1000 }, 1000 + 3600)
    assert(ok == false and why == "too recent")
end)

test("shouldAutoSync: past interval → true", function()
    assert(S.shouldAutoSync({ sync_interval_hours = 24, last_sync_time = 1000 }, 1000 + 24 * 3600) == true)
end)

test("shouldAutoSync: missing interval defaults to 24h", function()
    local ok = S.shouldAutoSync({ last_sync_time = 1000 }, 1000 + 23 * 3600)
    assert(ok == false)
end)


-- ─── runSync ─────────────────────────────────────────────────────────────

-- Full fake world: markers in memory (via makimarker deps), feeds keyed by URL,
-- downloads succeed unless listed in `fail_urls`.
local function world(opts)
    opts = opts or {}
    local files, dirs = {}, {}
    local markers = {}   -- dir -> marker source
    local feeds = opts.feeds or {}
    local names = opts.names or {}
    local fail_urls = opts.fail_urls or {}
    local log = {}
    local marker_deps = {
        readFile = function(p) return markers[p] end,
        writeFile = function(p, c) markers[p] = c; log[#log + 1] = "mwrite " .. p; return true end,
        rename = function(a, b) markers[b] = markers[a]; markers[a] = nil; return true end,
        listDirs = function(p) return dirs[p] or {} end,
    }
    local deps = {
        marker = marker_deps,
        fetchFeed = function(url)
            log[#log + 1] = "feed " .. url
            local f = feeds[url]
            if not f then return nil, "404" end
            return f
        end,
        fileName = function(url) return names[url] end,
        filetype = function(acq) return acq.type ~= "borrow" and "cbz" or nil end,
        download = function(url, path)
            log[#log + 1] = "dl " .. url
            if fail_urls[url] then return false, "http 500" end
            files[path] = true; return true
        end,
        exists = function(p) return files[p] == true end,
        remove = function(p) files[p] = nil; return true end,
        rename = function(a, b) files[b] = files[a]; files[a] = nil; return true end,
        now = function() return 500 end,
    }
    local function seed_marker(dir, catalog, feed, fetched)
        markers[dir .. "/.maki.lua"] = "return " .. package.loaded["dump"]({
            catalog = catalog, feed = feed, title = dir:match("[^/]+$"), fetched = fetched or {} })
    end
    return { files = files, dirs = dirs, markers = markers, deps = deps, log = log, seed = seed_marker }
end

local function acq(url) return { url = url, acquisitions = { { href = url, type = "application/zip" } }, title = url } end
local function page(entries, next_url) local t = entries; t.hrefs = { next = next_url }; return t end

local SERVERS = { { title = "K", url = "C", sync = true, sync_dir = "/m", username = "u", password = "p" } }

test("runSync: downloads new chapters, writes ledger, renames .part", function()
    local w = world({ feeds = { fs = page({ acq("u1"), acq("u2") }) }, names = { u1 = "c1.cbz", u2 = "c2.cbz" } })
    w.dirs["/m"] = { "S" }; w.seed("/m/S", "C", "fs")
    local r = S.runSync(SERVERS, { sync_max_dl = 50 }, w.deps, {})
    assert(r.downloaded == 2 and r.failed == 0 and r.aborted == false, "r=" .. tostring(r.downloaded))
    assert(w.files["/m/S/c1.cbz"] and w.files["/m/S/c2.cbz"])
    assert(w.files["/m/S/c1.cbz.part"] == nil)
    local mk = dofile_string(w.markers["/m/S/.maki.lua"])
    assert(mk.fetched.u1.file == "c1.cbz" and mk.fetched.u2.at == 500)
    assert(r.series[1].title == "S" and r.series[1].downloaded == 2)
end)

test("runSync: follows pagination", function()
    local w = world({ feeds = { fs = page({ acq("u1") }, "fs2"), fs2 = page({ acq("u2") }) },
                      names = { u1 = "c1.cbz", u2 = "c2.cbz" } })
    w.dirs["/m"] = { "S" }; w.seed("/m/S", "C", "fs")
    local r = S.runSync(SERVERS, {}, w.deps, {})
    assert(r.downloaded == 2)
end)

test("runSync: ledger entries are skipped; nothing written when unchanged", function()
    local w = world({ feeds = { fs = page({ acq("u1") }) }, names = { u1 = "c1.cbz" } })
    w.dirs["/m"] = { "S" }; w.seed("/m/S", "C", "fs", { u1 = { file = "c1.cbz", at = 1 } })
    local r = S.runSync(SERVERS, {}, w.deps, {})
    assert(r.downloaded == 0)
    for _, l in ipairs(w.log) do assert(not l:match("^mwrite"), "marker must not be rewritten") end
end)

test("runSync: ignore_ledger re-fetches deleted chapters", function()
    local w = world({ feeds = { fs = page({ acq("u1") }) }, names = { u1 = "c1.cbz" } })
    w.dirs["/m"] = { "S" }; w.seed("/m/S", "C", "fs", { u1 = { file = "c1.cbz", at = 1 } })
    local r = S.runSync(SERVERS, {}, w.deps, { ignore_ledger = true })
    assert(r.downloaded == 1 and w.files["/m/S/c1.cbz"])
end)

test("runSync: sync_max_dl caps the run", function()
    local w = world({ feeds = { fs = page({ acq("u1"), acq("u2"), acq("u3") }) },
                      names = { u1 = "1.cbz", u2 = "2.cbz", u3 = "3.cbz" } })
    w.dirs["/m"] = { "S" }; w.seed("/m/S", "C", "fs")
    local r = S.runSync(SERVERS, { sync_max_dl = 2 }, w.deps, {})
    assert(r.downloaded == 2 and r.capped == true)
end)

test("runSync: consecutive failures abort, ledger progress kept", function()
    local w = world({ feeds = { fs = page({ acq("u1"), acq("u2"), acq("u3"), acq("u4") }) },
                      names = { u1 = "1.cbz", u2 = "2.cbz", u3 = "3.cbz", u4 = "4.cbz" },
                      fail_urls = { u2 = true, u3 = true } })
    w.dirs["/m"] = { "S" }; w.seed("/m/S", "C", "fs")
    local r = S.runSync(SERVERS, {}, w.deps, {})
    assert(r.downloaded == 1 and r.failed == 2 and r.aborted == true and r.reason == "http 500")
    local mk = dofile_string(w.markers["/m/S/.maki.lua"])
    assert(mk.fetched.u1 and not mk.fetched.u2)
    local dls = 0; for _, l in ipairs(w.log) do if l:match("^dl") then dls = dls + 1 end end
    assert(dls == 3, "u4 must not be attempted")
end)

test("runSync: one feed failing does not abort others; all failing aborts", function()
    local w = world({ feeds = { fb = page({ acq("u1") }) }, names = { u1 = "1.cbz" } })
    w.dirs["/m"] = { "A", "B" }; w.seed("/m/A", "C", "fa"); w.seed("/m/B", "C", "fb")
    local r = S.runSync(SERVERS, {}, w.deps, {})
    assert(r.downloaded == 1 and r.aborted == false)
    assert(r.series[1].feed_failed == true and r.series[2].downloaded == 1)
    local w2 = world({})
    w2.dirs["/m"] = { "A" }; w2.seed("/m/A", "C", "fa")
    local r2 = S.runSync(SERVERS, {}, w2.deps, {})
    assert(r2.aborted == true)
end)

test("runSync: server_index restricts to one server; unsynced servers ignored", function()
    local servers = {
        { title = "X", url = "CX", sync = false, sync_dir = "/x" },
        { title = "K", url = "C", sync = true, sync_dir = "/m" },
    }
    local w = world({ feeds = { fs = page({ acq("u1") }) }, names = { u1 = "1.cbz" } })
    w.dirs["/m"] = { "S" }; w.seed("/m/S", "C", "fs")
    local r = S.runSync(servers, {}, w.deps, { server_index = 2 })
    assert(r.downloaded == 1)
    local r0 = S.runSync(servers, {}, w.deps, { server_index = 1 })
    assert(r0.downloaded == 0 and r0.aborted == false)
end)

test("runSync: finds markers nested below the sync dir", function()
    local w = world({ feeds = { fs = page({ acq("u1") }) }, names = { u1 = "1.cbz" } })
    w.dirs["/m"] = { "Lib" }; w.dirs["/m/Lib"] = { "S" }
    w.seed("/m/Lib/S", "C", "fs")
    local r = S.runSync(SERVERS, {}, w.deps, {})
    assert(r.downloaded == 1 and w.files["/m/Lib/S/1.cbz"])
end)

test("runSync: a marked series folder is not descended into", function()
    local w = world({ feeds = { fs = page({ acq("u1") }) }, names = { u1 = "1.cbz" } })
    w.dirs["/m"] = { "S" }; w.dirs["/m/S"] = { "extras" }
    w.seed("/m/S", "C", "fs"); w.seed("/m/S/extras", "C", "fs")
    local r = S.runSync(SERVERS, {}, w.deps, {})
    assert(r.downloaded == 1, "the nested marker must be ignored")
end)

test("runSync: only series that did something are reported", function()
    local w = world({ feeds = { fa = page({ acq("u1") }), fb = page({ acq("u2") }) },
                      names = { u1 = "1.cbz", u2 = "2.cbz" } })
    w.dirs["/m"] = { "A", "B" }
    w.seed("/m/A", "C", "fa", { u1 = { file = "1.cbz", at = 1 } })  -- nothing to do
    w.seed("/m/B", "C", "fb")
    local r = S.runSync(SERVERS, {}, w.deps, {})
    assert(r.downloaded == 1)
    assert(#r.series == 1 and r.series[1].title == "B", "#series=" .. #r.series)
    assert(r.series[1].dir == nil, "dir is dead weight in the pipe")
end)

test("runSync: progress callback and cancel", function()
    local w = world({ feeds = { fs = page({ acq("u1"), acq("u2") }) }, names = { u1 = "1.cbz", u2 = "2.cbz" } })
    w.dirs["/m"] = { "S" }; w.seed("/m/S", "C", "fs")
    local seen = {}
    w.deps.progress = function(st) seen[#seen + 1] = st.downloaded end
    local calls = 0
    w.deps.cancelled = function() calls = calls + 1; return calls > 1 end
    local r = S.runSync(SERVERS, {}, w.deps, {})
    assert(r.downloaded == 1 and r.cancelled == true)
    assert(seen[1] == 1)
end)

print(string.format("%d/%d tests passed", pass, pass + fail))
if fail > 0 then os.exit(1) end
