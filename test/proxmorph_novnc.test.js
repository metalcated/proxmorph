'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');

global.window = {
    clearInterval() {},
    clearTimeout() {},
};
global.document = {
    cookie: '',
    readyState: 'loading',
    addEventListener() {},
};
require(path.join(__dirname, '..', 'themes', 'novnc', 'proxmorph-novnc.js'));

const clipboard = global.window.ProxMorphNoVNCClipboard;
assert.ok(clipboard, 'noVNC clipboard API is exposed');
assert.equal(clipboard.version, '1.0.1');
assert.deepEqual(clipboard.defaults, {
    noVncContextMenu: true,
    noVncClipboardShortcuts: false,
});
assert.deepEqual(
    clipboard.normalizePreferences({
        noVncContextMenu: 'false',
        noVncClipboardShortcuts: '1',
    }),
    {
        noVncContextMenu: false,
        noVncClipboardShortcuts: true,
    },
    'account booleans normalize without browser storage',
);
assert.equal(clipboard.shortcutAction({ ctrlKey: true, key: 'c' }), 'c');
assert.equal(clipboard.shortcutAction({ metaKey: true, key: 'V' }), 'v');
assert.equal(clipboard.shortcutAction({ ctrlKey: true, shiftKey: true, key: 'v' }), '');
assert.equal(clipboard.shortcutAction({ ctrlKey: true, key: 'x' }), '');
assert.equal(clipboard.contextMenuGesture({ altKey: true, button: 2 }), true);
assert.equal(clipboard.contextMenuGesture({ shiftKey: true, button: 2 }), false);
assert.equal(clipboard.contextMenuGesture({ altKey: true, button: 0 }), false);

console.log('PASS: ProxMorph noVNC clipboard preferences and shortcuts');
