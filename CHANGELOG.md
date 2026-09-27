# Changelog

Every released version of Layland, newest first. Dates are the release commit's.
Versions are `MARKETING_VERSION` in `project.yml`, which is what the About panel and
the DMG name show.

## 1.1.0 · 2026-09-27

- **Group by file extension.** View ▸ Group By ▸ File Extension gathers every
  file under the displayed folder by type, then by extension, wherever it
  lives: all the videos, or every `.zip`, become one block. Hover a group for
  its size and file count; Folder is still the default.
- **Faster zooming.** Each zoom does less work on the main thread, so large
  scans respond sooner.
- **One background** for the welcome and scanning screens, which showed a
  slightly different gray under the title bar.

## 1.0.0 · 2026-09-26

- **First release.** A disk-usage treemap built to scan fast: a parallel scanner,
  a cushion treemap drawn off the main thread, color by file type or age,
  search, Quick Look, Reveal in Finder and Move to Trash.
- **Free to try.** The whole map and every size are free, with folder names for
  the first two levels; a license key from Gumroad unlocks every name and
  action.
- **Updates itself.** Layland checks for updates daily once you agree, and
  installs them in place.
