-- makibulk.lua
-- Pure helpers for the parallel bulk downloader (makibrowser). No KOReader
-- dependencies, so tests/_test_makibulk.lua can exercise them directly.

local M = {}

-- Indices of plan items assigned to worker `k` (1-based) of `workers`:
-- interleaved so every worker advances through the series evenly and all
-- finish at roughly the same time.
function M.workerSlice(n_items, workers, k)
    local out = {}
    for i = k, n_items, workers do
        out[#out + 1] = i
    end
    return out
end

-- Parse one worker manifest (tab-separated: status, idx, name-or-path).
-- "part" lines mark a download about to start; a following result line for
-- the same idx supersedes them. Accumulates into `into` (idx → {status,
-- name}) and collects part paths that never got a result line — the
-- half-written temp files of a killed worker — into `orphan_parts`.
function M.parseManifest(text, into, orphan_parts)
    into = into or {}
    orphan_parts = orphan_parts or {}
    local pending = {}
    for line in (text or ""):gmatch("[^\n]+") do
        local status, idx, rest = line:match("^(%S+)\t(%d+)\t?(.*)$")
        idx = tonumber(idx)
        if status == "part" and idx then
            pending[idx] = rest
        elseif status and idx then
            into[idx] = { status = status, name = rest ~= "" and rest or nil }
            pending[idx] = nil
        end
    end
    for _, part in pairs(pending) do
        orphan_parts[#orphan_parts + 1] = part
    end
    return into, orphan_parts
end

return M
