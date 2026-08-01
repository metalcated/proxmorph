'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');

const records = [];
const listeners = {};
let settingsButton;
let settingsWindow;
let appliedView;

const store = {
    add(record) {
        records.push(record);
        return record;
    },
    findRecord(field, value) {
        return records.find((record) => record[field] === value) || null;
    },
};

const toolbar = {
    down() {
        return null;
    },
    add(config) {
        settingsButton = config;
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
        appliedView = view;
    },
    expandAll() {},
    collapseAll() {},
    getStore() {
        return { getRootNode: () => ({ expand() {} }) };
    },
};

const formValues = {
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

global.window = {};
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
assert.deepEqual(records, [{ key: 'proxmorph-inventory', value: 'Inventory View' }]);
assert.equal(settingsButton.itemId, 'proxmorphInventorySettings');
assert.equal(settingsButton.tooltip, 'Inventory visibility settings');

assert.equal(selector.getViewFilter().id, 'server', 'native view behavior remains intact');

settingsButton.handler();
assert.equal(settingsWindow.config.modal, true, 'settings use an in-app modal');

const applyButton = settingsWindow.config.buttons.find((button) => button.text === 'Apply');
applyButton.handler();

assert.equal(selector.getValue(), 'proxmorph-inventory');
assert.equal(appliedView.id, 'proxmorph-inventory');
assert.deepEqual(appliedView.groups, ['node', 'pool']);
assert.equal(appliedView.getFilterFn()({ data: { type: 'qemu', status: 'running' } }), false);
assert.equal(appliedView.getFilterFn()({ data: { type: 'storage' } }), false);
assert.equal(appliedView.getFilterFn()({ data: { type: 'lxc', status: 'running' } }), true);

console.log('PASS: ProxMorph Inventory integrates with the native PVE tree controls');
