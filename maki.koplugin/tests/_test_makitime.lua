-- tests/_test_makitime.lua
-- Usage: cd maki.koplugin && lua tests/_test_makitime.lua

local Time = dofile("makitime.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

local function eq(got, want)
    assert(got == want, "got " .. tostring(got) .. ", want " .. tostring(want))
end

-- Reference epochs from `date -u -d ... +%s`.
local KOMGA_UTC = 1778726429 -- 2026-05-14T02:40:29Z

-- ─── parseISO8601 ────────────────────────────────────────────────────────

test("parse: Komga format with offset and milliseconds", function()
    local t = Time.parseISO8601("2026-05-14T03:40:29.471+01:00")
    assert(math.abs(t - (KOMGA_UTC + 0.471)) < 1e-6, tostring(t))
end)

test("parse: Z suffix", function()
    eq(Time.parseISO8601("2026-05-14T02:40:29Z"), KOMGA_UTC)
end)

test("parse: lowercase z and fractional seconds", function()
    local t = Time.parseISO8601("2026-05-14T02:40:29.5z")
    eq(t, KOMGA_UTC + 0.5)
end)

test("parse: negative and half-hour offsets", function()
    eq(Time.parseISO8601("2026-01-01T00:00:00-05:30"), 1767245400)
    eq(Time.parseISO8601("2026-05-14T00:40:29-02:00"), KOMGA_UTC)
end)

test("parse: offset without colon", function()
    eq(Time.parseISO8601("2026-05-14T03:40:29+0100"), KOMGA_UTC)
end)

test("parse: offset crossing a day and a leap day", function()
    eq(Time.parseISO8601("2000-03-01T01:59:59+02:00"), 951868799) -- 2000-02-29T23:59:59Z
end)

test("parse: epoch zero", function()
    eq(Time.parseISO8601("1970-01-01T00:00:00Z"), 0)
end)

test("parse: surrounding whitespace is tolerated", function()
    eq(Time.parseISO8601("  2026-05-14T02:40:29Z\n"), KOMGA_UTC)
end)

test("parse: independent of the process timezone", function()
    -- os.time{} would interpret a table as local time; the helper must not.
    local a = Time.parseISO8601("2026-05-14T02:40:29Z")
    local b = Time.parseISO8601("2026-05-14T02:40:29+00:00")
    eq(a, KOMGA_UTC); eq(b, KOMGA_UTC)
end)

test("parse: garbage yields nil", function()
    eq(Time.parseISO8601(nil), nil)
    eq(Time.parseISO8601(""), nil)
    eq(Time.parseISO8601("yesterday"), nil)
    eq(Time.parseISO8601(12345), nil)
    eq(Time.parseISO8601({}), nil)
    eq(Time.parseISO8601("2026-13-01T00:00:00Z"), nil)
    eq(Time.parseISO8601("2026-02-30T00:00:00Z"), nil)
    eq(Time.parseISO8601("2026-05-14T24:00:00Z"), nil)
    eq(Time.parseISO8601("2026-05-14T02:61:00Z"), nil)
    eq(Time.parseISO8601("2026-05-14T02:40:29+25:00"), nil)
    eq(Time.parseISO8601("2026-05-14T02:40:29Zjunk"), nil)
end)

test("parse: a date-time with no zone is ambiguous → nil", function()
    eq(Time.parseISO8601("2026-05-14T02:40:29"), nil)
end)

-- ─── entryUpdated (OPDS entry → raw <updated> string) ───────────────────

test("entryUpdated: returns the raw string", function()
    eq(Time.entryUpdated({ updated = "2026-05-14T03:40:29.471+01:00" }), "2026-05-14T03:40:29.471+01:00")
end)

test("entryUpdated: missing or non-string yields nil", function()
    eq(Time.entryUpdated({}), nil)
    eq(Time.entryUpdated({ updated = {} }), nil) -- empty <updated/> parses to a table
    eq(Time.entryUpdated(nil), nil)
end)

print(string.format("%d/%d tests passed", pass, pass + fail))
if fail > 0 then os.exit(1) end
