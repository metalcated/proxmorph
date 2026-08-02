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
let routedContent;
const apiRequests = [];
const documentClasses = new Set();
const definedClasses = {};
const nativeDatacenterMenuItem = { text: 'Bulk Start', itemId: 'bulkstart' };
const nativeNodeMenuItem = { text: 'Create VM', itemId: 'createvm' };
const classRegistry = {
    'PVE.dc.CmdMenu': { prototype: { items: [nativeDatacenterMenuItem] } },
    'PVE.node.CmdMenu': { prototype: { items: [nativeNodeMenuItem] } },
};
const availableClasses = new Set([
    'PVE.form.ViewSelector',
    'PVE.tree.ResourceTree',
    'PVE.panel.Config',
    'PVE.sdn.VnetEdit',
    'PVE.sdn.SubnetView',
    'PVE.sdn.VnetACLView',
    'PVE.dc.CmdMenu',
    'PVE.node.CmdMenu',
]);

function makeNode(id, children = [], expanded = false, text = id) {
    const node = {
        data: { id, text },
        childNodes: children,
        expanded,
        dirty: false,
        commitCount: 0,
        isLeaf() {
            return this.childNodes.length === 0;
        },
        isExpanded() {
            return this.expanded;
        },
        isRoot() {
            return id === 'root';
        },
        expand(recursive = false) {
            this.expanded = true;
            if (recursive) {
                this.childNodes.forEach((child) => child.expand(true));
            }
        },
        collapse(recursive = false) {
            this.expanded = false;
            if (recursive) {
                this.childNodes.forEach((child) => child.collapse(true));
            }
        },
        cascadeBy(callback) {
            callback(this);
            this.childNodes.forEach((child) => child.cascadeBy(callback));
        },
        set(field, value) {
            this.data[field] = value;
            this.dirty = true;
            if (id === 'root' && field === 'text') {
                rootText = value;
            }
        },
        commit() {
            this.dirty = false;
            this.commitCount++;
        },
        findChild(field, value, deep = false) {
            for (const child of this.childNodes) {
                if (child.data[field] === value) {
                    return child;
                }
                if (deep) {
                    const nested = child.findChild(field, value, true);
                    if (nested) {
                        return nested;
                    }
                }
            }
            return null;
        },
        appendChild(data) {
            const child = makeNode(data.id, [], false, data.text);
            child.data = { ...data };
            this.childNodes.push(child);
            return child;
        },
        removeChild(child) {
            this.childNodes = this.childNodes.filter((candidate) => candidate !== child);
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

function runContextAction(items, itemId, record) {
    items.find((item) => item.itemId === itemId).handler.call({
        up: () => ({ pveSelNode: record }),
    });
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

const workspace = {
    setContent(component) {
        routedContent = component;
        return component;
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
    up(selector) {
        return selector === 'pveStdWorkspace' ? workspace : null;
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
    showStoppedGuests: false,
    uiFont: 'modern',
    uiTextSize: 'comfortable',
};

// Mirrors the native Workspace listener that applies the selector's view to
// the existing PVE resource tree.
selector.on('select', (combo) => tree.setViewFilter(combo.getViewFilter()));

global.window = {
    location: { hostname: 'pve.gnet.com' },
    document: {
        documentElement: {
            classList: {
                add: (className) => documentClasses.add(className),
                remove: (className) => documentClasses.delete(className),
            },
        },
    },
};
global.PVE = {};
global.Proxmox = {
    Utils: {
        API2Request(options) {
            apiRequests.push(options);
            if (options.url === '/cluster/sdn/vnets') {
                options.success({
                    result: {
                        data: [{ vnet: 'prod-vnet', zone: 'prod-zone', state: 'new' }],
                    },
                });
            } else if (options.method === 'GET') {
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
                            uiFont: 'default',
                            uiTextSize: 'default',
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
    ClassManager: {
        get: (name) => classRegistry[name] || availableClasses.has(name),
    },
    define(name, config) {
        availableClasses.add(name);
        definedClasses[name] = config;
    },
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
assert.equal(
    definedClasses['ProxMorph.sdn.VnetBrowser'].alias,
    'widget.proxmorphVnetBrowser',
    'the scoped VNet browser is registered with ExtJS',
);
assert.equal(apiRequests[0].method, 'GET');
assert.equal(apiRequests[0].url, '/proxmorph/preferences');
assert.deepEqual(records, [
    { key: 'proxmorph-inventory', value: 'Inventory View' },
    { key: 'proxmorph-storage', value: 'Storage View' },
    { key: 'proxmorph-connectivity', value: 'Connectivity View' },
]);
assert.equal(settingsButton.itemId, 'proxmorphInventorySettings');
assert.equal(settingsButton.tooltip, 'Inventory and appearance settings');
assert.equal(navigation.itemId, 'proxmorphViewNavigation');
assert.equal(navigation.hidden, true, 'icon navigation is opt-in');
assert.equal(selector.hidden, false, 'native picker remains visible by default');
assert.equal(navigationStyle.id, 'proxmorph-inventory-navigation-style');
assert.deepEqual(
    [...documentClasses].sort(),
    ['proxmorph-font-default', 'proxmorph-text-default'],
    'saved typography classes are applied when the account preferences load',
);
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
    navigationItems.map((item) => [item.width, item.height]),
    [[34, 28], [34, 28], [34, 28], [34, 28]],
    'view icons match the compact native toolbar-button dimensions',
);
assert.ok(
    navigationItems.every(
        (item) =>
            item.cls.includes('x-btn-default-toolbar-small') &&
            item.iconCls.includes('x-btn-icon-el-default-toolbar-small'),
    ),
    'view buttons use the same toolbar and inner-icon styling as the surrounding controls',
);
assert.deepEqual(
    navigationItems.map((item) => item.margin),
    ['0 4 0 0', '0 4 0 0', '0 4 0 0', '0'],
    'outlined icon buttons have a consistent horizontal gap',
);
assert.match(
    navigationStyle.css,
    /\.pmx-view-nav-button \.x-btn-icon-el \{[^}]*align-items: center !important;[^}]*justify-content: center !important;[^}]*margin: 0 !important;/s,
    'view icons are explicitly centered without inherited icon offsets',
);
assert.deepEqual(
    navigationItems.map((item) => item.ariaLabel),
    ['Datacenter view', 'Inventory view', 'Storage view', 'Connectivity view'],
);
assert.match(
    navigationItems.find((item) => item.ariaLabel === 'Inventory view').tooltip,
    /node → resource pool → guest/,
);
assert.match(
    navigationItems.find((item) => item.ariaLabel === 'Connectivity view').tooltip,
    /zones, fabrics, VNets, and node networks/,
);

assert.equal(selector.getViewFilter().id, 'server', 'native view behavior remains intact');

findNode(currentRoot, 'node/pve01').expand();
assert.equal(findNode(currentRoot, 'node/pve01').isExpanded(), true);

const datacenterMenuItems = classRegistry['PVE.dc.CmdMenu'].prototype.items;
assert.equal(
    datacenterMenuItems[0],
    nativeDatacenterMenuItem,
    'native Datacenter menu configuration remains intact',
);
assert.deepEqual(
    datacenterMenuItems.filter((item) => item.text).map((item) => item.text),
    ['Bulk Start', 'Expand all', 'Collapse all'],
    'Datacenter context menu exposes both tree-wide actions',
);
runContextAction(datacenterMenuItems, 'proxmorphCollapseBranch', currentRoot);
assert.equal(currentRoot.isExpanded(), true, 'Collapse all keeps the Datacenter root visible');
assert.equal(findNode(currentRoot, 'node/pve01').isExpanded(), false);
runContextAction(datacenterMenuItems, 'proxmorphExpandBranch', currentRoot);
assert.equal(findNode(currentRoot, 'node/pve01').isExpanded(), true);

const nodeRecord = findNode(currentRoot, 'node/pve01');
const nodeMenuItems = classRegistry['PVE.node.CmdMenu'].prototype.items;
assert.equal(nodeMenuItems[0], nativeNodeMenuItem, 'native node menu configuration remains intact');
assert.deepEqual(
    nodeMenuItems.filter((item) => item.text).map((item) => item.text),
    ['Create VM', 'Expand branch', 'Collapse branch'],
    'node context menu scopes expansion actions to the selected branch',
);
runContextAction(nodeMenuItems, 'proxmorphCollapseBranch', nodeRecord);
assert.equal(nodeRecord.isExpanded(), false);
runContextAction(nodeMenuItems, 'proxmorphExpandBranch', nodeRecord);
assert.equal(nodeRecord.isExpanded(), true);

settingsButton.handler();
assert.equal(settingsWindow.config.modal, true, 'settings use an in-app modal');
assert.equal(settingsWindow.config.width, 640, 'settings modal has room for appearance controls');
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
    settingsItems.some((item) => item.name === 'uiFont'),
    'settings modal exposes the interface font option',
);
assert.ok(
    settingsItems.some((item) => item.name === 'uiTextSize'),
    'settings modal exposes the text-size option',
);
const stoppedGuestsControl = settingsItems.find(
    (item) => item.itemId === 'proxmorphShowStoppedGuests',
);
assert.ok(stoppedGuestsControl, 'settings modal exposes powered-off guest visibility');
assert.equal(stoppedGuestsControl.boxLabel, 'Show powered-off VMs and containers');
assert.ok(
    settingsItems.some(
        (item) =>
            item.itemId === 'proxmorphShowStoppedGuestsHelp' &&
            /hide stopped guests/.test(item.html),
    ),
    'the powered-off guest control explains its filtering behavior',
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
    ['Navigation', 'Hierarchy', 'Visible resources', 'Typography', 'Account'],
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
assert.match(
    navigationStyle.css,
    /--proxmorph-ui-font: "Roboto Flex", "Segoe UI Variable"/,
    'the modern option uses a native variable-font stack without changing icon fonts',
);
assert.match(
    navigationStyle.css,
    /html\.proxmorph-font-modern \.x-treelist-item-text[^}]*font-family: var\(--proxmorph-ui-font\) !important;/,
    'the VM and container navigation treelist inherits the selected interface font',
);
assert.match(
    navigationStyle.css,
    /html\[class\*="proxmorph-text-"\] \.x-treelist-item-text[^}]*font-size: var\(--proxmorph-ui-size\) !important;/,
    'the VM and container navigation treelist inherits the selected text scale',
);
assert.match(
    navigationStyle.css,
    /html body \.x-menu-body-default[^}]*var\(--pm-bg-surface, var\(--gh-canvas-muted\)\) !important;/,
    'floating menus resolve their surface color from the active theme tokens',
);
assert.match(
    navigationStyle.css,
    /html body \.x-panel-header-title-default[^}]*var\(--pm-text, var\(--gh-fg-default\)\) !important;/,
    'default ExtJS title subclasses resolve text color from the active theme tokens',
);

const applyButton = settingsWindow.config.buttons.find((button) => button.text === 'Apply');
applyButton.handler();

assert.equal(apiRequests[1].method, 'PUT');
assert.equal(apiRequests[1].url, '/proxmorph/preferences');
assert.equal(apiRequests[1].params.groupByNode, 0);
assert.equal(apiRequests[1].params.useIconNavigation, 1);
assert.equal(apiRequests[1].params.showStoppedGuests, 0);
assert.equal(apiRequests[1].params.uiFont, 'modern');
assert.equal(apiRequests[1].params.uiTextSize, 'comfortable');
assert.deepEqual(
    [...documentClasses].sort(),
    ['proxmorph-font-modern', 'proxmorph-text-comfortable'],
    'Apply switches typography immediately after the account save succeeds',
);

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
assert.equal(currentRoot.dirty, false, 'root relabeling does not leave an ExtJS dirty marker');
assert.ok(currentRoot.commitCount > 0, 'the presentation-only root label is committed');
assert.deepEqual(appliedView.groups, ['pool']);
assert.equal(appliedView.getFilterFn()({ data: { type: 'qemu', status: 'running' } }), false);
assert.equal(appliedView.getFilterFn()({ data: { type: 'storage' } }), false);
assert.equal(appliedView.getFilterFn()({ data: { type: 'lxc', status: 'running' } }), true);
assert.equal(
    appliedView.getFilterFn()({ data: { type: 'lxc', status: 'stopped' } }),
    false,
    'Apply immediately hides powered-off guests when the control is disabled',
);
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
assert.equal(appliedView.getFilterFn()({ data: { type: 'proxmorph-vnet' } }), true);
assert.equal(appliedView.getFilterFn()({ data: { type: 'storage' } }), false);
const vnetRequest = apiRequests.find((request) => request.url === '/cluster/sdn/vnets');
assert.ok(vnetRequest, 'Connections loads the permission-filtered Proxmox VNet endpoint');
assert.equal(vnetRequest.method, 'GET');
assert.equal(vnetRequest.params.pending, 1);
const vnetNode = findNode(currentRoot, 'proxmorph-vnet/prod-vnet');
assert.ok(vnetNode, 'the Connections tree receives the VNet record');
assert.equal(vnetNode.data.zone, 'prod-zone');
assert.equal(vnetNode.data.iconCls, 'fa fa-network-wired x-fa-treepanel');

workspace.setContent({ xtype: 'pvePanelConfig', pveSelNode: vnetNode });
assert.equal(
    routedContent.xtype,
    'proxmorphVnetBrowser',
    'selecting a VNet routes to its scoped Proxmox browser',
);
assert.equal(routedContent.showSearch, false);
const vnetBrowser = {
    pveSelNode: vnetNode,
    callParent() {
        this.parentCalled = true;
    },
};
definedClasses['ProxMorph.sdn.VnetBrowser'].initComponent.call(vnetBrowser);
assert.equal(vnetBrowser.parentCalled, true);
assert.equal(vnetBrowser.showSearch, false);
assert.equal(vnetBrowser.items[0].xtype, 'pveSDNSubnetView');
assert.equal(vnetBrowser.items[0].base_url, '/cluster/sdn/vnets/prod-vnet/subnets');
assert.equal(vnetBrowser.items[1].xtype, 'pveSDNVnetACLView');
assert.equal(vnetBrowser.items[1].path, '/sdn/zones/prod-zone/prod-vnet');

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
