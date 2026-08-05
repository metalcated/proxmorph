/**
 * ProxMorph Inventory View
 *
 * Adds an optional ESXi/vCenter-inspired inventory mode to the Proxmox VE
 * resource tree. The view uses Proxmox's existing resource records, resource
 * pools, permissions, and selection routing; it does not create or mutate
 * inventory objects.
 *
 * Compatibility: Proxmox VE 8.x, 9.2.6+, and later releases that retain the
 * PVE.form.ViewSelector and PVE.tree.ResourceTree extension points.
 *
 * Preferences are stored per authenticated Proxmox user through ProxMorph's
 * protected API and the replicated Proxmox cluster filesystem. The selected
 * view itself continues to use Proxmox's native URL state.
 *
 * Version: 1.9.0
 */
(function () {
    'use strict';

    var VIEW_KEY = 'proxmorph-inventory';
    var VIEW_NAME = 'Inventory View';
    var STORAGE_VIEW_KEY = 'proxmorph-storage';
    var CONNECTIVITY_VIEW_KEY = 'proxmorph-connectivity';
    var VNET_TYPE = 'proxmorph-vnet';
    var VNETS_URL = '/cluster/sdn/vnets';
    var VERSION = '1.9.0';
    var PREFERENCES_URL = '/proxmorph/preferences';
    var MAX_INIT_ATTEMPTS = 40;
    var initAttempts = 0;
    var initialized = false;
    var preferencesAvailable = false;
    var expansionStateByView = {};
    var connectivityVnets = [];
    var connectivityVnetsLoading = false;
    var vnetRoutingAvailable = false;
    var treeContextResourceTree = null;
    var treeContextViewSelector = null;

    var booleanSettingKeys = [
        'useIconNavigation',
        'groupByNode',
        'showPools',
        'showVirtualMachines',
        'showContainers',
        'showTemplates',
        'showStorage',
        'showNetwork',
        'showStoppedGuests',
        'noVncContextMenu',
        'noVncClipboardShortcuts',
    ];
    var choiceSettings = {
        uiFont: ['default', 'modern'],
        uiTextSize: ['default', 'comfortable', 'large'],
    };
    var defaults = {
        useIconNavigation: false,
        groupByNode: true,
        showPools: true,
        showVirtualMachines: true,
        showContainers: true,
        showTemplates: true,
        showStorage: false,
        showNetwork: false,
        showStoppedGuests: true,
        noVncContextMenu: true,
        noVncClipboardShortcuts: false,
        uiFont: 'default',
        uiTextSize: 'default',
    };

    var settings = copySettings(defaults);

    function copySettings(source) {
        var copy = {};
        Object.keys(defaults).forEach(function (key) {
            copy[key] = source[key];
        });
        return copy;
    }

    function normalizeBoolean(value) {
        return (
            value === true ||
            value === 1 ||
            value === '1' ||
            value === 'true' ||
            value === 'on'
        );
    }

    function normalizeChoice(key, value) {
        return choiceSettings[key].indexOf(value) !== -1 ? value : defaults[key];
    }

    function updateSettings(values) {
        booleanSettingKeys.forEach(function (key) {
            if (Object.prototype.hasOwnProperty.call(values || {}, key)) {
                settings[key] = normalizeBoolean(values[key]);
            }
        });
        Object.keys(choiceSettings).forEach(function (key) {
            if (Object.prototype.hasOwnProperty.call(values || {}, key)) {
                settings[key] = normalizeChoice(key, values[key]);
            }
        });
        return copySettings(settings);
    }

    function hasPreferencesAPI() {
        return (
            typeof Proxmox !== 'undefined' &&
            Proxmox.Utils &&
            typeof Proxmox.Utils.API2Request === 'function'
        );
    }

    function serializeSettings(values) {
        var serialized = {};
        var normalized = copySettings(defaults);
        booleanSettingKeys.forEach(function (key) {
            if (Object.prototype.hasOwnProperty.call(values || {}, key)) {
                normalized[key] = normalizeBoolean(values[key]);
            }
            serialized[key] = normalized[key] ? 1 : 0;
        });
        Object.keys(choiceSettings).forEach(function (key) {
            if (Object.prototype.hasOwnProperty.call(values || {}, key)) {
                normalized[key] = normalizeChoice(key, values[key]);
            }
            serialized[key] = normalized[key];
        });
        return serialized;
    }

    function typographyClassNames(values) {
        return [
            'proxmorph-font-' + normalizeChoice('uiFont', values.uiFont),
            'proxmorph-text-' + normalizeChoice('uiTextSize', values.uiTextSize),
        ];
    }

    function applyTypographySettings(refreshLayout) {
        var documentRoot = window.document && window.document.documentElement;
        if (!documentRoot || !documentRoot.classList) {
            return;
        }

        ['default', 'modern'].forEach(function (name) {
            documentRoot.classList.remove('proxmorph-font-' + name);
        });
        ['default', 'comfortable', 'large'].forEach(function (name) {
            documentRoot.classList.remove('proxmorph-text-' + name);
        });
        typographyClassNames(settings).forEach(function (className) {
            documentRoot.classList.add(className);
        });

        if (
            refreshLayout &&
            typeof Ext !== 'undefined' &&
            Ext.ComponentQuery &&
            Ext.ComponentQuery.query
        ) {
            Ext.ComponentQuery.query('viewport').forEach(function (viewport) {
                if (viewport && viewport.updateLayout) {
                    viewport.updateLayout();
                }
            });
        }
    }

    function loadPreferences(callback) {
        if (!hasPreferencesAPI()) {
            callback();
            return;
        }

        Proxmox.Utils.API2Request({
            url: PREFERENCES_URL,
            method: 'GET',
            success: function (response) {
                updateSettings(response && response.result ? response.result.data : {});
                preferencesAvailable = true;
                callback();
            },
            failure: function (response) {
                preferencesAvailable = false;
                if (window.console && console.warn) {
                    console.warn(
                        '[ProxMorph Inventory] User preferences could not be loaded; using defaults.',
                        response && response.htmlStatus ? response.htmlStatus : '',
                    );
                }
                callback();
            },
        });
    }

    function savePreferences(values, waitTarget, success, failure) {
        if (!hasPreferencesAPI()) {
            success(false);
            return;
        }

        Proxmox.Utils.API2Request({
            url: PREFERENCES_URL,
            method: 'PUT',
            params: serializeSettings(values),
            waitMsgTarget: waitTarget,
            success: function () {
                preferencesAvailable = true;
                success(true);
            },
            failure: function (response) {
                preferencesAvailable = false;
                failure(response);
            },
        });
    }

    function resourceIsVisible(item) {
        var data = item && item.data ? item.data : {};
        var type = data.type;

        // Nodes are real navigable records. Hide them when the user chooses the
        // vCenter-like Datacenter -> Pool -> Guest hierarchy.
        if (type === 'node') {
            return settings.groupByNode;
        }

        // With node grouping, native pool records would appear once at the
        // root and duplicate the per-node pool groups. In the vCenter-like
        // pool-only hierarchy, keep the native pool record so its selection
        // continues to route to Proxmox's real pool page.
        if (type === 'pool') {
            return settings.showPools && !settings.groupByNode;
        }

        if (type === 'qemu' || type === 'lxc') {
            if (data.template) {
                return settings.showTemplates;
            }
            if (!settings.showStoppedGuests && data.status !== 'running') {
                return false;
            }
            return type === 'qemu' ? settings.showVirtualMachines : settings.showContainers;
        }

        if (type === 'storage') {
            return settings.showStorage;
        }

        if (type === 'sdn' || type === 'network') {
            return settings.showNetwork;
        }

        return false;
    }

    function getInventoryGroups() {
        var groups = [];
        if (settings.groupByNode) {
            groups.push('node');
        }
        if (settings.showPools) {
            groups.push('pool');
        }
        return groups;
    }

    function buildInventoryViewFilter() {
        return {
            id: VIEW_KEY,
            // ResourceTree understands both attributes. Pools stay native PVE
            // resource/permission groups; only their presentation is folder-like.
            groups: getInventoryGroups(),
            getFilterFn: function () {
                return resourceIsVisible;
            },
        };
    }

    function buildStorageViewFilter() {
        return {
            id: STORAGE_VIEW_KEY,
            groups: ['node'],
            getFilterFn: function () {
                return function (item) {
                    var type = item && item.data ? item.data.type : undefined;
                    return type === 'node' || type === 'storage';
                };
            },
        };
    }

    function normalizeConnectivityVnets(records) {
        return (Array.isArray(records) ? records : [])
            .filter(function (record) {
                return record && record.vnet && record.state !== 'deleted';
            })
            .map(function (record) {
                var pending = record.pending && typeof record.pending === 'object' ? record.pending : {};
                return {
                    vnet: String(record.vnet),
                    zone: record.zone || pending.zone || '',
                    state: record.state || '',
                };
            })
            .sort(function (left, right) {
                return left.vnet.localeCompare(right.vnet);
            });
    }

    function buildConnectivityVnetNode(record) {
        return {
            id: VNET_TYPE + '/' + record.vnet,
            type: VNET_TYPE,
            text: record.vnet,
            vnet: record.vnet,
            zone: record.zone || '',
            state: record.state || '',
            hastate: 'unmanaged',
            iconCls: 'fa fa-network-wired x-fa-treepanel',
            leaf: true,
        };
    }

    function buildConnectivityViewFilter() {
        return {
            id: CONNECTIVITY_VIEW_KEY,
            groups: ['node'],
            getFilterFn: function () {
                return function (item) {
                    var type = item && item.data ? item.data.type : undefined;
                    return (
                        type === 'node' ||
                        type === 'sdn' ||
                        type === 'network' ||
                        type === VNET_TYPE
                    );
                };
            },
        };
    }

    function buildViewFilter(viewKey) {
        if (viewKey === STORAGE_VIEW_KEY) {
            return buildStorageViewFilter();
        }
        if (viewKey === CONNECTIVITY_VIEW_KEY) {
            return buildConnectivityViewFilter();
        }
        return buildInventoryViewFilter();
    }

    function findDirectChild(root, id) {
        if (!root) {
            return null;
        }
        if (root.findChild) {
            return root.findChild('id', id, false);
        }
        var children = root.childNodes || [];
        for (var index = 0; index < children.length; index++) {
            if (children[index].data && children[index].data.id === id) {
                return children[index];
            }
        }
        return null;
    }

    function syncConnectivityVnetNodes(viewSelector, resourceTree) {
        if (
            !vnetRoutingAvailable ||
            viewSelector.getValue() !== CONNECTIVITY_VIEW_KEY ||
            !resourceTree ||
            !resourceTree.getStore
        ) {
            return;
        }

        var root = resourceTree.getStore().getRootNode();
        if (!root) {
            return;
        }

        var expected = {};
        connectivityVnets.forEach(function (record) {
            var data = buildConnectivityVnetNode(record);
            expected[data.id] = true;
            var existing = findDirectChild(root, data.id);
            if (existing) {
                if (existing.beginEdit) {
                    existing.beginEdit();
                }
                Object.keys(data).forEach(function (key) {
                    if (existing.set) {
                        existing.set(key, data[key]);
                    } else {
                        existing.data[key] = data[key];
                    }
                });
                if (existing.commit) {
                    existing.commit();
                }
            } else if (root.appendChild) {
                root.appendChild(data);
            }
        });

        (root.childNodes || []).slice().forEach(function (child) {
            if (
                child.data &&
                child.data.type === VNET_TYPE &&
                !expected[child.data.id] &&
                root.removeChild
            ) {
                root.removeChild(child, true);
            }
        });

        if (root.sort && resourceTree.nodeSortFn) {
            root.sort(resourceTree.nodeSortFn.bind(resourceTree), true);
        }
    }

    function ensureVnetBrowserClass() {
        if (
            typeof Ext === 'undefined' ||
            !Ext.ClassManager ||
            !Ext.ClassManager.get ||
            !Ext.define
        ) {
            return false;
        }

        if (Ext.ClassManager.get('ProxMorph.sdn.VnetBrowser')) {
            return true;
        }

        var requiredClasses = [
            'PVE.panel.Config',
            'PVE.sdn.VnetEdit',
            'PVE.sdn.SubnetView',
            'PVE.sdn.VnetACLView',
        ];
        for (var index = 0; index < requiredClasses.length; index++) {
            if (!Ext.ClassManager.get(requiredClasses[index])) {
                return false;
            }
        }

        Ext.define('ProxMorph.sdn.VnetBrowser', {
            extend: 'PVE.panel.Config',
            alias: 'widget.proxmorphVnetBrowser',

            initComponent: function () {
                var me = this;
                var data = me.pveSelNode && me.pveSelNode.data ? me.pveSelNode.data : {};
                var vnet = data.vnet || data.text;
                var zone = data.zone;
                var encodedVnet = encodeURIComponent(vnet);

                me.title = 'VNet ' + vnet;
                me.onlineHelp = 'pvesdn_config_vnet';
                me.showSearch = false;
                me.tbar = [
                    {
                        text: 'Edit',
                        iconCls: 'fa fa-pencil',
                        handler: function () {
                            Ext.create('PVE.sdn.VnetEdit', {
                                autoShow: true,
                                vnet: vnet,
                            });
                        },
                    },
                ];
                me.items = [
                    {
                        xtype: 'pveSDNSubnetView',
                        itemId: 'subnets',
                        title: 'Subnets',
                        iconCls: 'fa fa-exchange',
                        base_url: '/cluster/sdn/vnets/' + encodedVnet + '/subnets',
                    },
                ];
                if (zone) {
                    me.items.push({
                        xtype: 'pveSDNVnetACLView',
                        itemId: 'permissions',
                        title: 'Permissions',
                        iconCls: 'fa fa-key',
                        path:
                            '/sdn/zones/' +
                            encodeURIComponent(zone) +
                            '/' +
                            encodedVnet,
                    });
                }

                me.callParent();
            },
        });

        return true;
    }

    function installVnetRouting(resourceTree) {
        if (!ensureVnetBrowserClass()) {
            return false;
        }

        var workspace = resourceTree.up ? resourceTree.up('pveStdWorkspace') : null;
        if (!workspace || !workspace.setContent) {
            return false;
        }
        if (workspace.__proxmorphVnetRouting) {
            return true;
        }

        workspace.__proxmorphVnetRouting = workspace.setContent;
        workspace.setContent = function (component) {
            if (
                component &&
                component.pveSelNode &&
                component.pveSelNode.data &&
                component.pveSelNode.data.type === VNET_TYPE
            ) {
                component.xtype = 'proxmorphVnetBrowser';
                component.showSearch = false;
            }
            return this.__proxmorphVnetRouting.call(this, component);
        };
        return true;
    }

    function loadConnectivityVnets(viewSelector, resourceTree) {
        if (!vnetRoutingAvailable || connectivityVnetsLoading || !hasPreferencesAPI()) {
            return;
        }

        connectivityVnetsLoading = true;
        Proxmox.Utils.API2Request({
            url: VNETS_URL,
            method: 'GET',
            params: { pending: 1 },
            success: function (response) {
                connectivityVnetsLoading = false;
                connectivityVnets = normalizeConnectivityVnets(
                    response && response.result ? response.result.data : [],
                );
                syncConnectivityVnetNodes(viewSelector, resourceTree);
            },
            failure: function (response) {
                connectivityVnetsLoading = false;
                if (window.console && console.warn) {
                    console.warn(
                        '[ProxMorph Inventory] VNets could not be loaded; Connections will show the native network records.',
                        response && response.htmlStatus ? response.htmlStatus : '',
                    );
                }
            },
        });
    }

    function installConnectivityRefresh(viewSelector, resourceTree) {
        var resourceStore =
            typeof PVE !== 'undefined' && PVE.data ? PVE.data.ResourceStore : null;
        if (!resourceStore || !resourceStore.on || resourceTree.__proxmorphVnetRefresh) {
            return;
        }
        resourceTree.__proxmorphVnetRefresh = true;
        resourceStore.on('load', function () {
            syncConnectivityVnetNodes(viewSelector, resourceTree);
        });
    }

    function getHierarchyLabel() {
        var parts = ['Datacenter'];
        if (settings.groupByNode) {
            parts.push('node');
        }
        if (settings.showPools) {
            parts.push('resource pool');
        }
        parts.push('guest');
        return parts.join(' → ');
    }

    function getResourceTree() {
        var trees = Ext.ComponentQuery.query('pveResourceTree');
        return trees && trees.length ? trees[0] : null;
    }

    function visitTreeNodes(root, callback) {
        if (!root) {
            return;
        }
        if (root.cascadeBy) {
            root.cascadeBy(callback);
            return;
        }
        callback(root);
        (root.childNodes || []).forEach(function (child) {
            visitTreeNodes(child, callback);
        });
    }

    function isExpandableNode(node) {
        if (!node) {
            return false;
        }
        if (node.isLeaf && node.isLeaf()) {
            return false;
        }
        return !node.isLeaf || (node.childNodes && node.childNodes.length > 0);
    }

    function captureExpansionState(resourceTree, viewKey) {
        if (!resourceTree || !viewKey || !resourceTree.getStore) {
            return;
        }
        var root = resourceTree.getStore().getRootNode();
        var expanded = [];
        visitTreeNodes(root, function (node) {
            if (
                node !== root &&
                isExpandableNode(node) &&
                node.isExpanded &&
                node.isExpanded() &&
                node.data &&
                node.data.id
            ) {
                expanded.push(node.data.id);
            }
        });
        expansionStateByView[viewKey] = expanded;
    }

    function restoreExpansionState(resourceTree, viewKey) {
        if (
            !resourceTree ||
            !viewKey ||
            !resourceTree.getStore ||
            !Object.prototype.hasOwnProperty.call(expansionStateByView, viewKey)
        ) {
            return;
        }
        var root = resourceTree.getStore().getRootNode();
        var expanded = {};
        expansionStateByView[viewKey].forEach(function (id) {
            expanded[id] = true;
        });
        visitTreeNodes(root, function (node) {
            if (node === root || !isExpandableNode(node) || !node.data || !node.data.id) {
                return;
            }
            if (expanded[node.data.id]) {
                if (node.expand) {
                    node.expand(false);
                }
            } else if (node.collapse) {
                node.collapse(false);
            }
        });
        if (root && root.expand) {
            root.expand(false);
        }
    }

    function updateExpansionMemory() {
        if (treeContextResourceTree && treeContextViewSelector) {
            captureExpansionState(
                treeContextResourceTree,
                treeContextViewSelector.getValue(),
            );
        }
    }

    function expandContextBranch(record) {
        if (!record || !treeContextResourceTree) {
            return;
        }
        if (record.isRoot && record.isRoot()) {
            treeContextResourceTree.expandAll();
        } else if (record.expand) {
            record.expand(true);
        }
        updateExpansionMemory();
    }

    function collapseContextBranch(record) {
        if (!record || !treeContextResourceTree) {
            return;
        }
        if (record.isRoot && record.isRoot()) {
            treeContextResourceTree.collapseAll();
            if (record.expand) {
                record.expand(false);
            }
        } else if (record.collapse) {
            record.collapse(true);
        }
        updateExpansionMemory();
    }

    function buildTreeContextActions(rootAction) {
        return [
            {
                xtype: 'menuseparator',
                itemId: 'proxmorphTreeExpansionSeparator',
            },
            {
                text: rootAction ? 'Expand all' : 'Expand branch',
                itemId: 'proxmorphExpandBranch',
                iconCls: 'fa fa-fw fa-plus-square-o',
                handler: function () {
                    var menu = this.up ? this.up('menu') : null;
                    expandContextBranch(menu && menu.pveSelNode);
                },
            },
            {
                text: rootAction ? 'Collapse all' : 'Collapse branch',
                itemId: 'proxmorphCollapseBranch',
                iconCls: 'fa fa-fw fa-minus-square-o',
                handler: function () {
                    var menu = this.up ? this.up('menu') : null;
                    collapseContextBranch(menu && menu.pveSelNode);
                },
            },
        ];
    }

    function appendTreeContextActions(menuClass, rootAction) {
        var prototype = menuClass && menuClass.prototype;
        if (!prototype || prototype.__proxmorphTreeExpansionItems) {
            return false;
        }
        var nativeItems = Array.isArray(prototype.items) ? prototype.items.slice() : [];
        prototype.items = nativeItems.concat(buildTreeContextActions(rootAction));
        prototype.__proxmorphTreeExpansionItems = true;
        return true;
    }

    function installTreeContextActions(viewSelector, resourceTree) {
        if (
            typeof Ext === 'undefined' ||
            !Ext.ClassManager ||
            !Ext.ClassManager.get ||
            !Ext.ClassManager.get('PVE.dc.CmdMenu') ||
            !Ext.ClassManager.get('PVE.node.CmdMenu')
        ) {
            return false;
        }

        treeContextResourceTree = resourceTree;
        treeContextViewSelector = viewSelector;
        appendTreeContextActions(Ext.ClassManager.get('PVE.dc.CmdMenu'), true);
        appendTreeContextActions(Ext.ClassManager.get('PVE.node.CmdMenu'), false);
        return true;
    }

    function setInventoryMode(viewSelector, resourceTree) {
        var isInventory = viewSelector.getValue() === VIEW_KEY;
        if (resourceTree && resourceTree.toggleCls) {
            resourceTree.toggleCls('proxmorph-inventory-tree', isInventory);
        }
    }

    function labelIconViewRoot(viewSelector, resourceTree) {
        var viewKey = viewSelector.getValue();
        var isIconView =
            viewKey === VIEW_KEY ||
            viewKey === STORAGE_VIEW_KEY ||
            viewKey === CONNECTIVITY_VIEW_KEY;
        var hostname = window.location && window.location.hostname;
        if (!settings.useIconNavigation || !isIconView || !hostname || !resourceTree.getStore) {
            return;
        }
        var root = resourceTree.getStore().getRootNode();
        if (!root) {
            return;
        }
        if (root.set) {
            root.set('text', hostname);
            if (root.commit) {
                root.commit();
            }
        } else if (root.data) {
            root.data.text = hostname;
        }
    }

    function selectView(viewSelector, resourceTree, viewKey) {
        var record = viewSelector.getStore().findRecord('key', viewKey, 0, false, true, true);
        if (!record) {
            return;
        }
        var previousView = viewSelector.getValue();
        if (previousView !== viewKey) {
            captureExpansionState(resourceTree, previousView);
        }
        viewSelector.setValue(viewKey);
        viewSelector.fireEvent('select', viewSelector, [record]);
        setInventoryMode(viewSelector, resourceTree);
        labelIconViewRoot(viewSelector, resourceTree);
        updateNavigationSelection(viewSelector);
    }

    function refreshInventoryView(viewSelector, resourceTree) {
        if (viewSelector.getValue() === VIEW_KEY) {
            captureExpansionState(resourceTree, VIEW_KEY);
            resourceTree.setViewFilter(buildInventoryViewFilter());
            restoreExpansionState(resourceTree, VIEW_KEY);
            labelIconViewRoot(viewSelector, resourceTree);
        } else {
            selectView(viewSelector, resourceTree, VIEW_KEY);
        }
    }

    function getNavigation(viewSelector) {
        var toolbar = viewSelector.ownerCt;
        return toolbar && toolbar.down ? toolbar.down('#proxmorphViewNavigation') : null;
    }

    function getNavigationButton(navigation, viewKey) {
        if (!navigation) {
            return null;
        }
        if (navigation.down) {
            return navigation.down('#proxmorphView-' + viewKey);
        }
        var items = navigation.items && navigation.items.items ? navigation.items.items : navigation.items || [];
        for (var index = 0; index < items.length; index++) {
            if (items[index].itemId === 'proxmorphView-' + viewKey) {
                return items[index];
            }
        }
        return null;
    }

    function updateNavigationSelection(viewSelector) {
        var navigation = getNavigation(viewSelector);
        var viewKey = viewSelector.getValue();
        ['server', VIEW_KEY, STORAGE_VIEW_KEY, CONNECTIVITY_VIEW_KEY].forEach(function (key) {
            var button = getNavigationButton(navigation, key);
            if (!button) {
                return;
            }
            var pressed = key === viewKey;
            if (button.setPressed) {
                button.setPressed(pressed);
            } else if (button.toggle) {
                button.toggle(pressed, true);
            } else {
                button.pressed = pressed;
            }
        });
    }

    function setComponentVisible(component, visible) {
        if (!component) {
            return;
        }
        if (component.setVisible) {
            component.setVisible(visible);
        } else {
            component.hidden = !visible;
        }
    }

    function syncNavigationMode(viewSelector) {
        setComponentVisible(viewSelector, !settings.useIconNavigation);
        setComponentVisible(getNavigation(viewSelector), settings.useIconNavigation);
        updateNavigationTooltips(viewSelector);
        updateNavigationSelection(viewSelector);
    }

    function createSettingsWindow(viewSelector, resourceTree) {
        var accountTitle = preferencesAvailable
            ? 'Authenticated Proxmox user'
            : 'Preference service unavailable';
        var accountDescription = preferencesAvailable
            ? 'Saved cluster-wide for the signed-in account.'
            : 'Apply will retry saving these settings to the account.';
        var form = Ext.create('Ext.form.Panel', {
            cls: 'proxmorph-inventory-settings',
            border: false,
            bodyPadding: 16,
            autoScroll: true,
            items: [
                {
                    xtype: 'fieldset',
                    title: 'Navigation',
                    cls: 'pmx-inventory-section',
                    margin: '0 0 12 0',
                    items: [
                        {
                            xtype: 'checkboxfield',
                            name: 'useIconNavigation',
                            boxLabel: 'Use icon view switcher',
                            inputValue: true,
                            uncheckedValue: false,
                            checked: settings.useIconNavigation,
                            cls: 'pmx-inventory-option',
                        },
                        {
                            xtype: 'component',
                            cls: 'pmx-inventory-help',
                            html: 'Replaces the dropdown with Datacenter, Inventory, Storage, and Connectivity shortcuts.',
                        },
                    ],
                },
                {
                    xtype: 'fieldset',
                    title: 'Hierarchy',
                    cls: 'pmx-inventory-section',
                    margin: '0 0 12 0',
                    items: [
                        {
                            xtype: 'component',
                            itemId: 'proxmorphHierarchySummary',
                            cls: 'pmx-inventory-summary',
                            html:
                                '<span class="pmx-inventory-summary-label">Active structure</span>' +
                                '<strong class="pmx-inventory-summary-value">' +
                                getHierarchyLabel() +
                                '</strong>',
                        },
                        {
                            xtype: 'checkboxfield',
                            name: 'groupByNode',
                            boxLabel: 'Show node level',
                            inputValue: true,
                            uncheckedValue: false,
                            checked: settings.groupByNode,
                            cls: 'pmx-inventory-option',
                        },
                        {
                            xtype: 'component',
                            cls: 'pmx-inventory-help',
                            html: 'Groups pools and guests beneath their Proxmox node.',
                        },
                        {
                            xtype: 'checkboxfield',
                            name: 'showPools',
                            boxLabel: 'Show resource-pool folders',
                            inputValue: true,
                            uncheckedValue: false,
                            checked: settings.showPools,
                            cls: 'pmx-inventory-option',
                        },
                        {
                            xtype: 'component',
                            cls: 'pmx-inventory-help pmx-inventory-help-last',
                            html: 'Keeps guests organized inside their existing Proxmox pools.',
                        },
                    ],
                },
                {
                    xtype: 'fieldset',
                    title: 'Visible resources',
                    cls: 'pmx-inventory-section',
                    margin: '0 0 12 0',
                    items: [
                        {
                            xtype: 'checkboxfield',
                            name: 'showStoppedGuests',
                            itemId: 'proxmorphShowStoppedGuests',
                            boxLabel: 'Show powered-off VMs and containers',
                            inputValue: true,
                            uncheckedValue: false,
                            checked: settings.showStoppedGuests,
                            cls: 'pmx-inventory-option',
                        },
                        {
                            xtype: 'component',
                            itemId: 'proxmorphShowStoppedGuestsHelp',
                            cls: 'pmx-inventory-help',
                            html: 'Turn this off to hide stopped guests from Inventory View.',
                        },
                        {
                            xtype: 'container',
                            layout: 'column',
                            defaults: {
                                xtype: 'checkboxfield',
                                columnWidth: 0.5,
                                inputValue: true,
                                uncheckedValue: false,
                                cls: 'pmx-inventory-resource-option',
                                margin: '0 0 8 0',
                            },
                            items: [
                                {
                                    name: 'showVirtualMachines',
                                    boxLabel: 'Virtual machines',
                                    checked: settings.showVirtualMachines,
                                },
                                {
                                    name: 'showContainers',
                                    boxLabel: 'Containers',
                                    checked: settings.showContainers,
                                },
                                {
                                    name: 'showTemplates',
                                    boxLabel: 'Templates',
                                    checked: settings.showTemplates,
                                },
                                {
                                    name: 'showStorage',
                                    boxLabel: 'Storage',
                                    checked: settings.showStorage,
                                },
                                {
                                    name: 'showNetwork',
                                    boxLabel: 'SDN and network resources',
                                    checked: settings.showNetwork,
                                },
                            ],
                        },
                        {
                            xtype: 'component',
                            cls: 'pmx-inventory-help pmx-inventory-help-last pmx-inventory-resource-help',
                            html: 'Storage and Connectivity remain available in their dedicated views.',
                        },
                    ],
                },
                {
                    xtype: 'fieldset',
                    title: 'Typography',
                    cls: 'pmx-inventory-section pmx-typography-section',
                    margin: '0 0 12 0',
                    defaults: {
                        xtype: 'combo',
                        queryMode: 'local',
                        editable: false,
                        forceSelection: true,
                        valueField: 'field1',
                        displayField: 'field2',
                        labelWidth: 130,
                        anchor: '100%',
                    },
                    items: [
                        {
                            name: 'uiFont',
                            fieldLabel: 'Interface font',
                            value: settings.uiFont,
                            store: [
                                ['default', 'Proxmox default'],
                                ['modern', 'Modern system (recommended)'],
                            ],
                        },
                        {
                            xtype: 'component',
                            cls: 'pmx-inventory-help pmx-typography-help',
                            html: 'Uses Roboto Flex when available, followed by the operating system\'s native UI font. Icons and console text keep their purpose-built fonts.',
                        },
                        {
                            name: 'uiTextSize',
                            fieldLabel: 'Text size',
                            value: settings.uiTextSize,
                            store: [
                                ['default', 'Default — 13 px'],
                                ['comfortable', 'Comfortable — 14 px (recommended)'],
                                ['large', 'Large — 15 px'],
                            ],
                        },
                        {
                            xtype: 'component',
                            cls: 'pmx-inventory-help pmx-inventory-help-last pmx-typography-help',
                            html: 'Scales interface labels, controls, menus, and resource-tree rows together.',
                        },
                    ],
                },
                {
                    xtype: 'fieldset',
                    title: 'Console clipboard',
                    cls: 'pmx-inventory-section',
                    margin: '0 0 12 0',
                    items: [
                        {
                            xtype: 'checkboxfield',
                            name: 'noVncContextMenu',
                            boxLabel: 'Enable Option/Alt + right-click clipboard menu',
                            inputValue: true,
                            uncheckedValue: false,
                            checked: settings.noVncContextMenu,
                            cls: 'pmx-inventory-option',
                        },
                        {
                            xtype: 'component',
                            cls: 'pmx-inventory-help',
                            html: 'Uses Option on macOS or Alt elsewhere. Normal right-click remains available inside the guest.',
                        },
                        {
                            xtype: 'checkboxfield',
                            name: 'noVncClipboardShortcuts',
                            boxLabel: 'Capture Ctrl+C and Ctrl+V in noVNC',
                            inputValue: true,
                            uncheckedValue: false,
                            checked: settings.noVncClipboardShortcuts,
                            cls: 'pmx-inventory-option',
                        },
                        {
                            xtype: 'component',
                            cls: 'pmx-inventory-help pmx-inventory-help-last',
                            html: 'Optional. ProxMorph forwards the shortcut to the guest and synchronizes plain text with the browser clipboard.',
                        },
                    ],
                },
                {
                    xtype: 'fieldset',
                    title: 'Account',
                    cls: 'pmx-inventory-section pmx-inventory-account-section',
                    margin: 0,
                    items: [
                        {
                            xtype: 'component',
                            itemId: 'proxmorphPreferenceScope',
                            cls: 'pmx-inventory-account',
                            html:
                                '<span class="pmx-inventory-account-icon fa fa-user-circle-o" aria-hidden="true"></span>' +
                                '<span class="pmx-inventory-account-copy">' +
                                '<strong>' +
                                accountTitle +
                                '</strong>' +
                                '<span>' +
                                accountDescription +
                                '</span>' +
                                '</span>',
                        },
                    ],
                },
            ],
        });

        var win = Ext.create('Ext.window.Window', {
            title: 'Inventory, Appearance & Console',
            iconCls: 'fa fa-sitemap',
            modal: true,
            resizable: false,
            constrain: true,
            width: 640,
            maxHeight: window.innerHeight ? Math.max(360, window.innerHeight - 48) : 720,
            layout: 'fit',
            items: [form],
            dockedItems: [
                {
                    xtype: 'toolbar',
                    dock: 'top',
                    items: [
                        {
                            text: 'Expand all',
                            iconCls: 'fa fa-plus-square-o',
                            handler: function () {
                                resourceTree.expandAll();
                            },
                        },
                        {
                            text: 'Collapse all',
                            iconCls: 'fa fa-minus-square-o',
                            handler: function () {
                                resourceTree.collapseAll();
                                resourceTree.getStore().getRootNode().expand();
                            },
                        },
                    ],
                },
            ],
            buttons: [
                {
                    text: 'Reset',
                    itemId: 'proxmorphInventoryReset',
                    cls: 'pmx-inventory-secondary-action',
                    handler: function () {
                        form.getForm().setValues(copySettings(defaults));
                    },
                },
                {
                    text: 'Apply',
                    handler: function () {
                        var button = this;
                        var values = form.getForm().getValues();
                        if (button.setDisabled) {
                            button.setDisabled(true);
                        }
                        savePreferences(
                            values,
                            win,
                            function () {
                                updateSettings(values);
                                applyTypographySettings(true);
                                syncNavigationMode(viewSelector);
                                refreshInventoryView(viewSelector, resourceTree);
                                win.close();
                            },
                            function (response) {
                                if (button.setDisabled) {
                                    button.setDisabled(false);
                                }
                                Ext.Msg.alert(
                                    'Unable to save ProxMorph settings',
                                    response && response.htmlStatus
                                        ? response.htmlStatus
                                        : 'The ProxMorph preferences service is unavailable.',
                                );
                            },
                        );
                    },
                },
                {
                    text: 'Cancel',
                    itemId: 'proxmorphInventoryCancel',
                    cls: 'pmx-inventory-secondary-action',
                    handler: function () {
                        win.close();
                    },
                },
            ],
        });

        win.show();
    }

    function installView(viewSelector, resourceTree) {
        var store = viewSelector.getStore();
        [
            { key: VIEW_KEY, value: VIEW_NAME },
            { key: STORAGE_VIEW_KEY, value: 'Storage View' },
            { key: CONNECTIVITY_VIEW_KEY, value: 'Connectivity View' },
        ].forEach(function (view) {
            if (!store.findRecord('key', view.key, 0, false, true, true)) {
                store.add(view);
            }
        });

        if (!viewSelector.__proxmorphNativeGetViewFilter) {
            viewSelector.__proxmorphNativeGetViewFilter = viewSelector.getViewFilter;
            viewSelector.getViewFilter = function () {
                var viewKey = this.getValue();
                if (
                    viewKey === VIEW_KEY ||
                    viewKey === STORAGE_VIEW_KEY ||
                    viewKey === CONNECTIVITY_VIEW_KEY
                ) {
                    return buildViewFilter(viewKey);
                }
                return this.__proxmorphNativeGetViewFilter.call(this);
            };
        }

        viewSelector.on('select', function () {
            setInventoryMode(viewSelector, resourceTree);
            restoreExpansionState(resourceTree, viewSelector.getValue());
            labelIconViewRoot(viewSelector, resourceTree);
            updateNavigationSelection(viewSelector);
            if (viewSelector.getValue() === CONNECTIVITY_VIEW_KEY) {
                syncConnectivityVnetNodes(viewSelector, resourceTree);
                loadConnectivityVnets(viewSelector, resourceTree);
            }
        });
        viewSelector.on('beforeselect', function () {
            captureExpansionState(resourceTree, viewSelector.getValue());
        });
    }

    function installNavigationStyles() {
        if (
            typeof Ext === 'undefined' ||
            !Ext.util ||
            !Ext.util.CSS ||
            !Ext.util.CSS.createStyleSheet ||
            (Ext.get && Ext.get('proxmorph-inventory-navigation-style'))
        ) {
            return;
        }
        Ext.util.CSS.createStyleSheet(
            [
                '.pmx-view-nav-button.x-btn.x-btn-default-toolbar-small,',
                '.pmx-view-nav-button.x-btn.x-btn-default-toolbar-small.x-btn-over,',
                '.pmx-view-nav-button.x-btn.x-btn-default-toolbar-small.x-btn-focus,',
                '.pmx-view-nav-button.x-btn.x-btn-default-toolbar-small.x-btn-pressed,',
                '.pmx-view-nav-button.x-btn.x-btn-default-toolbar-small.x-btn-menu-active {',
                '  background-color: transparent !important;',
                '  background-image: none !important;',
                '  border: 1px solid var(--pm-border, var(--gh-border-default, rgba(127, 127, 127, 0.42))) !important;',
                '  box-shadow: none !important;',
                '}',
                '.pmx-view-nav-button.x-btn.x-btn-default-toolbar-small.x-btn-pressed { border-color: var(--pm-border, var(--gh-border-default, rgba(127, 127, 127, 0.42))) !important; }',
                '.x-keyboard-mode .pmx-view-nav-button.x-btn.x-btn-default-toolbar-small.x-btn-focus { outline: 2px solid var(--pm-accent, var(--gh-accent-fg, var(--pwt-text-color, rgba(127, 127, 127, 0.7)))) !important; outline-offset: 1px; }',
                '.pmx-view-nav-button .x-btn-wrap, .pmx-view-nav-button .x-btn-button { align-items: center !important; background-color: transparent !important; background-image: none !important; display: flex !important; height: 100% !important; justify-content: center !important; width: 100% !important; }',
                '.pmx-view-nav-button .x-btn-inner { display: none !important; width: 0 !important; }',
                '.pmx-view-nav-button .x-btn-icon-el { align-items: center !important; display: flex !important; font-size: 16px; height: 16px !important; justify-content: center !important; line-height: 16px !important; margin: 0 !important; position: static !important; transform: none !important; width: 16px !important; }',
                '.pmx-view-nav-button.x-btn.x-btn-default-toolbar-small.x-btn-pressed .x-btn-icon-el { color: var(--pm-accent, var(--gh-accent-fg, var(--pwt-text-color, inherit))) !important; }',
                '.proxmorph-inventory-settings .pmx-inventory-section { border-color: var(--pm-border, var(--gh-border-default, rgba(127, 127, 127, 0.35))) !important; }',
                '.proxmorph-inventory-settings .pmx-inventory-section .x-fieldset-header-text { color: var(--pm-text, var(--gh-fg-default, var(--pwt-text-color, inherit))) !important; }',
                '.proxmorph-inventory-settings .pmx-inventory-option { margin-bottom: 2px; }',
                '.proxmorph-inventory-settings .pmx-inventory-help { margin: 0 0 12px 26px; color: var(--pm-text-dim, var(--gh-fg-muted, var(--pwt-text-color, inherit))); line-height: 1.35; }',
                '.proxmorph-inventory-settings .pmx-inventory-help-last { margin-bottom: 0; }',
                '.proxmorph-inventory-settings .pmx-inventory-summary, .proxmorph-inventory-settings .pmx-inventory-account { background-color: var(--pm-bg-surface, var(--gh-canvas-muted, var(--pwt-panel-background, transparent))) !important; border: 1px solid var(--pm-border, var(--gh-border-default, rgba(127, 127, 127, 0.35))); border-radius: var(--pm-radius-md, 6px) !important; }',
                '.proxmorph-inventory-settings .pmx-inventory-summary { margin-bottom: 12px; padding: 10px 12px; }',
                '.proxmorph-inventory-settings .pmx-inventory-summary-label { display: block; margin-bottom: 3px; color: var(--pm-text-dim, var(--gh-fg-muted, var(--pwt-text-color, inherit))); font-size: 11px; letter-spacing: 0.04em; text-transform: uppercase; }',
                '.proxmorph-inventory-settings .pmx-inventory-summary-value { display: block; color: var(--pm-text, var(--gh-fg-default, var(--pwt-text-color, inherit))); font-weight: 600; line-height: 1.35; }',
                '.proxmorph-inventory-settings .pmx-inventory-resource-help { margin-left: 0; }',
                '.proxmorph-inventory-settings .pmx-typography-section .x-form-item { margin-bottom: 8px; }',
                '.proxmorph-inventory-settings .pmx-typography-help { margin-left: 130px; }',
                '.proxmorph-inventory-settings .pmx-inventory-account { display: flex; align-items: center; gap: 10px; padding: 10px 12px; }',
                '.proxmorph-inventory-settings .pmx-inventory-account-icon { color: var(--pm-accent, var(--gh-accent-fg, var(--pwt-text-color, inherit))); font-size: 18px; }',
                '.proxmorph-inventory-settings .pmx-inventory-account-copy { display: flex; flex-direction: column; gap: 2px; }',
                '.proxmorph-inventory-settings .pmx-inventory-account-copy strong { color: var(--pm-text, var(--gh-fg-default, var(--pwt-text-color, inherit))); font-weight: 600; }',
                '.proxmorph-inventory-settings .pmx-inventory-account-copy span { color: var(--pm-text-dim, var(--gh-fg-muted, var(--pwt-text-color, inherit))); }',
                '.pmx-inventory-secondary-action.x-btn.x-btn-default-small, .pmx-inventory-secondary-action.x-btn.x-btn-default-small.x-btn-over, .pmx-inventory-secondary-action.x-btn.x-btn-default-small.x-btn-focus, .pmx-inventory-secondary-action.x-btn.x-btn-default-small.x-btn-pressed { background-color: transparent !important; background-image: none !important; border-color: var(--pm-border, var(--gh-border-default, rgba(127, 127, 127, 0.42))) !important; box-shadow: none !important; }',
                'html.proxmorph-font-modern { --proxmorph-ui-font: "Roboto Flex", "Segoe UI Variable", "Segoe UI", Roboto, system-ui, -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif; }',
                'html.proxmorph-font-modern body, html.proxmorph-font-modern .x-body, html.proxmorph-font-modern .x-grid-item, html.proxmorph-font-modern .x-grid-cell-inner, html.proxmorph-font-modern .x-tree-node-text, html.proxmorph-font-modern .x-btn-inner, html.proxmorph-font-modern .x-form-item-label, html.proxmorph-font-modern .x-form-text, html.proxmorph-font-modern .x-form-display-field, html.proxmorph-font-modern .x-panel-header-title, html.proxmorph-font-modern .x-window-header-title, html.proxmorph-font-modern .x-tab-inner, html.proxmorph-font-modern .x-menu-item-text, html.proxmorph-font-modern .x-boundlist-item, html.proxmorph-font-modern .x-tip-body, html.proxmorph-font-modern .x-toolbar-text, html.proxmorph-font-modern .x-column-header-text, html.proxmorph-font-modern .x-fieldset-header-text { font-family: var(--proxmorph-ui-font) !important; font-kerning: normal; font-optical-sizing: auto; -webkit-font-smoothing: antialiased; }',
                'html.proxmorph-font-modern .x-treelist-item-text, html.proxmorph-font-modern .x-menu-item-text-default, html.proxmorph-font-modern .x-toolbar-text-default, html.proxmorph-font-modern .x-btn-inner-default-small, html.proxmorph-font-modern .x-btn-inner-default-toolbar-small, html.proxmorph-font-modern .x-panel-header-title-default, html.proxmorph-font-modern .x-window-header-title-default, html.proxmorph-font-modern .x-panel-header-text-default, html.proxmorph-font-modern .x-tab-inner-default, html.proxmorph-font-modern .x-form-item-label-default, html.proxmorph-font-modern .x-form-cb-label-default, html.proxmorph-font-modern .x-form-display-field-default, html.proxmorph-font-modern .x-form-text-default, html.proxmorph-font-modern .x-column-header-text-default, html.proxmorph-font-modern .x-grid-empty, html.proxmorph-font-modern .x-progress-text, html.proxmorph-font-modern .x-tip-body-default, html.proxmorph-font-modern .x-tagfield-item-text, html.proxmorph-font-modern .x-tagfield-input-field, html.proxmorph-font-modern .proxmox-tag-dark, html.proxmorph-font-modern .proxmox-tag-light, html.proxmorph-font-modern .pve-edit-tag { font-family: var(--proxmorph-ui-font) !important; font-kerning: normal; font-optical-sizing: auto; -webkit-font-smoothing: antialiased; }',
                'html.proxmorph-font-modern .x-panel-header-title, html.proxmorph-font-modern .x-window-header-title, html.proxmorph-font-modern .x-fieldset-header-text { font-weight: 500 !important; letter-spacing: -0.01em; }',
                'html.proxmorph-font-modern pre, html.proxmorph-font-modern code, html.proxmorph-font-modern kbd, html.proxmorph-font-modern samp, html.proxmorph-font-modern .xterm, html.proxmorph-font-modern .xterm * { font-family: ui-monospace, "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace !important; font-optical-sizing: none; }',
                'html.proxmorph-text-default { --proxmorph-ui-size: 13px; --proxmorph-ui-line-height: 18px; }',
                'html.proxmorph-text-comfortable { --proxmorph-ui-size: 14px; --proxmorph-ui-line-height: 20px; }',
                'html.proxmorph-text-large { --proxmorph-ui-size: 15px; --proxmorph-ui-line-height: 22px; }',
                'html { --proxmorph-control-height: 30px; --proxmorph-data-row-height: 32px; --proxmorph-control-radius: var(--pm-radius-md, 6px); --proxmorph-control-padding: 10px; --proxmorph-modern-divider: color-mix(in srgb, var(--pm-border, var(--gh-border-default, #68707a)) 72%, transparent); --proxmorph-modern-hover: var(--pm-bg-elevated, var(--gh-canvas-subtle, rgba(127, 127, 127, 0.14))); --proxmorph-modern-selected: color-mix(in srgb, var(--pm-accent, var(--gh-accent-fg, #006eff)) 11%, transparent); }',
                'html.proxmorph-text-comfortable { --proxmorph-control-height: 32px; --proxmorph-data-row-height: 34px; }',
                'html.proxmorph-text-large { --proxmorph-control-height: 34px; --proxmorph-data-row-height: 36px; }',
                'html[class*="proxmorph-text-"] body, html[class*="proxmorph-text-"] .x-body, html[class*="proxmorph-text-"] .x-grid-item, html[class*="proxmorph-text-"] .x-btn-inner, html[class*="proxmorph-text-"] .x-form-item-label, html[class*="proxmorph-text-"] .x-form-text, html[class*="proxmorph-text-"] .x-form-display-field, html[class*="proxmorph-text-"] .x-tab-inner, html[class*="proxmorph-text-"] .x-menu-item-text, html[class*="proxmorph-text-"] .x-boundlist-item, html[class*="proxmorph-text-"] .x-tip-body, html[class*="proxmorph-text-"] .x-toolbar-text, html[class*="proxmorph-text-"] .x-column-header-text, html[class*="proxmorph-text-"] .x-fieldset-header-text { font-size: var(--proxmorph-ui-size) !important; }',
                'html[class*="proxmorph-text-"] .x-treelist-item-text, html[class*="proxmorph-text-"] .x-menu-item-text-default, html[class*="proxmorph-text-"] .x-toolbar-text-default, html[class*="proxmorph-text-"] .x-btn-inner-default-small, html[class*="proxmorph-text-"] .x-btn-inner-default-toolbar-small, html[class*="proxmorph-text-"] .x-panel-header-title-default, html[class*="proxmorph-text-"] .x-window-header-title-default, html[class*="proxmorph-text-"] .x-panel-header-text-default, html[class*="proxmorph-text-"] .x-tab-inner-default, html[class*="proxmorph-text-"] .x-form-item-label-default, html[class*="proxmorph-text-"] .x-form-cb-label-default, html[class*="proxmorph-text-"] .x-form-display-field-default, html[class*="proxmorph-text-"] .x-form-text-default, html[class*="proxmorph-text-"] .x-column-header-text-default, html[class*="proxmorph-text-"] .x-grid-empty, html[class*="proxmorph-text-"] .x-progress-text, html[class*="proxmorph-text-"] .x-tip-body-default, html[class*="proxmorph-text-"] .x-tagfield-item-text, html[class*="proxmorph-text-"] .x-tagfield-input-field, html[class*="proxmorph-text-"] .proxmox-tag-dark, html[class*="proxmorph-text-"] .proxmox-tag-light, html[class*="proxmorph-text-"] .pve-edit-tag { font-size: var(--proxmorph-ui-size) !important; }',
                'html[class*="proxmorph-text-"] .x-grid-cell-inner, html[class*="proxmorph-text-"] .x-tree-node-text, html[class*="proxmorph-text-"] .x-form-display-field, html[class*="proxmorph-text-"] .x-menu-item-text, html[class*="proxmorph-text-"] .x-boundlist-item, html[class*="proxmorph-text-"] .x-tip-body { line-height: var(--proxmorph-ui-line-height) !important; }',
                'html[class*="proxmorph-text-"] .x-treelist-item-text, html[class*="proxmorph-text-"] .x-menu-item-text-default, html[class*="proxmorph-text-"] .x-form-display-field-default, html[class*="proxmorph-text-"] .x-grid-empty, html[class*="proxmorph-text-"] .x-tip-body-default { line-height: var(--proxmorph-ui-line-height) !important; }',
                'html[class*="proxmorph-text-"] .x-panel-header-title, html[class*="proxmorph-text-"] .x-window-header-title { font-size: calc(var(--proxmorph-ui-size) + 1px) !important; }',
                'html body .x-treelist-pve-nav { background-color: var(--pm-bg-base, var(--gh-canvas-default)) !important; }',
                'html body .x-treelist-item-text, html body .x-toolbar-text-default, html body .x-form-item-label-default, html body .x-form-cb-label-default { color: var(--pm-text-dim, var(--gh-fg-muted)) !important; }',
                'html body .x-panel-header-title-default, html body .x-window-header-title-default, html body .x-panel-header-text-default, html body .x-form-display-field-default, html body .x-menu-item-text-default, html body .x-boundlist-item { color: var(--pm-text, var(--gh-fg-default)) !important; }',
                'html body .x-menu-default, html body .x-boundlist, html body .x-tip-default { background-color: var(--pm-bg-surface, var(--gh-canvas-muted)) !important; border-color: var(--pm-border, var(--gh-border-default)) !important; }',
                'html body .x-menu-body-default, html body .x-boundlist-list-ct, html body .x-tip-body-default { background-color: var(--pm-bg-surface, var(--gh-canvas-muted)) !important; color: var(--pm-text, var(--gh-fg-default)) !important; }',
                'html body .x-menu-item-icon-default { color: var(--pm-text-dim, var(--gh-fg-muted)) !important; }',
                'html body .x-grid-empty { background-color: var(--pm-bg-base, var(--gh-canvas-default)) !important; color: var(--pm-text-disabled, var(--gh-fg-subtle, var(--pm-text-dim))) !important; }',
                'html body .x-btn.x-btn-default-small, html body .proxmox-inline-button { box-sizing: border-box !important; height: var(--proxmorph-control-height) !important; min-height: var(--proxmorph-control-height) !important; padding: 0 !important; border-radius: var(--proxmorph-control-radius) !important; }',
                'html body .x-btn-default-small .x-btn-wrap-default-small, html body .proxmox-inline-button .x-btn-wrap { box-sizing: border-box !important; display: flex !important; align-items: center !important; justify-content: center !important; height: 100% !important; padding: 0 var(--proxmorph-control-padding) !important; }',
                'html body .x-btn-default-small .x-btn-button-default-small, html body .proxmox-inline-button .x-btn-button { display: flex !important; align-items: center !important; justify-content: center !important; min-width: 0 !important; }',
                'html body .x-btn-default-small .x-btn-inner-default-small, html body .proxmox-inline-button .x-btn-inner { box-sizing: border-box !important; line-height: calc(var(--proxmorph-control-height) - 2px) !important; overflow: hidden !important; padding: 0 !important; text-overflow: ellipsis; }',
                'html body .x-btn.x-btn-default-toolbar-small:not(.pmx-view-nav-button) { box-sizing: border-box !important; height: var(--proxmorph-control-height) !important; min-height: var(--proxmorph-control-height) !important; padding: 0 !important; background-color: transparent !important; background-image: none !important; border: 1px solid transparent !important; border-radius: var(--proxmorph-control-radius) !important; box-shadow: none !important; }',
                'html body .x-btn-default-toolbar-small:not(.pmx-view-nav-button) .x-btn-wrap-default-toolbar-small { box-sizing: border-box !important; display: flex !important; align-items: center !important; height: 100% !important; padding: 0 var(--proxmorph-control-padding) !important; }',
                'html body .x-btn-default-toolbar-small:not(.pmx-view-nav-button) .x-btn-inner-default-toolbar-small { line-height: calc(var(--proxmorph-control-height) - 2px) !important; padding: 0 !important; }',
                'html body .x-btn-default-toolbar-small:not(.pmx-view-nav-button) .x-btn-wrap-default-toolbar-small.x-btn-arrow-right::after, html body .x-btn-default-toolbar-small:not(.pmx-view-nav-button) .x-btn-wrap-default-toolbar-small.x-btn-split-right::after { box-sizing: border-box !important; align-items: center !important; align-self: center !important; border-left: 1px solid var(--proxmorph-modern-divider) !important; display: flex !important; filter: none !important; height: 18px !important; justify-content: flex-end !important; margin-left: 9px !important; min-height: 18px !important; padding-left: 8px !important; width: 18px !important; }',
                'html body .x-btn-default-toolbar-small:not(.pmx-view-nav-button).x-btn-over, html body .x-btn-default-toolbar-small:not(.pmx-view-nav-button).x-btn-focus { background-color: var(--proxmorph-modern-hover) !important; border-color: transparent !important; box-shadow: none !important; }',
                'html body .x-btn-default-toolbar-small:not(.pmx-view-nav-button).x-btn-pressed, html body .x-btn-default-toolbar-small:not(.pmx-view-nav-button).x-btn-menu-active { background-color: var(--proxmorph-modern-selected) !important; border-color: transparent !important; box-shadow: inset 0 -2px 0 var(--pm-accent, var(--gh-accent-fg, #006eff)) !important; padding: 0 !important; }',
                'html body .x-btn-default-toolbar-small:not(.pmx-view-nav-button).x-btn-pressed .x-btn-inner, html body .x-btn-default-toolbar-small:not(.pmx-view-nav-button).x-btn-menu-active .x-btn-inner, html body .x-btn-default-toolbar-small:not(.pmx-view-nav-button).x-btn-pressed .x-btn-icon-el, html body .x-btn-default-toolbar-small:not(.pmx-view-nav-button).x-btn-menu-active .x-btn-icon-el { color: var(--pm-accent, var(--gh-accent-fg, #006eff)) !important; }',
                'html body .x-btn-default-toolbar-small:not(.pmx-view-nav-button).x-btn-disabled { background-color: transparent !important; border-color: transparent !important; box-shadow: none !important; opacity: 0.46 !important; }',
                'html body .x-box-target:has(#view) > .x-btn.x-btn-default-toolbar-small { background-color: transparent !important; border: 1px solid var(--pm-border, var(--gh-border-default, rgba(127, 127, 127, 0.42))) !important; box-shadow: none !important; height: 28px !important; min-height: 28px !important; padding: 0 !important; }',
                'html body .x-box-target:has(#view) > .x-btn.x-btn-default-toolbar-small .x-btn-wrap-default-toolbar-small { padding: 0 8px !important; }',
                'html body .x-box-target:has(#view) > .x-btn.x-btn-default-toolbar-small.x-btn-over { background-color: var(--proxmorph-modern-hover) !important; }',
                'html body .x-toolbar-default.x-docked-top { background-color: var(--pm-bg-base, var(--gh-canvas-default)) !important; border-bottom: 1px solid var(--proxmorph-modern-divider) !important; }',
                'html body .x-grid-with-col-lines .x-grid-cell { border-right: 1px solid var(--proxmorph-modern-divider) !important; }',
                'html body .x-grid-with-col-lines .x-grid-cell:last-child { border-right: 0 !important; }',
                'html body .x-grid-item:has(td[class*="itype-icon"], td.pve-itype-fa) .x-grid-cell-inner { box-sizing: border-box !important; display: flex !important; align-items: center !important; min-height: var(--proxmorph-data-row-height) !important; padding-top: 5px !important; padding-bottom: 5px !important; }',
                'html body td[class*="itype-icon"] > .x-grid-cell-inner::before { align-self: center !important; flex: 0 0 14px !important; margin-top: 0 !important; vertical-align: initial !important; }',
                'html body td.pve-itype-fa .pve-grid-fa { align-items: center !important; align-self: center !important; display: inline-flex !important; flex: 0 0 16px !important; justify-content: center !important; line-height: 1 !important; }',
                'html body .x-grid:not(.x-tree-panel) .x-grid-item-selected { background-color: var(--proxmorph-modern-selected) !important; box-shadow: none !important; }',
                'html body .x-grid:not(.x-tree-panel) .x-grid-item-selected td.x-grid-cell:first-child { box-shadow: inset 3px 0 0 var(--pm-accent, var(--gh-accent-fg, #006eff)) !important; }',
                'html body .x-tab-default-top { background-color: transparent !important; background-image: none !important; border-color: transparent !important; border-radius: var(--proxmorph-control-radius) var(--proxmorph-control-radius) 0 0 !important; box-shadow: none !important; }',
                'html body .x-tab-default-top.x-tab-over { background-color: var(--proxmorph-modern-hover) !important; border-color: transparent !important; }',
                'html body .x-tab-default-top.x-tab-active { background-color: transparent !important; border-color: transparent !important; box-shadow: inset 0 -2px 0 var(--pm-accent, var(--gh-accent-fg, #006eff)) !important; }',
                'html body .x-menu-default, html body .x-boundlist { border: 1px solid var(--proxmorph-modern-divider) !important; border-radius: var(--pm-radius-lg, 8px) !important; box-shadow: 0 12px 30px rgba(0, 0, 0, 0.32) !important; padding: 4px !important; }',
                'html body .x-menu-item, html body .x-boundlist-item { border-radius: var(--pm-radius-md, 6px) !important; }',
                'html body .x-form-trigger-wrap-default { background-color: var(--pm-bg-surface, var(--gh-canvas-muted)) !important; border: 1px solid var(--proxmorph-modern-divider) !important; border-radius: var(--proxmorph-control-radius) !important; box-shadow: none !important; height: var(--proxmorph-control-height) !important; min-height: var(--proxmorph-control-height) !important; }',
                'html body .x-form-trigger-wrap-default .x-form-text-default { box-sizing: border-box !important; height: calc(var(--proxmorph-control-height) - 2px) !important; line-height: calc(var(--proxmorph-control-height) - 2px) !important; padding-top: 0 !important; padding-bottom: 0 !important; }',
                'html body .x-form-trigger-wrap-default .x-form-trigger-default { height: calc(var(--proxmorph-control-height) - 2px) !important; }',
                'html body .x-form-trigger-wrap-default.x-form-trigger-wrap-focus { border-color: var(--pm-accent, var(--gh-accent-fg, #006eff)) !important; box-shadow: 0 0 0 3px color-mix(in srgb, var(--pm-accent, var(--gh-accent-fg, #006eff)) 18%, transparent) !important; }',
            ].join('\n'),
            'proxmorph-inventory-navigation-style',
        );
    }

    function navigationTooltip(label, hierarchy) {
        var cluster =
            typeof PVE !== 'undefined' && PVE.ClusterName
                ? PVE.ClusterName
                : window.location && window.location.hostname
                  ? window.location.hostname
                  : 'Datacenter';
        return label + ' — ' + cluster + (hierarchy ? ' → ' + hierarchy : '');
    }

    function setButtonTooltip(button, tooltip) {
        if (!button) {
            return;
        }
        if (button.setTooltip) {
            button.setTooltip(tooltip);
        } else {
            button.tooltip = tooltip;
        }
    }

    function updateNavigationTooltips(viewSelector) {
        var navigation = getNavigation(viewSelector);
        var inventoryHierarchy = getHierarchyLabel().replace(/^Datacenter → /, '');
        setButtonTooltip(
            getNavigationButton(navigation, 'server'),
            navigationTooltip('Datacenter', 'nodes and resources'),
        );
        setButtonTooltip(
            getNavigationButton(navigation, VIEW_KEY),
            navigationTooltip('Inventory', inventoryHierarchy),
        );
        setButtonTooltip(
            getNavigationButton(navigation, STORAGE_VIEW_KEY),
            navigationTooltip('Storage', 'nodes → storage'),
        );
        setButtonTooltip(
            getNavigationButton(navigation, CONNECTIVITY_VIEW_KEY),
            navigationTooltip('Connectivity', 'zones, fabrics, VNets, and node networks'),
        );
    }

    function installNavigation(viewSelector, resourceTree) {
        var toolbar = viewSelector.ownerCt;
        if (!toolbar || toolbar.down('#proxmorphViewNavigation')) {
            return;
        }
        installNavigationStyles();

        var items = [
            {
                viewKey: 'server',
                label: 'Datacenter',
                iconCls: 'fa fa-server',
                hierarchy: 'nodes and resources',
            },
            {
                viewKey: VIEW_KEY,
                label: 'Inventory',
                iconCls: 'fa fa-sitemap',
                hierarchy: 'nodes → pools → guests',
            },
            {
                viewKey: STORAGE_VIEW_KEY,
                label: 'Storage',
                iconCls: 'fa fa-database',
                hierarchy: 'nodes → storage',
            },
            {
                viewKey: CONNECTIVITY_VIEW_KEY,
                label: 'Connectivity',
                iconCls: 'fa fa-globe',
                hierarchy: 'zones, fabrics, VNets, and node networks',
            },
        ].map(function (item, index, allItems) {
            return {
                xtype: 'button',
                itemId: 'proxmorphView-' + item.viewKey,
                cls: 'x-btn-default-toolbar-small pmx-view-nav-button',
                iconCls: item.iconCls + ' x-btn-icon-el-default-toolbar-small',
                tooltip: navigationTooltip(item.label, item.hierarchy),
                ariaLabel: item.label + ' view',
                width: 34,
                height: 28,
                margin: index < allItems.length - 1 ? '0 4 0 0' : '0',
                enableToggle: true,
                toggleGroup: 'proxmorphInventoryViews',
                allowDepress: false,
                pressed: viewSelector.getValue() === item.viewKey,
                handler: function () {
                    selectView(viewSelector, resourceTree, item.viewKey);
                },
            };
        });

        toolbar.add({
            xtype: 'container',
            itemId: 'proxmorphViewNavigation',
            cls: 'pmx-view-nav',
            hidden: !settings.useIconNavigation,
            layout: {
                type: 'hbox',
                align: 'stretch',
            },
            items: items,
        });
        syncNavigationMode(viewSelector);
    }

    function installSettingsButton(viewSelector, resourceTree) {
        var toolbar = viewSelector.ownerCt;
        if (!toolbar || toolbar.down('#proxmorphInventorySettings')) {
            return;
        }

        toolbar.add({
            xtype: 'button',
            itemId: 'proxmorphInventorySettings',
            cls: 'x-btn-default-toolbar-small',
            iconCls: 'fa fa-fw fa-sitemap x-btn-icon-el-default-toolbar-small',
            tooltip: 'Inventory, appearance, and console settings',
            ariaLabel: 'Inventory, appearance, and console settings',
            margin: '0 0 0 3',
            handler: function () {
                createSettingsWindow(viewSelector, resourceTree);
            },
        });
    }

    function restoreCustomViewState(viewSelector) {
        if (
            !viewSelector.applyState ||
            !Ext.state ||
            !Ext.state.Manager ||
            !Ext.state.Manager.getProvider
        ) {
            return;
        }
        var provider = Ext.state.Manager.getProvider();
        var state = provider && provider.get ? provider.get('view') : null;
        var viewKey = state && state.value;
        if (
            viewKey === VIEW_KEY ||
            viewKey === STORAGE_VIEW_KEY ||
            viewKey === CONNECTIVITY_VIEW_KEY
        ) {
            viewSelector.applyState(state, true);
        }
    }

    function initialize() {
        if (initialized) {
            return;
        }

        initAttempts++;
        var hasExtensionPoints =
            typeof PVE !== 'undefined' &&
            Ext.ClassManager.get('PVE.form.ViewSelector') &&
            Ext.ClassManager.get('PVE.tree.ResourceTree');
        var viewSelector = hasExtensionPoints ? Ext.getCmp('view') : null;
        var resourceTree = hasExtensionPoints ? getResourceTree() : null;

        if (!viewSelector || !resourceTree) {
            if (initAttempts < MAX_INIT_ATTEMPTS) {
                Ext.defer(initialize, 250);
            } else if (window.console && console.warn) {
                console.warn('[ProxMorph Inventory] Compatible PVE resource tree was not found; patch disabled.');
            }
            return;
        }

        vnetRoutingAvailable = installVnetRouting(resourceTree);
        installView(viewSelector, resourceTree);
        installConnectivityRefresh(viewSelector, resourceTree);
        installTreeContextActions(viewSelector, resourceTree);
        initialized = true;
        loadPreferences(function () {
            installNavigation(viewSelector, resourceTree);
            installSettingsButton(viewSelector, resourceTree);
            applyTypographySettings(true);
            restoreCustomViewState(viewSelector);
            syncNavigationMode(viewSelector);
            window.ProxMorphInventory.compatible = true;
            console.log('[ProxMorph] Inventory View initialized (v' + VERSION + ')');
        });
    }

    window.ProxMorphInventory = {
        version: VERSION,
        compatible: false,
        buildViewFilter: buildViewFilter,
        normalizeConnectivityVnets: normalizeConnectivityVnets,
        buildConnectivityVnetNode: buildConnectivityVnetNode,
        getHierarchyLabel: getHierarchyLabel,
        getSettings: function () {
            return copySettings(settings);
        },
        setSettings: function (values) {
            var updated = updateSettings(values);
            applyTypographySettings(true);
            return updated;
        },
        resetSettings: function () {
            settings = copySettings(defaults);
            applyTypographySettings(true);
            return copySettings(settings);
        },
        getTypographyClassNames: function () {
            return typographyClassNames(settings);
        },
        preferencesAvailable: function () {
            return preferencesAvailable;
        },
        captureExpansionState: captureExpansionState,
        restoreExpansionState: restoreExpansionState,
    };

    // Exposing the pure filter builder before this guard keeps it testable
    // without constructing an ExtJS application.
    if (typeof Ext === 'undefined' || !Ext.onReady || typeof PVE === 'undefined') {
        return;
    }

    Ext.onReady(function () {
        Ext.defer(initialize, 50);
    });
})();
