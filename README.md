# Smooth Zoom

A GNOME Shell 50 extension that smoothly zooms into the monitor your cursor is on, follows the cursor while zoomed, and gets out of the way of everything else on screen.

[smoothzoom_720.webm](https://github.com/user-attachments/assets/f61ffe7a-f8a5-4a54-9371-c44e06d3cb93)


Built for live demos, screen-sharing, and recording — so OBS (or whatever's capturing the screen) can stay a passive recorder while the zoom happens at the compositor level.

## Features


- **Per-monitor zoom.** Only the monitor containing the cursor at toggle time is scaled. Other monitors (preview, chat, notes) stay at 1×.
- **Smooth animation.** Configurable ease-out duration (default 250 ms).
- **Cursor follow.** Pivot tracks the cursor with a configurable smoothing factor while zoomed.
- **Pause/resume follow** with a separate hotkey — freeze the framing while the cursor moves freely under it.
- **Rebindable hotkeys** via a libadwaita preferences panel; no file editing required.

## Default hotkeys

| Hotkey       | Action                                                                 |
| ------------ | ---------------------------------------------------------------------- |
| `<Super>+Z`  | Toggle zoom. Smooth in to the cursor's monitor, smooth out to 1×.      |
| `<Super>+X`  | Toggle follow. Only meaningful while zoomed.                           |

Both are reassignable in the preferences panel.

## Requirements

- GNOME Shell **50**
- Wayland session (tested) — X11 should work but is not the target

## Install (from source)

```bash
# From the repo root containing the smoothzoom@kevinchappell.github.io/ directory
ln -s "$PWD/smoothzoom@kevinchappell.github.io" \
      "$HOME/.local/share/gnome-shell/extensions/smoothzoom@kevinchappell.github.io"

# Compile the gsettings schema
glib-compile-schemas smoothzoom@kevinchappell.github.io/schemas/

# Log out and back in (Wayland needs a fresh shell process to load a new extension)

# Enable
gnome-extensions enable smoothzoom@kevinchappell.github.io
```

Open the preferences panel with:

```bash
gnome-extensions prefs smoothzoom@kevinchappell.github.io
```

## Settings

All settings are exposed in the preferences panel and stored under the gsettings path `/org/gnome/shell/extensions/smoothzoom/`.

| Key                  | Type   | Default        | Range / Notes                                  |
| -------------------- | ------ | -------------- | ---------------------------------------------- |
| `zoom-level`         | double | `2.0`          | 1.25× – 6×                                     |
| `zoom-duration-ms`   | int    | `250`          | 50 – 800 ms                                    |
| `follow-smoothing`   | double | `0.18`         | 0.05 – 0.5 — lower = smoother / laggier        |
| `follow-default-on`  | bool   | `true`         | Auto-start follow on zoom-in                   |
| `hotkey-zoom`        | strv   | `['<Super>z']` | Accelerator strings                            |
| `hotkey-follow`      | strv   | `['<Super>x']` | Accelerator strings                            |

`follow-smoothing` is read live every follow tick — drag the slider while zoomed and the response changes immediately. Animation duration and zoom level are snapshotted at the start of each zoom cycle (changing them mid-animation would yank the in-flight tween).

## Development

The extension is structured to allow fast iteration without a Wayland logout:

```
smoothzoom@kevinchappell.github.io/
├── extension.js        # Thin shim — cache-busts and dynamic-imports zoomer.js
├── zoomer.js           # All real logic; reload-friendly
├── prefs.js            # libadwaita preferences UI
├── metadata.json
└── schemas/
    └── org.gnome.shell.extensions.smoothzoom.gschema.xml
```

GNOME Shell caches ESM modules for the process lifetime. `extension.js` works around this by dynamic-importing `zoomer.js?v=${Date.now()}`, so a disable/enable cycle picks up edits to `zoomer.js` without restarting the shell.

### Iteration loop

```bash
# After editing zoomer.js or the schema:
glib-compile-schemas smoothzoom@kevinchappell.github.io/schemas/   # only on schema changes
gnome-extensions disable smoothzoom@kevinchappell.github.io
gnome-extensions enable smoothzoom@kevinchappell.github.io

# Watch shell logs in another terminal:
journalctl /usr/bin/gnome-shell -f
```

Editing `extension.js` itself, `prefs.js`, or `metadata.json` still requires a logout/login to pick up.

### Architecture notes

- The zoom is implemented by cloning `Main.uiGroup` into an actor parented to `global.stage` (not `Main.uiGroup` itself — that would recurse), clipped to the active monitor's rect, with `set_pivot_point` + `set_scale` driving the animation.
- The system cursor is drawn above the stage by Mutter and stays native-size while zoomed.
- Active-monitor selection happens once on toggle and is locked in until zoom-out completes.

## License

MIT
