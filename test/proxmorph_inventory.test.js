'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');

global.window = {};
require(path.join(__dirname, '..', 'themes', 'patches', 'proxmorph-inventory.js'));

const inventory = global.window.ProxMorphInventory;
assert.ok(inventory, 'inventory API is exposed');
assert.equal(inventory.version, '1.0.0');
assert.equal(inventory.compatible, false, 'headless test does not claim an ExtJS match');

let view = inventory.buildViewFilter();
let visible = view.getFilterFn();

assert.deepEqual(view.groups, ['node', 'pool']);
assert.equal(visible({ data: { type: 'node', node: 'pve01' } }), true);
assert.equal(visible({ data: { type: 'pool', pool: 'Automation' } }), false);
assert.equal(visible({ data: { type: 'qemu', status: 'running' } }), true);
assert.equal(visible({ data: { type: 'lxc', status: 'stopped' } }), true);
assert.equal(visible({ data: { type: 'qemu', template: 1 } }), true);
assert.equal(visible({ data: { type: 'storage' } }), true);
assert.equal(visible({ data: { type: 'sdn' } }), true);
assert.equal(visible({ data: { type: 'network' } }), true);
assert.equal(visible({ data: { type: 'unknown' } }), false);

inventory.setSettings({
    showPools: 'false',
    showVirtualMachines: false,
    showContainers: true,
    showTemplates: false,
    showStorage: false,
    showNetwork: false,
    showStoppedGuests: false,
});

view = inventory.buildViewFilter();
visible = view.getFilterFn();

assert.deepEqual(view.groups, ['node']);
assert.equal(visible({ data: { type: 'qemu', status: 'running' } }), false);
assert.equal(visible({ data: { type: 'lxc', status: 'running' } }), true);
assert.equal(visible({ data: { type: 'lxc', status: 'stopped' } }), false);
assert.equal(visible({ data: { type: 'qemu', template: 1 } }), false);
assert.equal(visible({ data: { type: 'storage' } }), false);
assert.equal(visible({ data: { type: 'sdn' } }), false);
assert.equal(visible({ data: { type: 'network' } }), false);
assert.equal(visible({ data: { type: 'node' } }), true);

inventory.setSettings({ showPools: 'true' });
assert.deepEqual(inventory.buildViewFilter().groups, ['node', 'pool']);

assert.deepEqual(inventory.resetSettings(), {
    showPools: true,
    showVirtualMachines: true,
    showContainers: true,
    showTemplates: true,
    showStorage: true,
    showNetwork: true,
    showStoppedGuests: true,
});

console.log('PASS: ProxMorph Inventory filters and hierarchy');
