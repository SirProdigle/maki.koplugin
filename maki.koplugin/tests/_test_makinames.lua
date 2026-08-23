-- tests/_test_makinames.lua
-- Usage: cd maki.koplugin && lua tests/_test_makinames.lua

local Names = dofile("makinames.lua")

local pass, fail = 0, 0
local function eq(input, expected)
    local got = Names.normalizeChapter(input)
    if got == expected then pass = pass + 1
    else
        fail = fail + 1
        io.stderr:write(string.format("FAIL  %s\n  expected %s, got %s\n",
            tostring(input), tostring(expected), tostring(got)))
    end
end

-- Suwayomi scanlator prefix dropped, number padded
eq("Unknown_Chapter 1.cbz",      "Chapter 0001.cbz")
eq("Unknown_Chapter 11.cbz",     "Chapter 0011.cbz")
eq("Official_Chapter 61.cbz",    "Chapter 0061.cbz")
-- fractional chapters keep the fraction attached
eq("Official_Chapter 61.5.cbz",  "Chapter 0061.5.cbz")
-- no prefix: still padded
eq("Chapter 2.cbz",              "Chapter 0002.cbz")
-- 4+ digit numbers pass through unpadded
eq("Chapter 1100.cbz",           "Chapter 1100.cbz")
-- already normalised → idempotent
eq("Chapter 0061.cbz",           "Chapter 0061.cbz")
-- non-scanlator head is kept
eq("Vol.3 Chapter 12.cbz",       "Vol.3 Chapter 0012.cbz")
-- trailing title kept after the number
eq("Chapter 12 - The Title.cbz", "Chapter 0012 - The Title.cbz")
-- lowercase / separator variants canonicalised
eq("chapter 5.cbz",              "Chapter 0005.cbz")
eq("Group_chapter_007.cbz",      "Chapter 0007.cbz")
-- not chapters: untouched
eq("Some Book.epub",             "Some Book.epub")
eq("Chapter.cbz",                "Chapter.cbz")
eq("c097.cbz",                   "c097.cbz")
eq(nil,                          nil)

print(string.format("makinames: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
