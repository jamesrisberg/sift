# Sift

An open-source, on-screen file manager for macOS: browse, preview, sort and send files from a
glass window, with every operation undoable. macOS 14+.

## What it is

Sift lives in the menu bar and opens a glass browser window (Option-/) that behaves like a normal
window (other windows can cover it; it has a Dock icon and a ⌘-Tab entry while open) for
triaging files: browse folders, preview with Quick Look, and send files to your favourite
folders with a keystroke or a drag. Every file operation is journaled, so Cmd-Z undoes moves,
renames, trashes, tags and new folders. Rules sort files for you (preview first, or
automatically in watched folders), batch rename works with tokens and regular expressions, and
Finder tags, subfolder search, Spotlight search and Recents / Large Files views are built in.
Its compact mode is a dock strip at a screen edge with a slide-out drawer (below).

Sift is a MacHUD app: it uses HUDKit's panel and glass, ships a `machud.json` manifest and
answers the MacHUD control socket; in MacHUD's tool dock it is a windowed button that MacHUD
places, parks, dismisses and summons.

## Install

Check out HUDKit (the shared kit and build scripts) next to this repo, then install:

```sh
ls ~/dev            # hudkit  sift
~/dev/sift/install.sh
```

`install.sh` builds a release, quits a running copy, installs `/Applications/Sift.app`, links
the `sift` command onto your PATH and launches it.

## Use

| Key | Action |
|---|---|
| Option-/ | show or hide the panel (global) |
| Arrows, Shift-arrows | move / extend the selection |
| Space | Quick Look |
| Return | open (folders open in place) |
| Shift-Return | rename (batch rename when several items are selected) |
| Cmd-Down / Cmd-Up | enter folder / enclosing folder |
| Cmd-[ / Cmd-] | back / forward |
| Delete | move to Trash |
| Cmd-Z / Cmd-Shift-Z | undo / redo |
| 1-9 | send the selection to that target |
| Cmd-D, Cmd-Shift-N | duplicate, new folder |
| Cmd-C, Cmd-V, Option-Cmd-V | copy files, paste (copy), paste (move) |
| Cmd-F | search (the magnifier picks this folder, subfolders or Spotlight) |
| Cmd-Shift-R | rules |
| Cmd-1 / Cmd-2 | grid / list |
| Cmd-\ | two-pane mode; Tab switches pane; Cmd-Shift-M / Cmd-Shift-C move / copy to the other pane |
| Esc | close a sheet or search results, clear filter, then selection, then hide |

The menu bar icon's menu shows Sift, and has Dock Mode, Rules, Two-Pane Mode, Show Hidden Files,
When Names Collide, Reveal Targets/Rules File and Quit.

Drag files out (all selected items travel together), or drop onto the listing, a folder,
a breadcrumb or a target to move them; hold Option to copy. In the MacHUD dock, the Sift button
accepts file drops (`acceptsFileDrop`): Sift opens the dropped item's folder with it selected
(several items: the first one's folder, with every dropped item in it selected).

Targets (the sidebar and the strip) are stored in `~/Library/Application Support/Sift/targets.json`.

## Dock mode

Compact mode (menu bar > Dock Mode, the dock button in the toolbar, or MacHUD's
`panel mode compact`) turns the panel into a strip against a screen edge that looks and
behaves like the MacHUD tool dock (it is the same view, HUDKit's `HUDDockStripView`): Trash |
Downloads, your targets (a folder in the target's colour) | +.
The open drawer's tile has the accent dot on the edge side; a crowded strip shrinks its tiles.
Drop files on a tile to move them there (Option copies; on Trash, to the Trash). Click a
tile and its drawer slides out of the strip:

```
            +------------------------------------------------+
            | * Invoices  12 items - 3.4 MB               x  |
            | [ Search        ]                    Sort: Name |
            | (All) (Images) (PDFs) (Documents)               |
            | +------+ +------+ +------+ +------+ +------+    |
            | | thumb| | thumb| | thumb| | thumb| | thumb|    |
            | | name | | name | | name | | name | | name |    |
            | +------+ +------+ +------+ +------+ +------+    |
            | Open in Full Sift                   Trash All   |
            +------------------------------------------------+
      +-------------------------------------------------------+
      | [Trash] | [Downloads] [* Invoices] [* Archive] | [+] |
      +-------------------------------------------------------+
```

The drawer shows one folder with search, sort, category pills and file cards (Quick Look
thumbnails, hover details). Select several and drag them out, Space previews, Delete
trashes, Return opens, 1-9 send to a target, Cmd-Z undoes, and the context menu reveals,
opens, renames, tags, moves or trashes. Open in Full Sift switches to the browser at that
folder; Trash All asks first. Click the same tile again, press Esc or click anywhere
outside to close it; another tile swaps its contents in place. Drag the strip by its
background to move it: when you let go it snaps to the position nearest the pointer, one of
eight (the middle of each edge, or a corner, where it runs up or down the side from the corner),
and remembers it
(setting `dock.position`). It shares the screen with the MacHUD dock: when both sit on the same
edge the strip slides along it to stay clear, and its drawer opens away from MacHUD's dock.
Right-click the strip for its position, adding a target, or hiding.

Sift opens as the dock strip (setting `launchMode`: `dock`, the default; `full` for the browser;
`last` for whichever it was in). The menu bar item and Option-/ show Sift in its current mode;
Open in Full Sift switches to the browser.

Closing the panel (the x in the toolbar, Esc, Option-/, `panel hide`) only dismisses it;
Sift stays in the menu bar and comes back at its last frame, in its last mode.

## Rules

Rules live in `~/Library/Application Support/Sift/rules.json` and are edited in the Rules sheet
(the wand button, Cmd-Shift-R, or the menu bar). Each rule matches on any of: extensions, UTTypes
(conformance), a name regular expression, minimum age in days, download source domain (from
`kMDItemWhereFroms`, subdomains included), size range, and folder scope; and then moves (to a
path or a target), trashes, adds tags, or renames with a pattern. Rules run top to bottom and the
first match wins; a rule with no conditions matches nothing.

```json
{"version": 1, "autoApply": false, "watch": ["~/Downloads"],
 "rules": [
  {"name": "Old installers", "match": {"extensions": ["dmg", "pkg"], "minAgeDays": 14}, "action": {"type": "trash"}},
  {"name": "Papers", "match": {"sourceDomains": ["arxiv.org"]}, "action": {"type": "move", "target": "Reading"}},
  {"name": "Screenshots", "match": {"nameRegex": "^Screenshot"}, "action": {"type": "move", "to": "~/Pictures/Screenshots"}},
  {"name": "Receipts", "match": {"types": ["com.adobe.pdf"], "nameRegex": "receipt"}, "action": {"type": "tag", "tags": ["Green"]}}
 ]}
```

The sheet previews what the rules would do in the current folder, with a checkbox per step;
Apply runs the ticked steps as one undo step. With "Apply automatically" on, new files in
watched folders are sorted about two seconds after they settle (partial downloads are skipped).

## Batch rename

Select items and press Shift-Return (or use the context menu). The pattern takes `{name}`,
`{ext}`, `{n}` / `{n:3}` (counter, optionally zero-padded) and `{date}` / `{date:yyyyMMdd}`
(modification date); find/replace (plain or regex with `$1` groups) applies to the name first.
The extension is kept unless you untick it. Problems (duplicates, names already taken, invalid
characters) are flagged before anything changes; swaps like a<->b work.

## MacHUD contract

Panel `browser`, kind `windowed`, socket `sift`, app `xyz.machud.sift`. Verbs: the HUDKit set
(`hello`, `state`, `subscribe`, `panel show|hide|toggle|frame|mode`, `settings get|set|schema`,
`action`, `quit`) plus `action navigate`, `action reveal`, `action send` and `action drop`.
Full reference: [docs/CONTRACT.md](docs/CONTRACT.md).

```sh
sift hello
sift panel mode id=browser compact
sift action navigate path=~/Downloads
sift action send path=~/Downloads/report.pdf target=Documents
sift settings set collisionPolicy=skip
sift watch
sift quit
```

## Settings

| Key | Type | Default | |
|---|---|---|---|
| `defaultFolder` | path | empty | folder Sift opens at launch; empty reopens the last folder |
| `collisionPolicy` | enum `keepBoth`, `replace`, `skip` | `keepBoth` | what happens when a name is taken (`replace` sends the old item to the Trash) |
| `showHidden` | bool | `false` | show hidden files (for this session) |
| `launchMode` | enum `dock`, `full`, `last` | `dock` | how Sift appears when it starts |
| `dock.position` | enum: an edge middle or a corner | `bottom` | where the dock strip sits |
| `rulesAutoApply` | bool | `false` | apply rules automatically in watched folders |

Set them in MacHUD's settings window or with `sift settings set key=value`. `rulesAutoApply`
is stored in `rules.json`; the others in Sift's UserDefaults (`xyz.machud.sift`).

## Build from source

Needs Swift 5.9+ and HUDKit checked out next to this repo (`../hudkit`).

```sh
swift test          # FileKitTests + SiftTests
./build.sh          # build/Sift.app (release; ./build.sh debug for a debug build)
./install.sh        # build, install to /Applications, link the CLI, launch
```

`build.sh` and `install.sh` call HUDKit's shared `scripts/hud-build.sh` and `scripts/hud-install.sh`
(set `HUDKIT_DIR` if HUDKit lives elsewhere); the app is signed with your Apple Development
identity if there is one, with `Sift.entitlements`. The version comes from [VERSION](VERSION);
changes are in [CHANGELOG.md](CHANGELOG.md).

Layout: `Sources/FileKit` (the UI-free core: scanning, watching, thumbnails, file actions, undo
journal, rules, rename templates, tags, search), `Sources/Sift` (the menu bar app, with the bundle
files in `Sources/Sift/Resources`), `Sources/SiftCLI` (the `sift` client), `Tests/FileKitTests`,
`Tests/SiftTests`; see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
The Kit is named `FileKit`, not `SiftKit`: the one exception to the MacHUD naming convention,
because Stash depends on it, and imports it, by that name.

`Sift.app/Contents/MacOS/Sift --snapshot out.png [--open <folder>] [--snapshot-mode compact|full]
[--dock-position <position>] [--drawer <folder>] [--snapshot-sheet rules|rename] [--search <query>]`
writes a picture of the panel without Screen Recording permission (the glass is drawn as a dark
stand-in; with `--drawer` the strip and drawer are pictured together). Sift keeps running after the snapshot; stop it with `sift quit`.

## Isolation env vars for testing

| Variable | Effect |
|---|---|
| `SIFT_HOME` | base directory for everything Sift writes: rules, targets, the dock registry, and preferences in a separate defaults suite (default `~/Library/Application Support/Sift`) |
| `SIFT_SOCKET` | socket name (default `sift`); the CLI honours it too |
| `SIFT_NO_HOTKEYS` | set to skip registering the Option-/ hotkey |
| `SIFT_TARGETS_FILE` | another `targets.json` only, for trying things without touching your list |
| `SIFT_DOCKS_FILE` | another `docks.json` (the dock registry), e.g. a fake MacHUD dock |

```sh
SIFT_HOME=$(mktemp -d) SIFT_SOCKET=sift-test SIFT_NO_HOTKEYS=1 build/Sift.app/Contents/MacOS/Sift &
SIFT_SOCKET=sift-test build/Sift.app/Contents/Helpers/sift hello
```

## License

MIT, see [LICENSE](LICENSE).
