# Sift architecture

Sift is a SwiftPM package with three targets and a dependency on HUDKit (`../hudkit`):

| Target | Kind | Depends on | Purpose |
|---|---|---|---|
| `FileKit` | library | Foundation, CoreServices, QuickLookThumbnailing, UniformTypeIdentifiers | Pure file-management core. No AppKit or SwiftUI. Unit tested. |
| `Sift` | executable | FileKit, HUDKit, AppKit, SwiftUI, QuickLookUI | The menu bar app, its panel and the MacHUD control socket. |
| `SiftCLI` | executable | HUDKit | `sift`, a thin client for the control socket (`HUDSocketClient.runCLI`). Shipped in `Contents/Helpers/sift` because `Contents/MacOS/sift` would collide with `Sift` on a case-insensitive volume. |

`FileKitTests` exercises FileKit against temporary directories; `SiftTests` covers the app's
host logic and checks that the shipped `Sources/Sift/Resources/machud.json`, `settings.json` and
`Info.plist` decode with HUDKit and agree with the code (`swift test`). The Kit keeps the name
`FileKit` (rather than the convention's `SiftKit`) because Stash depends on it by that name.

## FileKit API

Every URL FileKit hands out is in one form, `URL.normalizedFileURL`: standardized, no
trailing slash, symlinks left alone. Items, selections, history and journal records all
compare by that form. `URL.canonicalPath` is the fully resolved path (`realpath`), which is
what FSEvents and directory enumerators report; FileKit maps those back to the form the
caller asked for, so browsing `/tmp` never yields `/private/tmp/...` URLs.

### Listing

- **`FileItem`** (`@Observable` class). `url`, `name`, `isDirectory`, `isPackage`,
  `isBrowsable` (a directory that is not a package), `fileSize`, dates, `contentType`,
  `category`, `thumbnail: CGImage?`, `folderItemCount: Int?`.
  `formattedSize` and `formattedDate` never touch the disk and share formatters; a folder's
  count is loaded by `await loadFolderItemCount()` off the main thread and cached until
  `invalidateFolderItemCount()`. `update(from:)` copies fresher metadata and reports whether
  the thumbnail is stale.
- **`FileCategory`**: coarse kind from a UTType (image, video, audio, pdf, document,
  archive, app, code, folder, other) with display names and SF Symbols.
- **`FileScanner.scan(_:options:)`**: `Options(includeHidden:depth:)`; depth 0 is a shallow
  listing, depth n descends n levels. Packages are never descended into. Throws if the
  folder itself cannot be read (instead of looking empty).
- **`FilterCriteria`** (value type): search text, categories, date and size ranges, sort
  field and direction, folders first. `apply(to:)` filters and sorts stably.
- **`FileListMerger.merge(existing:scanned:)`**: merge-on-rescan. Reuses the existing
  `FileItem` objects for URLs still present (so thumbnails and counts survive) and returns
  `added`, `removed` and `changed` sets.

### Watching and thumbnails

- **`FileSystemWatcher(latency:queue:)`**: `start(watching:handler:)` delivers batches of
  **`FileEvent`** (`path`, `flags: FileEvent.Flags`) coalesced per path. Helpers:
  `affectsListing(of:)` (a direct child or the folder changed, or a rescan is required) and
  `affectedChild(of:)` (the child folder whose contents changed, for count invalidation).
  The handler lives in a box retained by the FSEvents stream, so late callbacks after
  `stop()` are dropped safely.
- **`ThumbnailGenerator`**: `thumbnail(for:modified:) async -> CGImage?` through
  `QLThumbnailGenerator`, cached in an `NSCache` keyed by path plus modification date.
  Returns nil when Quick Look has nothing; the app falls back to the Finder icon.

### Actions and undo

- **`FileActionService`**: `trash`, `move(_:into:onCollision:)`, `copy(_:into:onCollision:)`,
  `duplicate` ("name copy.ext"), `rename(_:to:)`, `newFolder(in:)`. Each returns the
  completed **`FileOperation`** records. **`CollisionPolicy`** (`replace`, `keepBoth`,
  `skip`) is a value the caller passes in; `replace` trashes the old item so it can come
  back. A multi-item action that fails partway throws `FileActionError.partial(completed:)`
  so the finished part can still be journaled. `execute(_ PlannedOperation)` is the
  primitive used for undo and redo; it never overwrites anything.
- **`FileOperation`**: `move`, `rename`, `copy`, `trash(original:trashed:)`,
  `putBack(trashed:original:)`, `createFolder`, `removeEmptyFolder`. Each has an `inverse`
  (move and move back, trash and put back via the returned Trash URL, rename and rename
  back, new folder and remove-if-empty, copy and trash the copy). `touchedDirectories` and
  `resultURL` drive targeted refreshes and re-selection.
- **`UndoJournal`**: `record(_:name:)`, `undo()`, `redo()`, `canUndo`, `undoName`, `onChange`.
  Entries are groups (one user action). Undo executes the inverses in reverse order and
  pushes what *actually* ran onto the redo stack, so a re-trashed file's new Trash location
  is what the next undo uses. A partial failure keeps the reversed part redoable and the rest
  undoable (`JournalError.partial`).

### Smaller pieces

- **`NavigationHistory`**: back and forward stacks, `visit`, `breadcrumbs`.
- **`DragDrop.dragURLs(startingAt:selection:displayOrder:)`**: dragging a selected item
  carries the whole selection in display order. **`DragDrop.plan(dropping:into:mode:)`**
  drops duplicates, items already in the destination (for moves), the destination and its
  ancestors, comparing by path components.
- **`Target`** / **`TargetStore`**: favourite folders (name, colour, URL) persisted as JSON at
  `~/Library/Application Support/Sift/targets.json` (`{"version":1,"targets":[...]}`).
  A corrupt file throws rather than being overwritten with defaults.
- **`GridNavigation.move(from:_:columns:count:)`**: arrow-key movement in a row-major grid.

### Tags

- **`FileTags`**: `read`/`write` Finder tags through `URLResourceValues.tagNames`, `colors(of:)`
  from the `_kMDItemUserTags` attribute, the seven standard tags and their colours.
  `FileItem.tagNames` is loaded with the listing; `FileItem.update(from:)` picks up tag changes
  (they do not touch the modification date).
- **`FileOperation.setTags(url, from:, to:)`** / **`PlannedOperation.setTags(url, tags)`**: tag
  changes are journaled like any other operation. `FileActionService.setTags(_:transform:)` and
  `toggleTag(_:on:)` (Finder's rule: remove when every item has it, else add).
- **`FilterCriteria.tags`**: an item passes when it has any of the tags.

### Rename templates (`Rename/`)

- **`RenameTemplate`**: pattern tokens `{name}` `{ext}` `{n}` `{n:W}` `{date}` `{date:FORMAT}`,
  find/replace (literal or regex, case option) applied to the name before templating,
  `keepExtension`, `startNumber`. Folders have no extension.
- **`BatchRename.plan`/`validate`**: rows with the new name and a problem (`empty`,
  `invalidCharacters`, `duplicate` within the batch, `exists` on disk), case-insensitive.
- **`FileActionService.renameBatch`**: validates everything first, then renames; when a new
  name is another member's current name (swaps, chains) it goes through temporary names, so
  the whole batch is one journal entry that undoes cleanly.

### Rules (`Rules/`)

- **`Rule`**, **`RuleMatch`** (extensions, UTType conformance, name regex, `minAgeDays`,
  `sourceDomains`, size range, `folders` scope, `includeFolders`), **`RuleAction`** (`move(to:)`
  with a path or `target:Name`, `trash`, `tag`, `rename(template:)`), **`RuleSet`** (`autoApply`,
  `watch`, `rules`), **`RuleStore`** (`rules.json`, corrupt file throws), **`RulePaths`** (`~`).
- **`WhereFroms`**: reads (and, for tests, writes) `kMDItemWhereFroms`; domain matching
  includes subdomains but not label suffixes.
- **`RuleSubject`**: what a rule sees (built from disk, or directly in tests).
- **`RuleEngine.evaluate(_:now:)`**: pure; first enabled matching rule per item, no-ops
  dropped (already there, already tagged, same name), problems flagged (missing destination,
  unknown target, taken name). Returns **`PlannedRuleAction`**s carrying a `PlannedOperation`.
  **`RuleEngine.apply`** runs the unproblematic ones (moves honour the collision policy) and
  throws `.partial` so completed steps still journal.

### Search (`Search/`)

- **`RecursiveSearch`**: breadth-first name search (all terms, case and diacritic
  insensitive), bounded by depth and result count, cancellable, packages matched but not
  entered, URLs kept under the requested root.
- **`SpotlightQuery`**: `NSMetadataQuery` wrapper (main thread) with predicates for name
  search, recently used (`kMDItemLastUsedDate`) and large files.

## App structure (`Sources/Sift`)

```
main.swift            accessory activation policy, runs AppDelegate
AppDelegate           status item menu, Option-/ via HUDHotKeyCenter, launch options
                      (--open, --search, --snapshot, --snapshot-mode, --dock-position, --drawer,
                      --snapshot-sheet)
PanelController       SiftPanel (HUDPanelWindow + Quick Look control) on HUDGlassView;
                      show/hide (dismiss, never quit) with HUDAnimation fades; modes full /
                      compact (the dock strip) / parked (HUDParking); strip snapping to the
                      nearest of eight HUDDockPositions on release; publishes the strip
                      (and open drawer) to HUDDockRegistry and watches it (plus screen
                      changes) to keep clear of the MacHUD dock; cooperative `panel frame`;
                      snapshots
PanelMemory           UserDefaults: browser frame, last mode, launch mode, dock position
Theme                 hairline, radii, type scale, the full and strip glass styles
Dock/DockLayout       pure strip geometry: tile frames per edge, strip frame per position
                      (HUDDockLayout.avoiding other docks), snapping, drawer frame (opens
                      away from a neighbouring dock) and its tucked (slide-from) frame
Dock/DrawerState      one drawer at a time: open / swap / close
Dock/DrawerController the drawer panel: slide out 0.22 s / in 0.18 s behind the strip, global
                      click-outside monitor, keys, Quick Look for the drawer's listing
ControlHost           HUDPanelHost: HUDSocketServer + HUDControlRouter on sift.sock;
                      state, settings, actions navigate/reveal/send/drop; deduplicated state events
RulesController       rules.json, live preview for the Rules sheet, apply, auto-apply
                      (FSEvents on watched folders, debounced, partial downloads skipped,
                      its own results never re-processed)
KeyRouter             every keyboard shortcut; text fields and sheets keep their own keys
AppModel              panes, targets, collision policy, sheets, status toasts, and all file
                      actions (perform -> UndoJournal.record -> NSUndoManager.registerUndo)
BrowserModel          one pane: history, merged items, visible (filtered) items,
                      selection/focus/anchor, watcher, background rescans; search scope and
                      virtual views (search results, Recents, Large Files) shown in place of
                      the folder until closed
Views/RootView        sidebar + one or two panes + status toast, or the dock strip;
                      SheetHost draws sheets inside the panel; WindowDragHandle
Views/DockStripView   the strip's items (Trash, Downloads, targets, +) on HUDKit's HUDDockStrip
                      (the MacHUD tool dock's strip), drops, menus, drag-to-snap
Views/DrawerView      the drawer: header, search, sort, category pills, cards, footer
Views/SidebarView     smart views, targets (drop to send, click to open, number badges)
Views/PaneView        toolbar (history, PathBar or result title, search scope, search,
                      filter incl. tags, sort, view mode, rules), footer
Views/FileCollectionView  grid and list, thumbnails, tag dots, inline rename, drop target
Views/CellInteraction AppKit overlay per cell: clicks, multi-item drag source, folder drop
                      target, context menu (tags, batch rename, send to)
Views/RulesSheet      rule list, editor, watch settings, preview with checkboxes
Views/RenameSheet     pattern, tokens, find/replace, live preview table
```

Undo flow: `AppModel.perform` runs a FileKit action, records the returned operations in
the journal and registers one `NSUndoManager` action. The undo handler calls
`journal.undo()` and registers the redo handler (which calls `journal.redo()`), so the two
stacks move in lockstep. The journal's `onChange` refreshes any pane showing a touched
folder and re-selects the resulting items.

The panel is a `HUDPanelWindow` whose behaviour follows the mode. The browser (full mode) is
`.windowed`: borderless glass at normal level, activating Sift when clicked or summoned (not
on a MacHUD hover show), on the current Space, with a Dock tile and ⌘-Tab entry while it is on
screen (`HUDDockPolicy`); other windows can cover it. The dock strip (compact mode) and its
drawer are `.hover`: non-activating, floating on every Space, like MacHUD's own dock; the
drawer is keyable for its fields. Full mode is resizable. It is dragged by the toolbar and
sidebar header (`WindowDragHandle`). Sheets are SwiftUI overlays inside the panel rather than
AppKit sheets, which behave poorly on non-activating borderless panels and would not show in
snapshots. The control contract is in CONTRACT.md.
