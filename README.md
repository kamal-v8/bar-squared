# Bar² — Second Bar for Omarchy

Empty second bar that mirrors the default bar. Starts empty so you can offload widgets from a crowded main bar. Two modes: **full-edge** (reserves space, full span unless a width is set) and **floating shrunk** (centered, configurable width, also reserves space — never overlays windows). Control is a single **◧** button in the main bar.

**ID:** `io.github.kamal-v8.bar-squared` · **Name:** Bar² · **Where:** `~/.config/omarchy/plugins/io.github.kamal-v8.bar-squared/` (user-owned, hot-reloads on save)

## Files

- `Service.qml` — Bar² itself (service, always on; per-screen `PanelWindow`, empty when no widgets)
- `BarWidget.qml` — Control button in the main bar (bar-widget; single ◧, 18px)
- `ControlPanel.qml` — Control popup (Panel + KeyboardPanel; compact, scrollable)
- `manifest.json` — schemaVersion 1, kinds service + bar-widget
- `icon.svg` — spare vector icon (not currently used; control is text ◧)
- `LICENSE` — MIT

## Install

Config lives in the **bar.layout entry** for the ◧ control button
(mode/position/width/height/radius/spacing/transparent/hosted `layout`) —
the omasot single-entry pattern, so the menu (`inBar()`) and the service
loader (`isEnabled()`) agree. Every mutation additionally mirrors the config
into the legacy `plugins[]` self-entry as a crash-safe backup (core's disable
deletes the bar entry synchronously and would otherwise take the hosted
layout with it), which the service drops after returning hosted widgets to
the main bar. Pre-1.3 installs that kept config only in `plugins[]` are
migrated automatically on load.

```bash
omarchy plugin add https://github.com/kamal-v8/bar-squared.git --enable
omarchy restart shell
```

`--enable` is one click (button placed, service loaded; no separate `bar put`
needed, though `omarchy bar put io.github.kamal-v8.bar-squared --section right`
also works to re-place the button).

Click the **◧** button (or `omarchy-shell shell summon io.github.kamal-v8.bar-squared`), then use **→** to move widgets into the second bar.

## Enable / disable (one click)

```bash
omarchy plugin disable io.github.kamal-v8.bar-squared   # hides the second bar,
                                                         # returns hosted widgets
                                                         # to the main bar, unloads
omarchy plugin enable io.github.kamal-v8.bar-squared    # button back
```

## Remove

```bash
omarchy-shell io.github.kamal-v8.bar-squared clear               # optional: sends hosted widgets back first
omarchy plugin disable io.github.kamal-v8.bar-squared            # one call is enough
omarchy plugin remove io.github.kamal-v8.bar-squared
```

Note: disable preserves hosted widgets (same section in the main bar, settings
kept) but resets Bar²'s own appearance settings to defaults on next enable.

## Dependencies

None beyond a stock Omarchy install: QML only, plus `python3` (stdlib `json`/`os`/`sys`) for atomic `shell.json` edits and the bundled `omarchy-shell` CLI for panel actions. No network access, no `sudo`/`pkexec`, no binaries, no package installs.

## Configuration & consent

Bar² edits `~/.config/omarchy/shell.json` **only in response to your actions** — panel buttons, right-click moves, enable/disable migration and self-clean, or the `omarchy-shell io.github.kamal-v8.bar-squared …` commands documented below. Every write is an atomic `tmp → rename` limited to Bar²'s own `bar.layout` entry, its `plugins[]` mirror entry, plus the bar-layout entries you asked to move; nothing else is touched and nothing runs in the background.

## Control button

`BarWidget.qml` shows only `◧` at 18px (`WidgetButton { text: "◧" fontSize: 18 }`):

- **Left-click** → opens the control panel
- **Right-click** → toggles Bar² mode (`full` ↔ `floating`)
- To change the glyph/size, edit `BarWidget.qml` (`text:` / `fontSize:`) — hot-reloads on save.

## Control popup

`ControlPanel.qml` is a proper `Panel` + `KeyboardPanel` (same pattern as `omarchy.clock`). See `preview.png` for a screenshot: a `Bar² | Settings` header with a `mode·position` status pill plus **⚙** gear and **✕** on the right; below it the **Settings** drawer (hidden by default, opens via **⚙**) next to the **Main bar (n)** list with a `primary` badge and the **Second bar (n)** list with a `secondary` badge, each with its own search box. Drawer sections: Mode Full/Floating, Edge top/bottom/left/right, Look Transparent/Opaque, Width presets 300/400/500/600/Custom + −50/+50 stepper, Height −2/+2, Corners −2/+2 (`square` at 0), Spacing −1/+1. Main rows show the widget id, its section (`left`/`center`/`right`), and a bordered **→** button; Second rows show the id, a tappable **section pill** (`left`/`center`/`right` — click to move it to the next section; sections pin to the bar edges, so keep widgets in one section for tight packing), **↑**/**↓** reorder buttons, and a **←** send-back button. A hint + **Clear** / **Close** footer closes the panel.

- Compact: `contentWidth 760`, `contentHeight` fitted and capped at 520
- Settings drawer is hidden by default (`showBarSettings: false`); the header **⚙** gear opens it manually, the drawer **✕** hides it again
- The Bar² control entry itself is hidden from the Main list so you can't strand the controller inside the bar it operates
- Scrollable: `ScrollView` with vertical scrollbar only when content overflows
- Closes via: **Close** button, drawer **✕**, header **✕**, `Esc` (PanelKeyCatcher), clicking outside (KeyboardPanel dismiss area), opening another panel (popout coordinator), or `omarchy-shell shell hide io.github.kamal-v8.bar-squared`
- Auto-close fix (1.4.0): open state is service-owned (`Service.qml panelOpen`). `BarWidget.qml` mirrors live state there and restores it (`restoreIfNeeded`) after the bar rebuilds its widget Loader on a `shell.json` edit, and `ControlPanel.qml` mirrors `onOpenedChanged` too — so moves/resizes no longer close the panel, while genuine closes (✕, Esc, outside-click) still clear the flag and stay closed
- Sections: Mode Full/Floating, Edge top/bottom/left/right, Look Transparent/Opaque — same as `omarchy bar transparent` for the main bar, Width presets 300/400/500/600/Custom + −50/+50 stepper, Height −2/+2, Corners −2/+2 + square label at 0, Spacing −1/+1), side-by-side Main/Second lists with `→`/`←` (section-preserving) and `↑`/`↓` reorder, Clear/Close footer
- Drag-and-drop: hold + drag reorders widgets *within the main bar* (built-in). Moving *between* Main and Bar² is buttons only (`→`/`←` here, or right-click a Bar² widget to send it back) — no cross-bar drag.
- Layout writes only rebuild hosted widgets when the layout itself changed, so Height/Corners/Width/Transparent/Mode tweaks don't restart async widgets (e.g. GPU polling).

Because it uses the standard `open`/`close`/`opened` contract on the bar-widget root, these also work:

```bash
omarchy-shell shell summon io.github.kamal-v8.bar-squared
omarchy-shell shell hide io.github.kamal-v8.bar-squared
omarchy-shell shell toggle io.github.kamal-v8.bar-squared
```

## Bar² bar

`Service.qml` draws one `PanelWindow` per monitor (`io.github.kamal-v8.bar-squared` layer-shell namespace):

- Empty when `layout` is empty — no hint text, no control icons on the bar itself (all controls are in the popup)
- The window hides itself when there is nothing loadable to show (empty layout, or all hosted entries disabled): a hidden layer takes no exclusion, so disabling the last widget removes the bar instead of leaving an empty pill
- Disabled entries collapse (no placeholder); re-enabling restores them
- Main-bar copies win over nested ones: if an id sits in both, Bar² filters its copy so one widget never renders twice
- `full` mode: edge-anchored, `exclusionMode: Auto` (always reserves space so windows shrink, never hide underneath). Full span, unless an explicit `width` is set — then centered docked-shrunk at that width.
- `floating` mode: centered shrunk `width` (200–4000), rounded border, `exclusionMode: Auto` (reserves space like a dock, does not overlay windows)
- Horizontal windows always span the full edge (the visible bar stays centered); a click-through `mask` keeps the transparent margins from eating pointer input. This also keeps hosted widgets' popups anchored above their icon — a shrunk window would otherwise shift every popup left by the centering offset.
- Widget gap: `spacing` (0–32px, default 0) between hosted widgets, via control panel (⚙ → Spacing) or `omarchy-shell io.github.kamal-v8.bar-squared setSpacing 6`
- `transparent: true` mirrors the default bar (`surfaceFormat.opaque: false`, no border, full transparency). Toggle via control panel or `omarchy-shell io.github.kamal-v8.bar-squared setTransparent true/false`
- Widgets hosted via `barWidgetRegistry` with a minimal `dupBarApi`
- Right-click a widget on Bar² → moves it back to the main bar
- Drag-and-drop: hold left-click on any widget in the **main bar** and drag to reorder within the bar, or drop onto Bar² to move it there (same gesture as the built-in bar). Bar² → main is right-click (or the `←` button in the control panel).

## Move widgets

Third-party widgets (non-`omarchy.*`) are only loaded by the shell when referenced from the main bar or top-level `plugins[]`. Moving one to Bar² alone would unload it (empty slot). Bar² therefore keeps a bare `{"id": ...}` stub in top-level `plugins[]` while hosting the visible copy, and removes the stub when the widget moves back. First-party widgets need no stub (always loadable). Disabled entries collapse to zero width, and when nothing loadable remains the whole bar hides (no phantom pill).

```bash
omarchy-shell io.github.kamal-v8.bar-squared moveFromMain omarchy.microphone center  # main → Bar²
omarchy-shell io.github.kamal-v8.bar-squared moveToMain omarchy.microphone right     # Bar² → main
omarchy-shell io.github.kamal-v8.bar-squared moveWithinDup flowfocus -1              # reorder in Bar² (↑ = -1, ↓ = +1)
omarchy-shell io.github.kamal-v8.bar-squared moveDupSection flowfocus left          # move within Bar² to left/center/right
omarchy-shell io.github.kamal-v8.bar-squared status | jq
omarchy-shell io.github.kamal-v8.bar-squared toggleMode
omarchy-shell io.github.kamal-v8.bar-squared setPosition top   # top/bottom/left/right
omarchy-shell io.github.kamal-v8.bar-squared setWidth 600      # 200–4000
omarchy-shell io.github.kamal-v8.bar-squared setHeight 40      # 20–80
omarchy-shell io.github.kamal-v8.bar-squared setRadius 16      # 0–40, 0 = square
omarchy-shell io.github.kamal-v8.bar-squared setSpacing 6      # 0–32px gap between widgets
omarchy-shell io.github.kamal-v8.bar-squared setTransparent true   # true/false, like `omarchy bar transparent`
omarchy-shell io.github.kamal-v8.bar-squared clear             # returns hosted widgets to main bar
```

Moves are atomic file edits (`tmp → rename`) of `~/.config/omarchy/shell.json`, so the shell's `FileView` reloads them.

## Config

Primary store in `~/.config/omarchy/shell.json`: all Bar² settings (`mode`,
`position`, `width`, `height`, `radius`, `spacing`, `transparent`) plus the
nested second-bar `layout` live on the ◧ control button's `bar.layout` entry
(single-entry, omasot pattern). A `plugins[]` self-entry mirrors the same
config as a crash-safe backup for one-click disable (dropped by disableClean):

```json
{
  "bar": {"layout": {"right": [{"id": "io.github.kamal-v8.bar-squared", "mode": "floating", "position": "top", "width": 400, "height": 30, "radius": 6, "spacing": 6, "transparent": false, "layout": {"left": [], "center": [{"id": "flowfocus"}], "right": []}}]}},
  "plugins": [{"id": "io.github.kamal-v8.bar-squared", "mode": "floating", "position": "top", "width": 400, "layout": {"left": [], "center": [{"id": "flowfocus"}], "right": []}}]
}
```

## Modify

```bash
cd ~/.config/omarchy/plugins/io.github.kamal-v8.bar-squared/
$EDITOR BarWidget.qml     # glyph / size / click behavior
$EDITOR ControlPanel.qml  # popup layout / rows / widths
$EDITOR Service.qml       # Bar² geometry, colors (Color.bar.*), hosting
$EDITOR manifest.json     # version / metadata
# save → hot-reloads; if not: omarchy restart shell
omarchy-shell io.github.kamal-v8.bar-squared status | jq
hyprctl layers | grep -E "io.github.kamal-v8.bar-squared|omarchy-bar"
```

## Troubleshooting

- Click does nothing → check `omarchy-shell shell summon io.github.kamal-v8.bar-squared` returns `ok` (tests the open/close contract); check `qmllint BarWidget.qml ControlPanel.qml`
- `Target not found` → `omarchy restart shell`, then `omarchy-shell io.github.kamal-v8.bar-squared ping` → `ok`
- Popup too tall → capped at 520px with scroll; adjust `Style.space(520)` in `ControlPanel.qml`

## Changelog

- 1.5.4 — clearer Second-bar controls (section pill with full name + legend line instead of cryptic L/C/R), all hosted widgets packed into `center`

- 1.5.3 — width memory tracks shrink too (stability-gated): no more dead gaps when widget content shrinks; note: keep hosted widgets in one section for tight packing — left/center/right pin groups to the edges like the main bar
- 1.5.2 — Second-bar rows gain an L/C/R section-cycler button (`moveDupSection`), ↑/↓ disable at the edges
- 1.5.1 — bar items no longer overlap: slots floor by painted extents, remember settled widths across rebuilds, per-section live updates (reorder only remounts its section)
- 1.5.0 — compact popup (760px, cap 520px), settings drawer hidden by default (opens via ⚙), transfer gutter removed (per-row buttons only), fresh `preview.png`
- 1.4.0 — panel no longer closes on every move/resize (service-owned open state)
- 1.3.0 — one-click enable/disable (single-entry config, auto-migration)
