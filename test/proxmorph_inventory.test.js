'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');

global.window = {};
require(path.join(__dirname, '..', 'themes', 'patches', 'proxmorph-inventory.js'));

const inventory = global.window.ProxMorphInventory;
assert.ok(inventory, 'inventory API is exposed');
assert.equal(inventory.version, '1.5.0');
assert.equal(inventory.compatible, false, 'headless test does not claim an ExtJS match');

let view = inventory.buildViewFilter();
let visible = view.getFilterFn();

assert.deepEqual(view.groups, ['node', 'pool']);
assert.equal(visible({ data: { type: 'node', node: 'pve01' } }), true);
assert.equal(visible({ data: { type: 'pool', pool: 'Automation' } }), false);
assert.equal(visible({ data: { type: 'qemu', status: 'running' } }), true);
assert.equal(visible({ data: { type: 'lxc', status: 'stopped' } }), true);
assert.equal(visible({ data: { type: 'qemu', template: 1 } }), true);
assert.equal(visible({ data: { type: 'storage' } }), false);
assert.equal(visible({ data: { type: 'sdn' } }), false);
assert.equal(visible({ data: { type: 'network' } }), false);
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

inventory.setSettings({ groupByNode: false });
assert.deepEqual(inventory.buildViewFilter().groups, ['pool']);
assert.equal(inventory.getHierarchyLabel(), 'Datacenter → resource pool → guest');
assert.equal(inventory.buildViewFilter().getFilterFn()({ data: { type: 'node' } }), false);
assert.equal(inventory.buildViewFilter().getFilterFn()({ data: { type: 'pool' } }), true);

let storageView = inventory.buildViewFilter('proxmorph-storage');
let storageVisible = storageView.getFilterFn();
assert.deepEqual(storageView.groups, ['node']);
assert.equal(storageVisible({ data: { type: 'node' } }), true);
assert.equal(storageVisible({ data: { type: 'storage' } }), true);
assert.equal(storageVisible({ data: { type: 'qemu' } }), false);

let connectivityView = inventory.buildViewFilter('proxmorph-connectivity');
let connectivityVisible = connectivityView.getFilterFn();
assert.deepEqual(connectivityView.groups, ['node']);
assert.equal(connectivityVisible({ data: { type: 'node' } }), true);
assert.equal(connectivityVisible({ data: { type: 'sdn' } }), true);
assert.equal(connectivityVisible({ data: { type: 'network' } }), true);
assert.equal(connectivityVisible({ data: { type: 'proxmorph-vnet' } }), true);
assert.equal(connectivityVisible({ data: { type: 'storage' } }), false);

const normalizedVnets = inventory.normalizeConnectivityVnets([
    { vnet: 'voice', pending: { zone: 'edge' }, state: 'new' },
    { vnet: 'archive', zone: 'storage' },
    { vnet: 'retired', zone: 'legacy', state: 'deleted' },
    null,
]);
assert.deepEqual(normalizedVnets, [
    { vnet: 'archive', zone: 'storage', state: '' },
    { vnet: 'voice', zone: 'edge', state: 'new' },
]);
assert.deepEqual(inventory.buildConnectivityVnetNode(normalizedVnets[0]), {
    id: 'proxmorph-vnet/archive',
    type: 'proxmorph-vnet',
    text: 'archive',
    vnet: 'archive',
    zone: 'storage',
    state: '',
    hastate: 'unmanaged',
    iconCls: 'fa fa-network-wired x-fa-treepanel',
    leaf: true,
});

assert.deepEqual(inventory.resetSettings(), {
    useIconNavigation: false,
    groupByNode: true,
    showPools: true,
    showVirtualMachines: true,
    showContainers: true,
    showTemplates: true,
    showStorage: false,
    showNetwork: false,
    showStoppedGuests: true,
});

console.log('PASS: ProxMorph Inventory filters and hierarchy');
