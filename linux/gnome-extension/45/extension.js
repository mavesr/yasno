// Ясно: lets the Yasno keyboard switcher read and select GNOME input sources on Wayland,
// where no program may switch the layout by itself. Exposes four D-Bus methods on the
// session bus at /io/github/mavesr/Yasno (interface io.github.mavesr.Yasno).
import Shell from 'gi://Shell';
import Gio from 'gi://Gio';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Keyboard from 'resource:///org/gnome/shell/ui/status/keyboard.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const INTERFACE = `<node><interface name="io.github.mavesr.Yasno">
<method name="Version"><arg type="s" direction="out"/></method>
<method name="Sources"><arg type="s" direction="out"/></method>
<method name="State"><arg type="s" direction="out"/></method>
<method name="Activate"><arg type="u" direction="in"/><arg type="b" direction="out"/></method>
</interface></node>`;

class Service {
    Version() { return '1'; }

    Sources() {
        const manager = Keyboard.getInputSourceManager();
        const list = [];
        for (let i = 0; manager.inputSources[i]; i++) {
            const source = manager.inputSources[i];
            list.push({type: source.type, id: source.id, name: source.displayName});
        }
        return JSON.stringify(list);
    }

    State() {
        const manager = Keyboard.getInputSourceManager();
        const window = global.display.focus_window;
        let app = '', appName = '';
        if (window) {
            const tracked = Shell.WindowTracker.get_default().get_window_app(window);
            app = (tracked && tracked.get_id()) || window.get_wm_class() || '';
            appName = (tracked && tracked.get_name()) || window.get_wm_class() || '';
        }
        // A password entry of the Shell itself (lock screen, polkit, Wi-Fi) or a locked session.
        const focus = global.stage.get_key_focus();
        const secret = !!(focus && focus.get_password_char && focus.get_password_char() !== 0);
        const locked = !!Main.sessionMode.isLocked;
        return JSON.stringify({current: manager.currentSource ? manager.currentSource.index : -1, app, appName, secret, locked});
    }

    Activate(index) {
        const source = Keyboard.getInputSourceManager().inputSources[index];
        if (!source) return false;
        source.activate(true);
        return true;
    }
}

export default class YasnoExtension extends Extension {
    enable() {
        this._object = Gio.DBusExportedObject.wrapJSObject(INTERFACE, new Service());
        this._object.export(Gio.DBus.session, '/io/github/mavesr/Yasno');
    }

    disable() {
        this._object?.unexport();
        this._object = null;
    }
}
