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
 * Preferences are intentionally held in memory for the current page. This
 * patch does not add browser-local persistence.
 *
 * Version: 1.0.0
 */
(function () {
    'use strict';

    var VIEW_KEY = 'proxmorph-inventory';
    var VIEW_NAME = 'Inventory View';
    var VERSION = '1.0.0';
    var MAX_INIT_ATTEMPTS = 40;
    var initAttempts = 0;
    var initialized = false;

    var defaults = {
        showPools: true,
        showVirtualMachines: true,
        showContainers: true,
        showTemplates: true,
        showStorage: true,
        showNetwork: true,
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

    function resourceIsVisible(item) {
        var data = item && item.data ? item.data : {};
        var type = data.type;

        // Nodes provide the navigable top level of this view and stay visible.
        if (type === 'node') {
            return true;
        }

        // Resource-pool records would duplicate the pool groups synthesized
        // from each guest's native `pool` field.
        if (type === 'pool') {
            return false;
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

    function buildViewFilter() {
        return {
            id: VIEW_KEY,
            // ResourceTree already understands both attributes. Using them in
            // sequence yields Datacenter -> Node -> nested Pool -> Guest.
            groups: settings.showPools ? ['node', 'pool'] : ['node'],
            getFilterFn: function () {
                return resourceIsVisible;
            },
        };
    }

    function getResourceTree() {
        var trees = Ext.ComponentQuery.query('pveResourceTree');
        return trees && trees.length ? trees[0] : null;
    }

    function setInventoryMode(viewSelector, resourceTree) {
        var isInventory = viewSelector.getValue() === VIEW_KEY;
        if (resourceTree && resourceTree.toggleCls) {
            resourceTree.toggleCls('proxmorph-inventory-tree', isInventory);
        }
    }

    function selectInventoryView(viewSelector, resourceTree) {
        var record = viewSelector.getStore().findRecord('key', VIEW_KEY, 0, false, true, true);
        if (!record) {
            return;
        }
        viewSelector.setValue(VIEW_KEY);
        viewSelector.fireEvent('select', viewSelector, [record]);
        setInventoryMode(viewSelector, resourceTree);
    }

    function refreshInventoryView(viewSelector, resourceTree) {
        if (viewSelector.getValue() === VIEW_KEY) {
            resourceTree.setViewFilter(buildViewFilter());
        } else {
            selectInventoryView(viewSelector, resourceTree);
        }
    }

    function createSettingsWindow(viewSelector, resourceTree) {
        var form = Ext.create('Ext.form.Panel', {
            border: false,
            bodyPadding: 14,
            defaultType: 'checkboxfield',
            defaults: {
                labelWidth: 230,
                inputValue: true,
                uncheckedValue: false,
            },
            items: [
                {
                    xtype: 'displayfield',
                    fieldLabel: 'Hierarchy',
                    value: 'Datacenter → node → resource pool → guest',
                    userCls: 'pmx-hint',
                },
                {
                    name: 'showPools',
                    fieldLabel: 'Group guests by resource pool',
                    checked: settings.showPools,
                },
                {
                    name: 'showVirtualMachines',
                    fieldLabel: 'Show virtual machines',
                    checked: settings.showVirtualMachines,
                },
                {
                    name: 'showContainers',
                    fieldLabel: 'Show containers',
                    checked: settings.showContainers,
                },
                {
                    name: 'showTemplates',
                    fieldLabel: 'Show templates',
                    checked: settings.showTemplates,
                },
                {
                    name: 'showStorage',
                    fieldLabel: 'Show storage',
                    checked: settings.showStorage,
                },
                {
                    name: 'showNetwork',
                    fieldLabel: 'Show SDN and network resources',
                    checked: settings.showNetwork,
                },
                {
                    name: 'showStoppedGuests',
                    fieldLabel: 'Show stopped guests',
                    checked: settings.showStoppedGuests,
                },
                {
                    xtype: 'displayfield',
                    fieldLabel: 'Preference scope',
                    value: 'Current page only',
                    userCls: 'pmx-hint',
                },
            ],
        });

        var win = Ext.create('Ext.window.Window', {
            title: 'Inventory View',
            iconCls: 'fa fa-sitemap',
            modal: true,
            resizable: false,
            width: 520,
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
                    handler: function () {
                        settings = copySettings(defaults);
                        form.getForm().setValues(settings);
                    },
                },
                {
                    text: 'Apply',
                    handler: function () {
                        updateSettings(form.getForm().getValues());
                        refreshInventoryView(viewSelector, resourceTree);
                        win.close();
                    },
                },
                {
                    text: 'Cancel',
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
        if (!store.findRecord('key', VIEW_KEY, 0, false, true, true)) {
            store.add({ key: VIEW_KEY, value: VIEW_NAME });
        }

        if (!viewSelector.__proxmorphNativeGetViewFilter) {
            viewSelector.__proxmorphNativeGetViewFilter = viewSelector.getViewFilter;
            viewSelector.getViewFilter = function () {
                if (this.getValue() === VIEW_KEY) {
                    return buildViewFilter();
                }
                return this.__proxmorphNativeGetViewFilter.call(this);
            };
        }

        viewSelector.on('select', function () {
            setInventoryMode(viewSelector, resourceTree);
        });
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
        installSettingsButton(viewSelector, resourceTree);
        initialized = true;
        window.ProxMorphInventory.compatible = true;
        console.log('[ProxMorph] Inventory View initialized (v' + VERSION + ')');
    }

    window.ProxMorphInventory = {
        version: VERSION,
        compatible: false,
        buildViewFilter: buildViewFilter,
        getSettings: function () {
            return copySettings(settings);
        },
        setSettings: updateSettings,
        resetSettings: function () {
            settings = copySettings(defaults);
            return copySettings(settings);
        },
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
