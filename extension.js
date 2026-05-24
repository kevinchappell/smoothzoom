import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

// Thin shim: defers all real work to zoomer.js, which is dynamic-imported
// with a cache-busting query string so disable/enable cycles pick up edits
// without needing a Wayland logout. ESM extension modules are otherwise
// cached for the lifetime of the gnome-shell process.

export default class SmoothZoomExtension extends Extension {
    async enable() {
        const mod = await import(`./zoomer.js?v=${Date.now()}`);
        this._zoomer = new mod.Zoomer(this.getSettings());
        this._zoomer.enable();
        console.log('[smoothzoom] enabled');
    }

    disable() {
        this._zoomer?.disable();
        this._zoomer = null;
        console.log('[smoothzoom] disabled');
    }
}
