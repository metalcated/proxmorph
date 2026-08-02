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
 * Version: 1.4.0
 */
(function () {
    'use strict';

    var VIEW_KEY = 'proxmorph-inventory';
    var VIEW_NAME = 'Inventory View';
    var STORAGE_VIEW_KEY = 'proxmorph-storage';
    var CONNECTIVITY_VIEW_KEY = 'proxmorph-connectivity';
    var VERSION = '1.4.0';
    var PREFERENCES_URL = '/proxmorph/preferences';
    var MAX_INIT_ATTEMPTS = 40;
    var initAttempts = 0;
    var initialized = false;
    var preferencesAvailable = false;
    var expansionStateByView = {};

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
    };

    var settings = copySettings(defaults);

    function copySettings(source) {
        var copy = {};
        Object.keys(defaults).forEach(function (key) {
            copy[key] = source[key];
        });
        return copy;
    }

    function updateSettings(values) {
        Object.keys(defaults).forEach(function (key) {
            if (Object.prototype.hasOwnProperty.call(values || {}, key)) {
                settings[key] =
                    values[key] === true ||
                    values[key] === 1 ||
                    values[key] === '1' ||
                    values[key] === 'true' ||
                    values[key] === 'on';
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
        Object.keys(defaults).forEach(function (key) {
            if (Object.prototype.hasOwnProperty.call(values || {}, key)) {
                normalized[key] =
                    values[key] === true ||
                    values[key] === 1 ||
                    values[key] === '1' ||
                    values[key] === 'true' ||
                    values[key] === 'on';
            }
            serialized[key] = normalized[key] ? 1 : 0;
        });
        return serialized;
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

    function buildConnectivityViewFilter() {
        return {
            id: CONNECTIVITY_VIEW_KEY,
            groups: ['node'],
            getFilterFn: function () {
                return function (item) {
                    var type = item && item.data ? item.data.type : undefined;
                    return type === 'node' || type === 'sdn' || type === 'network';
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
                                    name: 'showStoppedGuests',
                                    boxLabel: 'Stopped guests',
                                    checked: settings.showStoppedGuests,
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
            title: 'Inventory View',
            iconCls: 'fa fa-sitemap',
            modal: true,
            resizable: false,
            constrain: true,
            width: 600,
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
                                syncNavigationMode(viewSelector);
                                refreshInventoryView(viewSelector, resourceTree);
                                win.close();
                            },
                            function (response) {
                                if (button.setDisabled) {
                                    button.setDisabled(false);
                                }
                                Ext.Msg.alert(
                                    'Unable to save Inventory View settings',
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
                '.pmx-view-nav { border-bottom: 1px solid rgba(127, 127, 127, 0.35); padding-bottom: 4px; }',
                '.pmx-view-nav-button.x-btn.x-btn-default-toolbar-small,',
                '.pmx-view-nav-button.x-btn.x-btn-default-toolbar-small.x-btn-over,',
                '.pmx-view-nav-button.x-btn.x-btn-default-toolbar-small.x-btn-focus,',
                '.pmx-view-nav-button.x-btn.x-btn-default-toolbar-small.x-btn-pressed,',
                '.pmx-view-nav-button.x-btn.x-btn-default-toolbar-small.x-btn-menu-active {',
                '  background-color: transparent !important;',
                '  background-image: none !important;',
                '  border: 1px solid var(--pm-border, var(--gh-border-default, rgba(127, 127, 127, 0.42))) !important;',
                '  border-radius: 7px !important;',
                '  box-shadow: none !important;',
                '  padding: 0 !important;',
                '}',
                '.pmx-view-nav-button.x-btn.x-btn-default-toolbar-small.x-btn-over { border-color: var(--pm-border-strong, var(--gh-border-muted, rgba(160, 160, 160, 0.72))) !important; }',
                '.pmx-view-nav-button.x-btn.x-btn-default-toolbar-small.x-btn-pressed { border-color: var(--pm-accent, var(--gh-accent-fg, var(--pwt-text-color, rgba(190, 190, 190, 0.9)))) !important; }',
                '.x-keyboard-mode .pmx-view-nav-button.x-btn.x-btn-default-toolbar-small.x-btn-focus { outline: 2px solid var(--pm-accent, var(--gh-accent-fg, var(--pwt-text-color, rgba(127, 127, 127, 0.7)))) !important; outline-offset: 1px; }',
                '.pmx-view-nav-button .x-btn-wrap, .pmx-view-nav-button .x-btn-button { background-color: transparent !important; background-image: none !important; }',
                '.pmx-view-nav-button .x-btn-inner { display: none; }',
                '.pmx-view-nav-button .x-btn-icon-el { font-size: 18px; opacity: 0.72; }',
                '.pmx-view-nav-button.x-btn.x-btn-default-toolbar-small.x-btn-pressed .x-btn-icon-el { color: var(--pm-accent, var(--gh-accent-fg, var(--pwt-text-color, inherit))) !important; opacity: 1; }',
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
                '.proxmorph-inventory-settings .pmx-inventory-account { display: flex; align-items: center; gap: 10px; padding: 10px 12px; }',
                '.proxmorph-inventory-settings .pmx-inventory-account-icon { color: var(--pm-accent, var(--gh-accent-fg, var(--pwt-text-color, inherit))); font-size: 18px; }',
                '.proxmorph-inventory-settings .pmx-inventory-account-copy { display: flex; flex-direction: column; gap: 2px; }',
                '.proxmorph-inventory-settings .pmx-inventory-account-copy strong { color: var(--pm-text, var(--gh-fg-default, var(--pwt-text-color, inherit))); font-weight: 600; }',
                '.proxmorph-inventory-settings .pmx-inventory-account-copy span { color: var(--pm-text-dim, var(--gh-fg-muted, var(--pwt-text-color, inherit))); }',
                '.pmx-inventory-secondary-action.x-btn.x-btn-default-small, .pmx-inventory-secondary-action.x-btn.x-btn-default-small.x-btn-over, .pmx-inventory-secondary-action.x-btn.x-btn-default-small.x-btn-focus, .pmx-inventory-secondary-action.x-btn.x-btn-default-small.x-btn-pressed { background-color: transparent !important; background-image: none !important; border-color: var(--pm-border, var(--gh-border-default, rgba(127, 127, 127, 0.42))) !important; box-shadow: none !important; }',
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
            navigationTooltip('Connectivity', 'SDN and node networks'),
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
                hierarchy: 'SDN and node networks',
            },
        ].map(function (item, index, allItems) {
            return {
                xtype: 'button',
                itemId: 'proxmorphView-' + item.viewKey,
                cls: 'pmx-view-nav-button',
                iconCls: item.iconCls,
                tooltip: navigationTooltip(item.label, item.hierarchy),
                ariaLabel: item.label + ' view',
                width: 42,
                height: 34,
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
            tooltip: 'Inventory visibility settings',
            ariaLabel: 'Inventory visibility settings',
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

        installView(viewSelector, resourceTree);
        initialized = true;
        loadPreferences(function () {
            installNavigation(viewSelector, resourceTree);
            installSettingsButton(viewSelector, resourceTree);
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
        getHierarchyLabel: getHierarchyLabel,
        getSettings: function () {
            return copySettings(settings);
        },
        setSettings: updateSettings,
        resetSettings: function () {
            settings = copySettings(defaults);
            return copySettings(settings);
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
