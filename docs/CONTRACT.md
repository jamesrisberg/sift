# Sift's MacHUD contract

Sift implements the MacHUD contract through HUDKit. MacHUD reads
`Sift.app/Contents/Resources/machud.json` without launching the app and talks to the running
app over a Unix socket. The shared parts are specified in HUDKit's [CONTRACT.md](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md):
[manifest](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#manifest), [socket framing and errors](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#socket), the [verbs](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#verbs),
[subscribe](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#subscribe-and-state-events), the [settings schema](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#settings-schema),
[docks.json](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#docksjson), [hover and windowed behaviour](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#behaviour-hover-and-windowed),
[file drops](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#file-drops), [menu bar consolidation](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#menu-bar-consolidation) and the
[compliance checklist](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#compliance-checklist); this page lists what Sift adds.

- Manifest: `Sources/Sift/Resources/machud.json`: app `xyz.machud.sift`, socket `sift`, one panel
  `browser` (symbol `square.grid.2x2`, `kind: windowed`, `order: 1`, default 900x560, compact 340x64
  (the dock strip along the bottom with three targets; it grows with the target count and is 64
  wide on a side edge), capability `acceptsFileDrop` (handled by `action drop`), settings schema
  `settings.json`).
- Windowed: MacHUD places, parks, dismisses and summons the browser. `panel show from=<edge>
  anchor=x,y,w,h` slides it out of the dock (`HUDAnimation.slide(in:)`, 0.22 s), `panel hide
  to=<edge>` slides it back (0.18 s). MacHUD sends `reason=click` (a dock click) or
  `reason=summon` (summon, menus, hotkeys, loadouts) for a windowed panel; a show brings the
  browser forward and activates Sift (`HUDPanelWindow.activateOnShow`). Without options it fades
  in or out where it is. A show that arrives mid-hide wins.
- Socket: `~/Library/Application Support/MacHUD/sockets/sift.sock` (0600), one JSON object per
  line: `{"command": "...", "args": {...}}` in, `{"ok": true, ...}` or `{"ok": false, "error": "..."}` out.
- CLI: `sift <command> [key=value ...]` (in `Sift.app/Contents/Helpers/sift`, linked onto PATH by
  `install.sh`). `sift action navigate path=~/x` is shorthand for `action name=navigate`, a leading
  `~` in values is expanded, and `sift watch` prints `subscribe` events until interrupted.

## Verbs

| Command | Args | Result |
|---|---|---|
| `hello` | | `{app, name, hudkit, version, panels, verbs}`: `hudkit` is the contract version, `version` the app's (`VERSION`) |
| `state` | | `{panels: [{id: "browser", visible, mode, badge, status}]}`: `badge` is the number of items in the active pane's folder, `status` the folder (or the search/smart view title) |
| `subscribe` | `events=state` (optional) | acknowledged, then `{"event": "state", "panels": [...]}` on every navigation, listing, visibility, mode or frame change. `sift watch` prints them. |
| `panel show` / `hide` / `toggle` | `id=browser`, optional `from=`/`to=` edge, `anchor=x,y,w,h`, `reason=hover/click/summon` | fades in or out. `hide` dismisses (Sift keeps running); `show` summons the panel at its last frame (MacHUD's `panel frame` if it set one) in its last mode. From the MacHUD dock: `from=<edge>` slides it out of that edge (`HUDAnimation.slide(in:)`, 0.22 s), `to=<edge>` slides it back (0.18 s); a show brings the browser forward and activates Sift. A show that arrives mid-hide wins |
| `panel frame` | `id=browser x= y= w= h=` | AppKit screen coordinates; in full mode kept as the browser's frame, in compact mode the strip snaps to the dock position nearest that frame |
| `panel mode` | `id=browser` + `full`, `compact` or `parked` | `compact` is dock mode: the 64 pt strip (the MacHUD tool dock's) at `dock.position` (one of the eight `HUDDockPosition`s; corners run along the side edge; kept clear of other docks in `docks.json`) (Trash, Downloads, targets, +; drop files on a tile to move them, Option copies; click a tile for its slide-out drawer); `parked` slides to the nearest screen edge leaving a 14 pt sliver (or to `edge=left/right/top/bottom` with a `peek=` pt sliver when given, as MacHUD does; they are remembered for later bare `parked`s), and `show`/`toggle` slides it back. Switching to `full` or `compact` shows the panel. |
| `settings get` | `key=` (optional) | `defaultFolder` (path, empty = reopen last folder), `collisionPolicy` (`keepBoth`, `replace`, `skip`), `showHidden`, `rulesAutoApply`, `launchMode` (`dock`, `full`, `last`; default `dock`), `dock.position` (`bottom`, `top`, `left`, `right`, `topLeft`, `topRight`, `bottomLeft`, `bottomRight`) |
| `settings set` | `key=value ...` | validates every value before applying any |
| `settings schema` | | `{schema}` from `settings.json` |
| `action navigate` | `path=` | opens the folder in the active pane (visibility unchanged) |
| `action reveal` | `path=` | opens the item's folder with the item selected, switches to full mode and shows the panel |
| `action send` | `path=` (comma-separated for several), `target=` (name or 1-based number), `copy=1` (optional) | moves (or copies) through the undo journal; returns `{target, moved, results}` |
| `action drop` | `paths=` (HUDKit's drop encoding: percent-encoded paths joined with `\|`) | files dropped on Sift's MacHUD dock button. Opens the folder of the first dropped item that exists with it selected; several items select every dropped item in that folder (the others are skipped). Switches to full mode and shows the panel. Returns `{folder, selected, skipped}`; `drop needs paths=` without paths, `nothing at <path>` when none exists |
| `action show` / `hide` / `toggle` | | same as the panel verbs |
| `menu` / `menu-invoke` | `id=` (and optional `title=`) for `menu-invoke` | the status menu, which MacHUD hosts while it runs (menu bar consolidation); the menu bar icon hides meanwhile |
| `quit` | | replies, then quits (the socket file is removed) |
| `help` | | lists the registered commands |

## Settings

| Key | Type | Default |
|---|---|---|
| `defaultFolder` | path | empty (reopen the last folder) |
| `collisionPolicy` | enum `keepBoth`, `replace`, `skip` | `keepBoth` |
| `showHidden` | bool | `false` (not persisted) |
| `launchMode` | enum `dock`, `full`, `last` | `dock` |
| `dock.position` | enum `bottom`, `top`, `left`, `right`, `topLeft`, `topRight`, `bottomLeft`, `bottomRight` | `bottom` |
| `rulesAutoApply` | bool | `false` |
| `menuBar.consumed` | bool | `true`: hide the menu bar icon while MacHUD hosts Sift's menu (served by HUDKit, stored in `<data directory>/menubar.json`: `~/Library/Application Support/Sift`, or `SIFT_HOME`) |

`Sources/Sift/Resources/settings.json` describes them for MacHUD's settings window
(`HUDSettingsSchema`: `{"version": 1, "settings": [{"key", "title", "type": "path" | "enum" | "bool",
"options"?, "default"?, "help"?}]}`). `rulesAutoApply` is stored in `<home>/rules.json`; the others
in UserDefaults (domain `xyz.machud.sift`, or a separate suite under `SIFT_HOME`), not in a
`preferences.json`.

## Environment

| Variable | Read by | Effect |
|---|---|---|
| `SIFT_HOME` | app | base directory for everything the app writes: `rules.json`, `targets.json`, `docks.json`, `menubar.json`, and preferences in a separate defaults suite |
| `SIFT_SOCKET` | app, CLI | socket name instead of `sift` |
| `SIFT_NO_HOTKEYS` | app | skip the Option-/ hotkey |
| `SIFT_TARGETS_FILE` | app | another `targets.json` (overrides `SIFT_HOME` for targets only) |
| `SIFT_DOCKS_FILE` | app | another `docks.json` (`HUDDockRegistry`), e.g. a fake MacHUD dock |

## Launch flags

| Flag | Effect |
|---|---|
| `--snapshot <path.png>` | show the panel and write a PNG of it after 3 s; unlike the convention, Sift keeps running afterwards (`sift quit`) |
| `--snapshot-mode compact\|full` | the mode to picture |
| `--dock-position <position>` | the dock strip position to picture |
| `--drawer <folder>` | dock mode with that folder's drawer out |
| `--snapshot-sheet rules\|rename` | picture the Rules or batch rename sheet |
| `--open <folder>` | start in that folder |
| `--search <query>` | start a subfolder search |

## Example

```sh
sift hello
sift panel show id=browser
sift action navigate path=~/Downloads
sift panel mode id=browser compact
sift action send path=~/Downloads/report.pdf target=Documents
sift settings set collisionPolicy=skip
sift watch
sift quit
```
