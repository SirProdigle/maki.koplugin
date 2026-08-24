-- tests/_test_makibulk.lua
-- Usage: cd maki.koplugin && lua tests/_test_makibulk.lua

local Bulk = dofile("makibulk.lua")

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1
    else
        fail = fail + 1
        io.stderr:write("FAIL  " .. name .. "\n")
    end
end
local function eq_list(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- workerSlice: interleaved, disjoint, complete
check("slice 10/3 k=1", eq_list(Bulk.workerSlice(10, 3, 1), {1, 4, 7, 10}))
check("slice 10/3 k=2", eq_list(Bulk.workerSlice(10, 3, 2), {2, 5, 8}))
check("slice 10/3 k=3", eq_list(Bulk.workerSlice(10, 3, 3), {3, 6, 9}))
check("slice covers all", (function()
    local seen = {}
    for k = 1, 3 do
        for _, i in ipairs(Bulk.workerSlice(10, 3, k)) do
            if seen[i] then return false end
            seen[i] = true
        end
    end
    for i = 1, 10 do if not seen[i] then return false end end
    return true
end)())
check("slice single worker", eq_list(Bulk.workerSlice(4, 1, 1), {1, 2, 3, 4}))
check("slice more workers than items", eq_list(Bulk.workerSlice(2, 3, 3), {}))

-- parseManifest: results, superseded part lines, orphans
local into, orphans = Bulk.parseManifest(table.concat({
    "part\t1\t/x/.maki-part-1",
    "ok\t1\tChapter 0001.cbz",
    "part\t4\t/x/.maki-part-1",
    "skip\t4\tChapter 0004.cbz",
    "part\t7\t/x/.maki-part-1",
}, "\n"))
check("ok parsed", into[1] and into[1].status == "ok" and into[1].name == "Chapter 0001.cbz")
check("skip parsed", into[4] and into[4].status == "skip")
check("unfinished not a result", into[7] == nil)
check("orphan part collected", #orphans == 1 and orphans[1] == "/x/.maki-part-1")

-- fail line with empty name; accumulate across manifests
local into2 = Bulk.parseManifest("fail\t2\t\n", into)
check("fail parsed, nil name", into2[2] and into2[2].status == "fail" and into2[2].name == nil)
check("accumulates", into2[1] and into2[1].status == "ok")
check("empty text ok", (function()
    local r, o = Bulk.parseManifest(nil)
    return next(r) == nil and #o == 0
end)())

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
