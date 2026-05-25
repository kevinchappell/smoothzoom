import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import { Zoomer } from './zoomer.js';

export default class SmoothZoomExtension extends Extension {
  enable() {
    this._zoomer = new Zoomer(this.getSettings());
    this._zoomer.enable();
  }

  disable() {
    this._zoomer?.disable();
    this._zoomer = null;
  }
}
