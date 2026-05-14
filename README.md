# Maki 巻

A KOReader OPDS catalog plugin with **bulk download by folder** and **breadcrumb-based path layout** — long-press any folder in the catalog, hit "Download all here", and the files land in `<sync_dir>/<folder_title>/<...>/file.ext`.

巻 (maki) is the Japanese counter for volumes/scrolls, used for manga and book series (第1巻 = Vol. 1).

## Why this exists

Komga and other comic/manga servers expose libraries → series → chapters via OPDS. The vanilla KOReader OPDS browser downloads one file at a time and dumps everything into a single global folder. [OPDSfoldersync](https://github.com/koesac/OPDSfoldersync.koplugin) added per-catalog sync folders, but every download still goes flat into that one folder — no series subfolders, no nesting.

Maki adds the missing piece: walk the OPDS subtree from wherever you long-press, and preserve the structure on disk.

## What's different from upstream

| Feature | KOReader OPDS | OPDSfoldersync | **Maki** |
|---|:---:|:---:|:---:|
| Browse + single-file download | ✅ | ✅ | ✅ |
| Per-catalog sync folder | ❌ | ✅ | ✅ |
| Author/category filters | ❌ | ✅ | ✅ |
| Auto-sync on schedule | ❌ | ✅ | ✅ |
| Long-press folder → bulk download | ❌ | ❌ | ✅ |
| Series-subfolder path building | ❌ | ❌ | ✅ |
| Coexists with built-in OPDS plugin | n/a | ❌ (replaces) | ✅ |

## How "Download all here" works

You're inside an OPDS feed — for example, browsing your Komga "Manga" library which lists series. **Long-press** on "Chainsaw Man". You get:

```
┌─ Chainsaw Man ──────────────┐
│ [ Download all here ]       │
└─────────────────────────────┘
```

Hit it. Maki:

1. Walks every navigation entry under "Chainsaw Man" (in this case, just the chapter list).
2. Follows `rel=next` pagination so the full set of chapters is enumerated.
3. Plans a target path for each acquisition: `<sync_dir>/<folder_title>/<nested.../>file.ext`.
4. Skips files already on the device.
5. Downloads sequentially in a dismissable subprocess.

So a long-press at the Manga-library level gives you `<sync_dir>/Chainsaw Man/Official_Chapter 1.cbz`, `<sync_dir>/Chainsaw Man/Official_Chapter 2.cbz`, etc. Long-press at the all-libraries level, and each series gets its own subfolder under the sync root.

The breadcrumb is built from where you triggered the action, not from the entire navigation chain — predictable and intuitive.

## Install

Maki coexists with the built-in `opds.koplugin`. You don't have to remove anything.

1. Copy the `maki.koplugin/` directory into your KOReader plugins folder:
   - Kindle: `/mnt/us/koreader/plugins/maki.koplugin/`
   - Kobo: `/mnt/onboard/.adds/koreader/plugins/maki.koplugin/`
   - Desktop: `<koreader-dir>/plugins/maki.koplugin/`
2. Restart KOReader.
3. Enable under **Plugin management → Maki**.
4. Add catalogs via the File Manager menu → **Maki (OPDS+)**.

Settings (sync folder, max sync downloads, filters, auto-sync interval) live under **Maki (OPDS+) → ⚙**.

## Credits

- The OPDS browser core is the [KOReader OPDS plugin](https://github.com/koreader/koreader/tree/master/plugins/opds.koplugin) (AGPL-3.0).
- The per-catalog sync layer is from [koesac/OPDSfoldersync.koplugin](https://github.com/koesac/OPDSfoldersync.koplugin).
- Maki adds the bulk-download-with-breadcrumb-folders feature on top.

## License

AGPL-3.0 (inherited from KOReader, see [LICENSE](LICENSE)).
