import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';

// Thin shim: defers all real work to zoomer.js.
//
// Behavior is identical to a static `import` of './zoomer.js' — the same
// module is loaded, the same Zoomer class is instantiated, and the same
// enable()/disable() lifecycle is honored. The query string on the import
// specifier does not affect runtime behavior for end users.
//
// Why dynamic import with a `?v=` query string: GNOME Shell caches ESM
// modules for the lifetime of the shell process, so a `disable` + `enable`
// cycle would otherwise re-run enable() against the *cached* module and
// never pick up edits to zoomer.js without a full logout. The unique query
// string forces a fresh module load on each enable(), which is only
// observable during development. No network, filesystem, or eval is
// involved — this is a standard ESM dynamic import resolving to a local
// file in the extension directory.
//
// Keeping the indirection here also means extension.js itself stays tiny
// and rarely changes, while all real logic lives in zoomer.js.

export default class SmoothZoomExtension extends Extension {
  async enable() {
    const mod = await import(`./zoomer.js?v=${Date.now()}`);
    this._zoomer = new mod.Zoomer(this.getSettings());
    this._zoomer.enable();
  }

  disable() {
    this._zoomer?.disable();
    this._zoomer = null;
  }
}
