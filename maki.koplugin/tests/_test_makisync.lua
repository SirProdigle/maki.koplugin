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

print(string.format("%d/%d tests passed", pass, pass + fail))
if fail > 0 then os.exit(1) end
