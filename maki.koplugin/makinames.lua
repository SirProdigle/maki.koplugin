-- makinames.lua
-- Chapter filename normalisation, shared by the bulk downloader and the
-- background sync (both reach it through getServerFileName) so the name a
-- file is saved under and the name the sync planner checks for on disk can
-- never diverge.
--
-- Suwayomi names chapter files "<scanlator>_<chapter name>.cbz", which for
-- sources with no scanlator yields "Unknown_Chapter 1.cbz" — ugly, and its
-- unpadded number sorts lexicographically as 1, 10, 11, …, 19, 2, 20.
-- We drop the scanlator prefix and zero-pad to four digits:
--   "Unknown_Chapter 1.cbz"      → "Chapter 0001.cbz"
--   "Official_Chapter 61.5.cbz"  → "Chapter 0061.5.cbz"
-- Anything that doesn't look like "…Chapter <n>…" passes through untouched,
-- so plain book downloads are unaffected.

local M = {}

function M.normalizeChapter(filename)
    if type(filename) ~= "string" then return filename end
    local stem, ext = filename:match("^(.*)(%.[^.]+)$")
    if not stem then stem, ext = filename, "" end
    local head, num = stem:match("^(.-)[Cc]hapter[%s_%.]*(%d+)")
    if not num then return filename end
    local tail = stem:match("^.-[Cc]hapter[%s_%.]*%d+(.*)$") or ""
    -- Keep a fractional chapter number ("61.5") attached to the number.
    local dec = tail:match("^(%.%d+)")
    if dec then tail = tail:sub(#dec + 1) end
    -- A head ending in "_" is a Suwayomi scanlator prefix — drop it. Any
    -- other head ("Vol.3 ") is real context — keep it.
    if head:match("_$") then head = "" end
    local padded = #num < 4 and (string.rep("0", 4 - #num) .. num) or num
    return head .. "Chapter " .. padded .. (dec or "") .. tail .. ext
end

return M
