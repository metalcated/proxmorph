'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');

const records = [];
const listeners = {};
let settingsButton;
let settingsWindow;
let appliedView;
let navigation;
let rootText = 'Datacenter';

const store = {
    add(record) {
        records.push(record);
        return record;
    },
    findRecord(field, value) {
        if (field === 'key' && value === 'server') {
            return { key: 'server', value: 'Server View' };
        }
        return records.find((record) => record[field] === value) || null;
    },
};

const toolbar = {
    down(selector) {
        if (selector === '#proxmorphViewNavigation') {
            return navigation || null;
        }
        if (selector === '#proxmorphInventorySettings') {
            return settingsButton || null;
        }
        return null;
    },
    add(config) {
        if (config.itemId === 'proxmorphViewNavigation') {
            navigation = config;
        } else if (config.itemId === 'proxmorphInventorySettings') {
            settingsButton = config;
        }
        return config;
    },
};

const selector = {
    ownerCt: toolbar,
    value: 'server',
    getStore() {
        return store;
    },
    getValue() {
        return this.value;
    },
    setValue(value) {
        this.value = value;
    },
    getViewFilter() {
        return { id: 'server', groups: ['node'] };
    },
    on(event, handler) {
        (listeners[event] ||= []).push(handler);
    },
    fireEvent(event, ...args) {
        (listeners[event] || []).forEach((handler) => handler(...args));
    },
};

const tree = {
    toggleCls() {},
    setViewFilter(view) {
        rootText = 'Datacenter';
        appliedView = view;
    },
    expandAll() {},
    collapseAll() {},
    getStore() {
        return {
            getRootNode: () => ({
                data: { text: rootText },
                set(field, value) {
                    if (field === 'text') {
                        rootText = value;
                    }
                },
                expand() {},
            }),
        };
    },
};

const formValues = {
    useIconNavigation: true,
    groupByNode: false,
    showPools: true,
    showVirtualMachines: false,
    showContainers: true,
    showTemplates: true,
    showStorage: false,
    showNetwork: true,
    showStoppedGuests: true,
};

// Mirrors the native Workspace listener that applies the selector's view to
// the existing PVE resource tree.
selector.on('select', (combo) => tree.setViewFilter(combo.getViewFilter()));

global.window = { location: { hostname: 'pve.gnet.com' } };
global.PVE = {};
global.Ext = {
    ClassManager: { get: () => true },
    ComponentQuery: { query: () => [tree] },
    getCmp: () => selector,
    onReady: (handler) => handler(),
    defer: (handler) => handler(),
    create(className, config) {
        if (className === 'Ext.form.Panel') {
            return {
                config,
                getForm: () => ({
                    getValues: () => formValues,
                    setValues() {},
                }),
            };
        }
        if (className === 'Ext.window.Window') {
            settingsWindow = {
                config,
                show() {},
                close() {},
            };
            return settingsWindow;
        }
        throw new Error(`Unexpected Ext class: ${className}`);
    },
};

require(path.join(__dirname, '..', 'themes', 'patches', 'proxmorph-inventory.js'));

assert.equal(global.window.ProxMorphInventory.compatible, true);
assert.deepEqual(records, [
    { key: 'proxmorph-inventory', value: 'Inventory View' },
    { key: 'proxmorph-storage', value: 'Storage View' },
    { key: 'proxmorph-connectivity', value: 'Connectivity View' },
]);
assert.equal(settingsButton.itemId, 'proxmorphInventorySettings');
assert.equal(settingsButton.tooltip, 'Inventory visibility settings');
assert.equal(navigation.itemId, 'proxmorphViewNavigation');
assert.equal(navigation.hidden, true, 'icon navigation is opt-in');
assert.equal(selector.hidden, false, 'native picker remains visible by default');

const navigationItems = navigation.items;
assert.deepEqual(
    navigationItems.map((item) => item.ariaLabel),
    ['Datacenter view', 'Inventory view', 'Storage view', 'Connectivity view'],
);
assert.match(
    navigationItems.find((item) => item.ariaLabel === 'Inventory view').tooltip,
    /node → resource pool → guest/,
);

assert.equal(selector.getViewFilter().id, 'server', 'native view behavior remains intact');

settingsButton.handler();
assert.equal(settingsWindow.config.modal, true, 'settings use an in-app modal');
assert.ok(
    settingsWindow.config.items[0].config.items.some((item) => item.name === 'useIconNavigation'),
    'settings modal exposes the icon-switcher option',
);
assert.ok(
    settingsWindow.config.items[0].config.items.some((item) => item.name === 'groupByNode'),
    'settings modal exposes the hierarchy option',
);

const applyButton = settingsWindow.config.buttons.find((button) => button.text === 'Apply');
applyButton.handler();

assert.equal(selector.getValue(), 'proxmorph-inventory');
assert.equal(selector.hidden, true, 'native picker is hidden when icon navigation is enabled');
assert.equal(navigation.hidden, false, 'icon navigation is shown when enabled');
assert.match(
    navigationItems.find((item) => item.ariaLabel === 'Inventory view').tooltip,
    /resource pool → guest/,
    'Inventory tooltip follows the selected hierarchy',
);
assert.equal(appliedView.id, 'proxmorph-inventory');
assert.equal(rootText, 'pve.gnet.com', 'icon views use the current PVE host as the root label');
assert.deepEqual(appliedView.groups, ['pool']);
assert.equal(appliedView.getFilterFn()({ data: { type: 'qemu', status: 'running' } }), false);
assert.equal(appliedView.getFilterFn()({ data: { type: 'storage' } }), false);
assert.equal(appliedView.getFilterFn()({ data: { type: 'lxc', status: 'running' } }), true);
assert.equal(
    navigationItems.find((item) => item.ariaLabel === 'Inventory view').pressed,
    true,
    'active icon follows the selected view',
);

navigationItems.find((item) => item.ariaLabel === 'Storage view').handler();
assert.equal(selector.getValue(), 'proxmorph-storage');
assert.equal(appliedView.id, 'proxmorph-storage');
assert.equal(appliedView.getFilterFn()({ data: { type: 'storage' } }), true);
assert.equal(appliedView.getFilterFn()({ data: { type: 'qemu' } }), false);

navigationItems.find((item) => item.ariaLabel === 'Connectivity view').handler();
assert.equal(selector.getValue(), 'proxmorph-connectivity');
assert.equal(appliedView.id, 'proxmorph-connectivity');
assert.equal(appliedView.getFilterFn()({ data: { type: 'network' } }), true);
assert.equal(appliedView.getFilterFn()({ data: { type: 'storage' } }), false);

navigationItems.find((item) => item.ariaLabel === 'Datacenter view').handler();
assert.equal(selector.getValue(), 'server');
assert.equal(appliedView.id, 'server', 'Datacenter icon returns to native Server View');
assert.equal(rootText, 'Datacenter', 'native Datacenter view restores the native root label');

console.log('PASS: ProxMorph Inventory and icon views integrate with native PVE tree controls');
