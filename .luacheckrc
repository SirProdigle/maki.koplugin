-- luacheck config for maki.koplugin / KOReader plugin context
std = "lua54"
max_line_length = false  -- KOReader doesn't enforce 120
codes = true

-- Globals provided by KOReader at runtime
globals = {
    "G_reader_settings",
}

-- Conventional names that should not warn even if shadowed/unused
read_globals = {
    "_",  -- gettext
    "_VERSION",
    "G_defaults",
}

-- Files
files["maki.koplugin/_meta.lua"].globals = { "_" }

-- Lua's `__`/`___` underscore vars are intentionally unused (loop ignores)
ignore = {
    "212/__",   -- unused loop variable __
    "212/___",  -- unused loop variable ___
    "212/_",    -- unused gettext alias when not used
    "631",      -- line too long
    "611",      -- trailing whitespace
    "212/self", -- unused 'self' on a method we don't use it in
}
