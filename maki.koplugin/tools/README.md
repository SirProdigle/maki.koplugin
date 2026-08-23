# Maki tools

## seed_markers.lua

One-off migration for series folders created before `.maki.lua` markers
existed. Open Maki → ⚙ → **Seed markers (one-off)**. For every folder under a
sync catalog's sync dir that matches a series title in that catalog, writes a
marker whose ledger contains every chapter currently on the feed — a baseline.
Chapters missing from disk at seed time are treated as deliberately skipped;
use long-press → *Download all here* to pull a backlog.
