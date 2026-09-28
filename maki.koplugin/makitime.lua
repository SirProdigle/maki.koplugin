-- makitime.lua
-- Pure timestamp helpers for OPDS change detection. No KOReader
-- dependencies, so tests/_test_makitime.lua can exercise them directly.
--
-- The UTC epoch is computed arithmetically (days-from-civil): os.time{}
-- interprets its table as *local* time, which would make the result depend
-- on the device's timezone setting.

local M = {}

local floor = math.floor

-- Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's
-- days_from_civil).
local function days_from_civil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

local function days_in_month(y, m)
    if m == 2 then
        local leap = (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
        return leap and 29 or 28
    end
    return (m == 4 or m == 6 or m == 9 or m == 11) and 30 or 31
end

-- Parse an ISO-8601 / RFC 3339 date-time with a zone designator
-- ("2026-05-14T03:40:29.471+01:00", "...Z", "+0100", "+01") into a UTC epoch
-- number (fractional seconds kept). Anything unparseable — including a
-- date-time with no zone, which is ambiguous — yields nil.
function M.parseISO8601(s)
    if type(s) ~= "string" then return nil end
    s = s:match("^%s*(.-)%s*$")
    local y, mo, d, h, mi, sec, rest =
        s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(.*)$")
    if not y then return nil end
    y, mo, d, h, mi, sec = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(sec)

    local frac = 0
    local fdigits, after = rest:match("^%.(%d+)(.*)$")
    if fdigits then
        frac = tonumber("0." .. fdigits)
        rest = after
    end

    local offset
    if rest == "Z" or rest == "z" then
        offset = 0
    else
        local sign, oh, om = rest:match("^([%+%-])(%d%d):?(%d%d)$")
        if not sign then
            sign, oh = rest:match("^([%+%-])(%d%d)$")
            om = "00"
        end
        if not sign then return nil end
        oh, om = tonumber(oh), tonumber(om)
        if oh > 23 or om > 59 then return nil end
        offset = (oh * 60 + om) * 60
        if sign == "-" then offset = -offset end
    end

    if mo < 1 or mo > 12 or d < 1 or d > days_in_month(y, mo)
       or h > 23 or mi > 59 or sec > 60 then
        return nil
    end

    local epoch = days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + sec - offset
    if frac ~= 0 then epoch = epoch + frac end
    return epoch
end

-- The raw <updated> text of a parsed OPDS entry, or nil. makiparser yields a
-- string for <updated>…</updated> and a table for an empty element.
function M.entryUpdated(entry)
    if type(entry) == "table" and type(entry.updated) == "string" then
        return entry.updated
    end
    return nil
end

return M
