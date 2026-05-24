import Adw from 'gi://Adw';
import Gdk from 'gi://Gdk';
import GObject from 'gi://GObject';
import Gtk from 'gi://Gtk';
import {ExtensionPreferences} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

// Keys whose modifier mask we ignore so e.g. NumLock doesn't change the binding.
const IGNORED_MODS = Gdk.ModifierType.LOCK_MASK
    | Gdk.ModifierType.MOD2_MASK
    | Gdk.ModifierType.MOD3_MASK
    | Gdk.ModifierType.MOD4_MASK
    | Gdk.ModifierType.MOD5_MASK
    | Gdk.ModifierType.BUTTON1_MASK
    | Gdk.ModifierType.BUTTON2_MASK
    | Gdk.ModifierType.BUTTON3_MASK
    | Gdk.ModifierType.BUTTON4_MASK
    | Gdk.ModifierType.BUTTON5_MASK;

// Adw.ActionRow with a button that captures a key combo. Stores result as a
// strv in `settings[key]` using Gtk.accelerator_name.
const ShortcutRow = GObject.registerClass(
class ShortcutRow extends Adw.ActionRow {
    _init(settings, key, title, subtitle) {
        super._init({title, subtitle, activatable: true});
        this._settings = settings;
        this._key = key;

        this._button = new Gtk.Button({
            valign: Gtk.Align.CENTER,
            has_frame: true,
        });
        this._button.add_css_class('flat');
        this.add_suffix(this._button);
        this.set_activatable_widget(this._button);

        this._reset = new Gtk.Button({
            valign: Gtk.Align.CENTER,
            icon_name: 'edit-clear-symbolic',
            tooltip_text: 'Reset to default',
        });
        this._reset.add_css_class('flat');
        this._reset.connect('clicked', () => {
            this._settings.reset(this._key);
        });
        this.add_suffix(this._reset);

        this._button.connect('clicked', () => this._beginCapture());

        this._changedId = this._settings.connect(
            `changed::${this._key}`, () => this._refresh());
        this.connect('destroy', () => {
            if (this._changedId) {
                this._settings.disconnect(this._changedId);
                this._changedId = 0;
            }
        });
        this._refresh();
    }

    _refresh() {
        const accels = this._settings.get_strv(this._key);
        const accel = accels[0] ?? '';
        if (accel) {
            const label = Gtk.accelerator_get_label(
                ...this._parseAccel(accel));
            this._button.set_label(label || accel);
        } else {
            this._button.set_label('Disabled');
        }
    }

    _parseAccel(accel) {
        const [ok, keyval, mods] = Gtk.accelerator_parse(accel);
        if (!ok) return [0, 0];
        return [keyval, mods];
    }

    _beginCapture() {
        const root = this.get_root();
        const dialog = new Adw.MessageDialog({
            transient_for: root,
            modal: true,
            heading: 'Press shortcut',
            body: 'Press the new key combination, or Backspace to clear, or Escape to cancel.',
        });
        dialog.add_response('cancel', 'Cancel');

        const controller = new Gtk.EventControllerKey();
        controller.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
        controller.connect('key-pressed', (_c, keyval, _keycode, state) => {
            const mods = state & ~IGNORED_MODS & Gtk.accelerator_get_default_mod_mask();

            if (keyval === Gdk.KEY_Escape && !mods) {
                dialog.close();
                return Gdk.EVENT_STOP;
            }
            if (keyval === Gdk.KEY_BackSpace && !mods) {
                this._settings.set_strv(this._key, []);
                dialog.close();
                return Gdk.EVENT_STOP;
            }

            if (!isAcceptableAccel(keyval, mods))
                return Gdk.EVENT_STOP;

            const accel = Gtk.accelerator_name(keyval, mods);
            this._settings.set_strv(this._key, [accel]);
            dialog.close();
            return Gdk.EVENT_STOP;
        });
        dialog.add_controller(controller);
        dialog.present();
    }
});

function isAcceptableAccel(keyval, mods) {
    if (!keyval) return false;
    if (!Gtk.accelerator_valid(keyval, mods)) return false;
    // Require at least one modifier — pure letter keys would conflict with typing.
    if (!mods) return false;
    return true;
}

export default class SmoothZoomPrefs extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const settings = this.getSettings();

        const page = new Adw.PreferencesPage({
            title: 'Smooth Zoom',
            icon_name: 'zoom-in-symbolic',
        });
        window.add(page);

        // --- Zoom ---
        const zoomGroup = new Adw.PreferencesGroup({title: 'Zoom'});
        page.add(zoomGroup);

        const zoomLevel = new Adw.SpinRow({
            title: 'Zoom level',
            subtitle: 'Magnification factor',
            adjustment: new Gtk.Adjustment({
                lower: 1.25, upper: 6.0,
                step_increment: 0.05, page_increment: 0.25,
            }),
            digits: 2,
        });
        settings.bind('zoom-level', zoomLevel, 'value',
            0 /* DEFAULT */);
        zoomGroup.add(zoomLevel);

        const zoomDuration = new Adw.SpinRow({
            title: 'Animation duration',
            subtitle: 'Zoom in/out time in milliseconds',
            adjustment: new Gtk.Adjustment({
                lower: 50, upper: 800,
                step_increment: 10, page_increment: 50,
            }),
        });
        settings.bind('zoom-duration-ms', zoomDuration, 'value', 0);
        zoomGroup.add(zoomDuration);

        // --- Follow ---
        const followGroup = new Adw.PreferencesGroup({title: 'Follow'});
        page.add(followGroup);

        const followSmoothing = new Adw.SpinRow({
            title: 'Cursor smoothing',
            subtitle: 'Lower = smoother / laggier (0.05–0.5)',
            adjustment: new Gtk.Adjustment({
                lower: 0.05, upper: 0.5,
                step_increment: 0.01, page_increment: 0.05,
            }),
            digits: 2,
        });
        settings.bind('follow-smoothing', followSmoothing, 'value', 0);
        followGroup.add(followSmoothing);

        const followDefault = new Adw.SwitchRow({
            title: 'Auto-start follow on zoom-in',
            subtitle: 'When off, zoom-in freezes the pivot at the cursor',
        });
        settings.bind('follow-default-on', followDefault, 'active', 0);
        followGroup.add(followDefault);

        // --- Hotkeys ---
        const hotkeyGroup = new Adw.PreferencesGroup({
            title: 'Hotkeys',
            description: 'Click a row to rebind. Backspace clears, Escape cancels.',
        });
        page.add(hotkeyGroup);

        hotkeyGroup.add(new ShortcutRow(
            settings, 'hotkey-zoom',
            'Toggle zoom', 'Smooth zoom in / out on the cursor’s monitor'));
        hotkeyGroup.add(new ShortcutRow(
            settings, 'hotkey-follow',
            'Toggle follow', 'Pause / resume cursor tracking while zoomed'));

        window._settings = settings; // keep alive
    }
}
