# Layland

A macOS disk-usage treemap in the spirit of [GrandPerspective](https://grandperspectiv.sourceforge.net),
built around one goal: **scan fast**. On a 3.8-million-entry home folder it finishes in ~13 s where
`du -sk` needs ~76 s (Apple silicon, APFS, macOS 26).

Native Swift 6, SwiftUI shell, AppKit treemap. One dependency: [Sparkle](https://sparkle-project.org), for updates.

## Build

```bash
brew install xcodegen
xcodegen generate            # produces Layland.xcodeproj (git-ignored)
open Layland.xcodeproj       # or:
xcodebuild -scheme Layland -configuration Release build
```

Targets:

- **Layland** – the app. `open -a Layland --args --scan ~/Downloads` starts a scan on launch
  (`--scan file.layland` loads a saved one); `--search text` pre-fills the search field;
  `--edit-palette` opens the palette editor.
- **layland-bench** – CLI around the scanner for timing and correctness checks:
  `layland-bench [--threads N] [--top K] [--allocated] [--cross-mounts] [--save out.layland] <path>`
- **LaylandTests** – Swift Testing suite for the scanner, tree model and layout.

Signing uses the Developer ID identity so the Full Disk Access grant survives rebuilds (ad-hoc
signatures change per build and TCC silently stops honouring them). Change `DEVELOPMENT_TEAM` in
`project.yml` or switch to `CODE_SIGN_IDENTITY: "-"` if you don't have one.

## Why it's fast

`Layland/Core/DiskScanner.swift`:

1. **`getattrlistbulk(2)`** – one syscall returns a batch of entries with type, sizes, inode, link
   count and flags. No per-file `stat`, no `FileManager`, no `URL` objects.
2. **Parallel traversal** – each directory is a work item; a LIFO queue feeds a pool of threads.
   A directory listing costs one or two 4 KB metadata reads that APFS does not keep cached across
   scans, so the scan is bound by SSD latency, not CPU; ~4× the core count keeps the queue full.
3. **`openat` from the parent** – one cached component lookup per directory instead of a path walk.
4. **Flat arena** (`FileTree.swift`) – nodes are 48-byte structs in one array, names in one byte
   buffer, children contiguous. Sizes and counts aggregate in a single reverse pass because every
   index is greater than its parent's. ~180 MB for 3.8 M entries, no ARC traffic during the scan.
5. Hard links are counted once (by device + inode), mount points are not crossed, APFS firmlinks
   (`/Users`, `/Applications`, …) are followed, so scanning `/` matches what the Finder shows.

### Benchmark vs GrandPerspective

MacBook Pro (Apple silicon, 8 cores, 24 GB), macOS 26.6, APFS on the internal SSD, warm cache,
both apps granted Full Disk Access. GrandPerspective 3.8.1 was built from its source, unsandboxed
like the website download, and its times are its own `Done scanning … in N s` log line. Both
tools agree on the folder counts.

| folder | files | folders | GrandPerspective | Layland | speed-up |
| --- | ---: | ---: | ---: | ---: | ---: |
| `~/dev` | 1.55 M | 234 k | 42.2 s | 6.3 s | 6.7× |
| `~/Library` | 892 k | 126 k | 31.2 s | 4.3 s | 7.2× |
| `~` (home) | 3.32 M | 500 k | 97.5 s | 14.2 s | 6.9× |

For reference, `du -sk ~` takes 76 s on the same tree, and Layland with 4 threads 23 s — the
gap is almost entirely the parallel queue keeping the SSD busy (see "Why it's fast").

The app icon is generated: `swift scripts/makeicon.swift icon_1024.png` renders it with SwiftUI (a cushion
treemap clipped to a squircle concentric with the macOS icon shape); scale the result into `Layland/App/Assets.xcassets` with `sips`.

## Rendering

`Layland/Treemap`: squarified layout in device pixels (`TreemapLayout`), then **cushion shading**
(van Wijk & van de Wetering) rasterised by a small parallel software renderer
(`CushionRenderer`) – every leaf's surface is the sum of its ancestors' parabolic ridges, so
folder nesting shows through the shading without borders. A 3.8 M-node tree lays out in ~50 ms
and rasterises in ~5 ms, all on a background queue (`TreemapRenderer`, latest request wins); the
layer-backed `TreemapView` stretches the previous image on the GPU in the meantime, so resizing
never blocks the main thread. Children are pre-sorted once per scan (`FileTree.orderedChildren`)
and files are classified by extension during the scan (`FileCategory`), so layout never sorts or
allocates per file. Tune the look in `CushionShape` and `CushionRenderer.Lighting`.

View menu: **Color By** (file type, or age since last modification in nine buckets — see
`ColorMode.swift`), **Show Legend**, **Show Free Space** (adds the volume's free space and the
space used outside the scanned folder as two extra cells, so the scan appears in proportion to
the disk), **Color Palette** (six presets in `TreemapPalette.presetColors`, one hex colour per
`FileCategory` slot, saved presets, and **Custom**), **Edit Custom Palette…** (a live editor; the
main window shows `SampleTree` with every category while it is open), **Cushion Strength** (flat / subtle / normal / strong), and **Cell Margin** (an even
gap between cells ≥ 12 px and around clusters of smaller ones).

Item menu: **Quick Look** (⌘Y or space), **Reveal in Finder**, **Move to Trash**, **Select
Enclosing Folder** (⌘[), **Select Largest Item Inside** (⌘]), **Next Search Result** (⌘G).
Arrow keys walk the selection to the neighbouring cell. The toolbar search field matches file
names (case-insensitive substring over the raw name bytes, ~50 ms for millions of files) and dims
everything else; matches hidden inside collapsed folders light up the folder.

File menu: **Save Scan…** / **Open Scan…** – `.layland` files (`ScanArchive.swift`: a JSON
manifest plus the LZFSE-compressed node and name arrays). A 3.8 M-node home folder is ~64 MB,
writes in ~2 s and loads in ~0.3 s. Files opened from the Finder are handled too.

## Layout

```
Layland/Core      scanner, tree model, work queue, file categories   (shared with the bench target)
Layland/Treemap   squarified layout, cushion renderer, palette, NSView
Layland/UI        session state, SwiftUI screens, menu commands
Bench/            layland-bench CLI
LaylandTests/     unit tests
```

## Roadmap ideas

- Incremental rescans: persist the tree and use FSEvents (`sinceWhen:`) to re-list only the
  directories that changed – turns a 13 s rescan into a fraction of a second.
- A "largest files" sidebar and a colour legend / filter by category.
- App Store build: enable the sandbox and keep folder access through security-scoped bookmarks
  (folder selection already goes through `NSOpenPanel`).

## Updates and releases

Layland updates itself with [Sparkle](https://sparkle-project.org): once the user agrees (Sparkle
asks on the second launch), it checks
`https://layland.app/appcast.xml` daily (the site proxies the appcast attached to the latest
GitHub release), and installs
EdDSA-signed, notarized archives in place. App menu ▸ Check for Updates… checks now. To try an
update against a local feed, run a build with `LAYLAND_FEED=http://localhost:8000/appcast.xml`.

`./release.sh` makes a release: it builds a universal Release, packages and notarizes a DMG,
zips the stapled app for Sparkle, signs it into the appcast (keeping previous entries), and
publishes a GitHub release with `Layland.dmg`, the zip and `appcast.xml`. Bump
`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` and add a `CHANGELOG.md`
entry first. `--no-notarize` stops after the DMG; `--dry-run` exercises the publishing half
against a draft it deletes; `--critical` marks an update nobody should skip.

## License

[FSL-1.1-ALv2](LICENSE) — the [Functional Source License](https://fsl.software).
Read it, build it, modify it, run it for whatever you like. The one thing it
withholds is *competing use*: shipping it as a commercial product that
substitutes for this one. Every release converts to **Apache-2.0 two years after
it is published**, irrevocably — so this is open source on a delay, not a
trapdoor.
