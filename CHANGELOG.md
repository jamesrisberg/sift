# Changelog

All notable changes to Sift are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/); the current version is in [VERSION](VERSION).

## [Unreleased]

## [0.2.0] - 2026-09-29

### Changed
- Built with HUDKit 0.2.0: `hello` reports contract version 0.2.0, and a socket request's
  `args` values that are JSON objects or arrays reach the app as JSON text.

## [0.1.0] - 2026-09-27

The first release: an on-screen file manager for macOS 14+ in the MacHUD family.

### Added
- Browser window: a menu bar app with a HUDKit glass browser (Option-/) that behaves like a
  normal window (HUDKit `.windowed`: other windows can cover it, clicking or summoning it
  activates Sift, a Dock tile and ⌘-Tab entry while open, on the current Space). Quick Look,
  grid and list views, keyboard triage, multi-item drag and drop, back/forward history,
  breadcrumbs, two-pane mode, targets (favourite folders, 1-9 to send), new folder, duplicate,
  copy/paste, and smart views (Recents, Downloads, Large Files). Closing dismisses rather than
  quits.
- Dock strip and drawer: compact mode is the MacHUD tool dock's strip (HUDKit
  `HUDDockStripView`, 64 pt, 44 pt family-icon glyph tiles) with Trash, Downloads, target and
  + tiles, named by strip hover labels, at one of eight screen positions (snaps to the
  nearest on release; a press that moves more than 4 pt drags the strip), kept clear of the
  MacHUD dock. Each tile has a slide-out drawer with search, sort, category pills and file
  cards. The strip and drawer are `.hover` panels, floating on every Space. Sift opens in
  dock mode by default (`launchMode`: `dock`, `full`, `last`).
- FileKit, the UI-free core: items, scanner, filter/sort, merge-on-rescan, FSEvents watcher and
  Quick Look thumbnails; file actions with a collision policy (`keepBoth`, `replace`, `skip`)
  and an undo journal, so moves, renames, copies, trashes, tags and new folders undo with
  Cmd-Z (partially completed batches included); navigation history, drag/drop planning,
  targets and grid navigation.
- Rules: a declarative engine (`rules.json`) matching extensions, UTTypes, name regex, age,
  download source (`kMDItemWhereFroms`), size and folder scope, and moving, trashing, tagging
  or renaming; a Rules sheet with a per-step preview, apply as one undo step, and optional
  auto-apply in watched folders.
- Batch rename: `{name}` `{ext}` `{n}` `{date}` templates with find/replace and regex,
  validation before anything changes, and swaps and chains as one undoable step.
- Finder tags: read, write, filter and colour dots, journaled like any other operation.
- Search: bounded breadth-first subfolder name search and Spotlight queries.
- MacHUD contract: `machud.json` (windowed panel `browser`, `order` 1, compact size 340x64 = the
  strip, `acceptsFileDrop`), the HUDKit control socket verbs, `panel mode full|compact|parked`,
  `action navigate|reveal|send|drop` (a drop opens the first item's folder with the dropped
  items selected), and a settings schema for MacHUD's settings window.
- Menu bar consolidation (HUDKit): while MacHUD runs, Sift's menu is served in MacHUD's status
  menu (`menu`, `menu-invoke`) and its own icon hides; opt out with
  `settings set menuBar.consumed=false` (stored in `<data directory>/menubar.json`).
- App and menu bar icons from the MacHUD family set (HUDKit `Icons/`).
- The `sift` CLI for the control socket.
- `--snapshot` and its picking flags for visual checks; `SIFT_HOME`, `SIFT_SOCKET`,
  `SIFT_NO_HOTKEYS`, `SIFT_TARGETS_FILE` and `SIFT_DOCKS_FILE` for isolated instances.
- MacHUD repo conventions: bundle id `xyz.machud.sift`, bundle files in
  `Sources/Sift/Resources`, `VERSION`, build and install through HUDKit's shared scripts, CI.
