import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const ZOOM_SCALE = 2.0;
const ZOOM_DURATION = 250;
const FOLLOW_TICK_MS = 16;       // ~60Hz
const FOLLOW_SMOOTHING = 0.18;   // 0..1 lerp factor per tick
const FOLLOW_DEFAULT_ON = true;

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
        this._followEnabled = FOLLOW_DEFAULT_ON;
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
    }

    disable() {
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
        console.log(`[smoothzoom] follow=${this._followEnabled ? 'on' : 'off'}`);
    }

    _zoomIn() {
        const [px, py] = global.get_pointer();
        const monIdx = monitorIndexForPoint(px, py);
        const mon = Main.layoutManager.monitors[monIdx];
        if (!mon) {
            console.log(`[smoothzoom] no monitor at (${px},${py})`);
            return;
        }

        if (this._container) {
            this._stopFollow();
            if (this._zoomActor)
                this._zoomActor.remove_all_transitions();
            this._container.destroy();
            this._container = null;
            this._zoomActor = null;
            this._clone = null;
        }

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
            scale_x: ZOOM_SCALE,
            scale_y: ZOOM_SCALE,
            duration: ZOOM_DURATION,
            mode: Clutter.AnimationMode.EASE_OUT_QUAD,
            onComplete: () => {
                if (this._state === 'ZOOMING_IN') {
                    this._state = 'ZOOMED';
                    if (this._followEnabled)
                        this._startFollow();
                }
            },
        });

        console.log(`[smoothzoom] zoom-in mon=${monIdx} pivot=(${this._pivotX.toFixed(2)},${this._pivotY.toFixed(2)}) follow=${this._followEnabled ? 'on' : 'off'}`);
    }

    _zoomOut() {
        if (!this._container || !this._zoomActor) return;
        this._stopFollow();
        this._state = 'ZOOMING_OUT';
        const container = this._container;
        const zoomActor = this._zoomActor;
        zoomActor.remove_all_transitions();
        zoomActor.ease({
            scale_x: 1.0,
            scale_y: 1.0,
            duration: ZOOM_DURATION,
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
        console.log('[smoothzoom] zoom-out');
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
        const [px, py] = global.get_pointer();
        const targetX = clamp01((px - this._mon.x) / this._mon.w);
        const targetY = clamp01((py - this._mon.y) / this._mon.h);
        this._pivotX += (targetX - this._pivotX) * FOLLOW_SMOOTHING;
        this._pivotY += (targetY - this._pivotY) * FOLLOW_SMOOTHING;
        this._zoomActor.set_pivot_point(this._pivotX, this._pivotY);
    }
}
