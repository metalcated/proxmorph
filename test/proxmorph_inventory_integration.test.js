'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');

const records = [];
const listeners = {};
let settingsButton;
let settingsWindow;
let appliedView;
let navigation;
let navigationStyle;
let rootText = 'Datacenter';
const apiRequests = [];

function makeNode(id, children = [], expanded = false, text = id) {
    const node = {
        data: { id, text },
        childNodes: children,
        expanded,
        isLeaf() {
            return this.childNodes.length === 0;
        },
        isExpanded() {
            return this.expanded;
        },
        expand() {
            this.expanded = true;
        },
        collapse() {
            this.expanded = false;
        },
        cascadeBy(callback) {
            callback(this);
            this.childNodes.forEach((child) => child.cascadeBy(callback));
        },
        set(field, value) {
            this.data[field] = value;
            if (id === 'root' && field === 'text') {
                rootText = value;
            }
        },
    };
    return node;
}

function makeRoot(viewId) {
    const branchId =
        viewId === 'proxmorph-inventory'
            ? 'pool/Automation'
            : viewId === 'proxmorph-storage'
              ? 'storage/pve01/local-zfs'
              : viewId === 'proxmorph-connectivity'
                ? 'network/pve01/vmbr0'
                : 'node/pve01';
    return makeNode(
        'root',
        [makeNode(branchId, [makeNode(`${branchId}/guest`)], false)],
        true,
        'Datacenter',
    );
}

function findNode(root, id) {
    let match = null;
    root.cascadeBy((node) => {
        if (node.data.id === id) {
            match = node;
        }
    });
    return match;
}

function flattenConfigItems(items) {
    const flattened = [];
    (items || []).forEach((item) => {
        flattened.push(item);
        flattened.push(...flattenConfigItems(item.items));
    });
    return flattened;
}

let currentRoot = makeRoot('server');

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
        currentRoot = makeRoot(view.id);
    },
    expandAll() {
        currentRoot.cascadeBy((node) => node.expand());
    },
    collapseAll() {
        currentRoot.cascadeBy((node) => node.collapse());
    },
    getStore() {
        return {
            getRootNode: () => currentRoot,
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
global.Proxmox = {
    Utils: {
        API2Request(options) {
            apiRequests.push(options);
            if (options.method === 'GET') {
                options.success({
                    result: {
                        data: {
                            useIconNavigation: false,
                            groupByNode: true,
                            showPools: true,
                            showVirtualMachines: true,
                            showContainers: true,
                            showTemplates: true,
                            showStorage: false,
                            showNetwork: false,
                            showStoppedGuests: true,
                        },
                    },
                });
            } else {
                options.success({ result: { data: null } });
            }
        },
    },
};
global.Ext = {
    ClassManager: { get: () => true },
    ComponentQuery: { query: () => [tree] },
    util: {
        CSS: {
            createStyleSheet(css, id) {
                navigationStyle = { css, id };
            },
        },
    },
    get: () => null,
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
assert.equal(global.window.ProxMorphInventory.preferencesAvailable(), true);
assert.equal(apiRequests[0].method, 'GET');
assert.equal(apiRequests[0].url, '/proxmorph/preferences');
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
assert.equal(navigationStyle.id, 'proxmorph-inventory-navigation-style');
assert.match(
    navigationStyle.css,
    /\.pmx-view-nav-button\.x-btn\.x-btn-default-toolbar-small\.x-btn-pressed[^{]*\{[^}]*background-color: transparent !important;/s,
    'active view button overrides theme fills with a transparent background',
);
assert.match(
    navigationStyle.css,
    /border: 1px solid var\(--pm-border, var\(--gh-border-default, rgba\(127, 127, 127, 0\.42\)\)\) !important;/,
    'each view icon uses a theme-native outlined box',
);

const navigationItems = navigation.items;
assert.deepEqual(
    navigationItems.map((item) => item.margin),
    ['0 4 0 0', '0 4 0 0', '0 4 0 0', '0'],
    'outlined icon buttons have a consistent horizontal gap',
);
assert.deepEqual(
    navigationItems.map((item) => item.ariaLabel),
    ['Datacenter view', 'Inventory view', 'Storage view', 'Connectivity view'],
);
assert.match(
    navigationItems.find((item) => item.ariaLabel === 'Inventory view').tooltip,
    /node → resource pool → guest/,
);

assert.equal(selector.getViewFilter().id, 'server', 'native view behavior remains intact');

findNode(currentRoot, 'node/pve01').expand();
assert.equal(findNode(currentRoot, 'node/pve01').isExpanded(), true);

settingsButton.handler();
assert.equal(settingsWindow.config.modal, true, 'settings use an in-app modal');
assert.equal(settingsWindow.config.width, 600, 'settings modal has room for compact columns');
const settingsFormConfig = settingsWindow.config.items[0].config;
const settingsItems = flattenConfigItems(settingsFormConfig.items);
assert.ok(
    settingsItems.some((item) => item.name === 'useIconNavigation'),
    'settings modal exposes the icon-switcher option',
);
assert.ok(
    settingsItems.some((item) => item.name === 'groupByNode'),
    'settings modal exposes the hierarchy option',
);
assert.ok(
    settingsItems.some(
        (item) =>
            item.itemId === 'proxmorphPreferenceScope' &&
            /Authenticated Proxmox user/.test(item.html),
    ),
    'settings modal identifies account-level persistence',
);
assert.deepEqual(
    settingsFormConfig.items.map((item) => item.title),
    ['Navigation', 'Hierarchy', 'Visible resources', 'Account'],
    'settings are organized into compact task-focused sections',
);
assert.equal(
    settingsItems.some((item) => item.userCls === 'pmx-hint' || item.cls === 'pmx-hint'),
    false,
    'informational settings never use Proxmox warning styling',
);
assert.match(
    navigationStyle.css,
    /background-color: var\(--pm-bg-surface, var\(--gh-canvas-muted, var\(--pwt-panel-background, transparent\)\)\) !important;/,
    'modal surfaces inherit the active theme tokens',
);

const applyButton = settingsWindow.config.buttons.find((button) => button.text === 'Apply');
applyButton.handler();

assert.equal(apiRequests[1].method, 'PUT');
assert.equal(apiRequests[1].url, '/proxmorph/preferences');
assert.equal(apiRequests[1].params.groupByNode, 0);
assert.equal(apiRequests[1].params.useIconNavigation, 1);

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

findNode(currentRoot, 'pool/Automation').expand();
assert.equal(findNode(currentRoot, 'pool/Automation').isExpanded(), true);

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
assert.equal(
    findNode(currentRoot, 'node/pve01').isExpanded(),
    true,
    'Datacenter expansion state survives switching through custom views',
);

navigationItems.find((item) => item.ariaLabel === 'Inventory view').handler();
assert.equal(
    findNode(currentRoot, 'pool/Automation').isExpanded(),
    true,
    'Inventory expansion state is restored independently from Datacenter state',
);

console.log('PASS: ProxMorph Inventory and icon views integrate with native PVE tree controls');
