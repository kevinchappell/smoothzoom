import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const FOLLOW_TICK_MS = 16;       // ~60Hz

function monitorIndexForPoint(x, y) {
    const monitors = Main.layoutManager.monitors;
    for (let i = 0; i < monitors.length; i++) {
        const m = monitors[i];
        if (x >= m.x && x < m.x + m.width &&
            y >= m.y && y < m.y + m.height)
            return i;
    }
    return Main.layoutManager.primaryIndex;
}

function clamp01(v) {
    return v < 0 ? 0 : v > 1 ? 1 : v;
}

export class Zoomer {
    constructor(settings) {
        this._settings = settings;
        this._state = 'IDLE';   // IDLE | ZOOMING_IN | ZOOMED | ZOOMING_OUT
        this._container = null;
        this._zoomActor = null;
        this._clone = null;
        this._mon = null;       // {x,y,w,h} of active monitor
        this._pivotX = 0;
        this._pivotY = 0;
        this._followEnabled = settings.get_boolean('follow-default-on');
        this._followTimer = 0;
        this._boundKeys = [];
    }

    enable() {
        const modes = Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW | Shell.ActionMode.POPUP;
        const add = (key, handler) => {
            Main.wm.addKeybinding(
                key, this._settings,
                Meta.KeyBindingFlags.NONE, modes,
                handler);
            this._boundKeys.push(key);
        };
        add('hotkey-zoom', () => this.toggleZoom());
        add('hotkey-follow', () => this.toggleFollow());

        // Rebind hotkeys live when the user changes them in prefs.
        const rebind = (key, handler) => {
            Main.wm.removeKeybinding(key);
            Main.wm.addKeybinding(
                key, this._settings,
                Meta.KeyBindingFlags.NONE, modes,
                handler);
        };
        this._settings.connectObject(
            'changed::hotkey-zoom',
            () => rebind('hotkey-zoom', () => this.toggleZoom()),
            'changed::hotkey-follow',
            () => rebind('hotkey-follow', () => this.toggleFollow()),
            'changed::follow-default-on', () => {
                // Only updates the default; doesn't flip an in-progress zoom.
                if (this._state === 'IDLE')
                    this._followEnabled = this._settings.get_boolean('follow-default-on');
            },
            this);
    }

    disable() {
        this._settings.disconnectObject(this);
        for (const key of this._boundKeys)
            Main.wm.removeKeybinding(key);
        this._boundKeys = [];
        this._teardown();
    }

    _teardown() {
        this._stopFollow();
        if (this._zoomActor)
            this._zoomActor.remove_all_transitions();
        if (this._container)
            this._container.destroy();
        this._container = null;
        this._zoomActor = null;
        this._clone = null;
        this._mon = null;
        this._state = 'IDLE';
        this._settings = null;
    }

    toggleZoom() {
        if (this._state === 'IDLE' || this._state === 'ZOOMING_OUT')
            this._zoomIn();
        else
            this._zoomOut();
    }

    toggleFollow() {
        if (this._state === 'IDLE') return;
        this._followEnabled = !this._followEnabled;
        if (this._followEnabled && this._state === 'ZOOMED')
            this._startFollow();
        else
            this._stopFollow();
    }

    _zoomIn() {
        const [px, py] = global.get_pointer();
        const monIdx = monitorIndexForPoint(px, py);
        const mon = Main.layoutManager.monitors[monIdx];
        if (!mon)
            return;

        if (this._container) {
            this._stopFollow();
            if (this._zoomActor)
                this._zoomActor.remove_all_transitions();
            this._container.destroy();
            this._container = null;
            this._zoomActor = null;
            this._clone = null;
        }

        // Snapshot animation params for this zoom cycle (changes mid-anim
        // would yank the transition; smoothing is read live in _followTick).
        const zoomScale = this._settings.get_double('zoom-level');
        const zoomDuration = this._settings.get_int('zoom-duration-ms');
        this._followEnabled = this._settings.get_boolean('follow-default-on');

        this._mon = {x: mon.x, y: mon.y, w: mon.width, h: mon.height};

        // Outer container: clips to monitor rect; never scales.
        // Parented to global.stage so cloning Main.uiGroup doesn't recurse.
        this._container = new Clutter.Actor({
            x: mon.x,
            y: mon.y,
            width: mon.width,
            height: mon.height,
            clip_to_allocation: true,
            reactive: false,
        });
        Shell.util_set_hidden_from_pick(this._container, true);

        // Inner actor: gets the scale + pivot transform.
        this._zoomActor = new Clutter.Actor({
            x: 0,
            y: 0,
            width: mon.width,
            height: mon.height,
            reactive: false,
        });
        this._pivotX = clamp01((px - mon.x) / mon.width);
        this._pivotY = clamp01((py - mon.y) / mon.height);
        this._zoomActor.set_pivot_point(this._pivotX, this._pivotY);
        this._zoomActor.set_scale(1.0, 1.0);
        this._container.add_child(this._zoomActor);

        // Live mirror of Main.uiGroup, offset so the active monitor's
        // top-left lands at (0,0) inside the inner actor.
        this._clone = new Clutter.Clone({
            source: Main.uiGroup,
            x: -mon.x,
            y: -mon.y,
            clip_to_allocation: true,
            reactive: false,
        });
        this._zoomActor.add_child(this._clone);

        global.stage.add_child(this._container);

        this._state = 'ZOOMING_IN';
        this._zoomActor.ease({
            scale_x: zoomScale,
            scale_y: zoomScale,
            duration: zoomDuration,
            mode: Clutter.AnimationMode.EASE_OUT_QUAD,
            onComplete: () => {
                if (this._state === 'ZOOMING_IN') {
                    this._state = 'ZOOMED';
                    if (this._followEnabled)
                        this._startFollow();
                }
            },
        });
    }

    _zoomOut() {
        if (!this._container || !this._zoomActor) return;
        this._stopFollow();
        this._state = 'ZOOMING_OUT';
        const container = this._container;
        const zoomActor = this._zoomActor;
        const zoomDuration = this._settings.get_int('zoom-duration-ms');
        zoomActor.remove_all_transitions();
        zoomActor.ease({
            scale_x: 1.0,
            scale_y: 1.0,
            duration: zoomDuration,
            mode: Clutter.AnimationMode.EASE_OUT_QUAD,
            onComplete: () => {
                if (this._container === container) {
                    container.destroy();
                    this._container = null;
                    this._zoomActor = null;
                    this._clone = null;
                    this._mon = null;
                    this._state = 'IDLE';
                }
            },
        });
    }

    _startFollow() {
        if (this._followTimer) return;
        this._followTimer = GLib.timeout_add(
            GLib.PRIORITY_DEFAULT,
            FOLLOW_TICK_MS,
            () => {
                this._followTick();
                return GLib.SOURCE_CONTINUE;
            }
        );
    }

    _stopFollow() {
        if (this._followTimer) {
            GLib.source_remove(this._followTimer);
            this._followTimer = 0;
        }
    }

    _followTick() {
        if (!this._zoomActor || !this._mon)
            return;
        const smoothing = this._settings.get_double('follow-smoothing');
        const [px, py] = global.get_pointer();
        const targetX = clamp01((px - this._mon.x) / this._mon.w);
        const targetY = clamp01((py - this._mon.y) / this._mon.h);
        this._pivotX += (targetX - this._pivotX) * smoothing;
        this._pivotY += (targetY - this._pivotY) * smoothing;
        this._zoomActor.set_pivot_point(this._pivotX, this._pivotY);
    }
}
