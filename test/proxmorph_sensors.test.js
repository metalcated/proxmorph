'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.join(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'themes', 'patches', 'proxmorph-sensors.js'), 'utf8');

function StatusView() {
    this.items = [{ itemId: 'cpus' }];
    this.listeners = {};
}

StatusView.prototype.initComponent = function () {};
StatusView.prototype.on = function (event, handler) {
    this.listeners[event] = handler;
};

const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    document: { readyState: 'interactive' },
    gettext: (value) => value,
    getComputedStyle: () => ({ getPropertyValue: () => '' }),
    setTimeout() {},
    window: {},
};

sandbox.Ext = {
    Array: {
        insert(target, index, values) {
            target.splice(index, 0, ...values);
        },
    },
    ClassManager: {
        get(name) {
            return name === 'PVE.node.StatusView' ? StatusView : null;
        },
    },
    ComponentQuery: { query: () => [] },
    isArray: Array.isArray,
    util: {
        Format: {
            number(value, pattern) {
                const precision = pattern === '0.##' ? 2 : 1;
                return Number(value).toFixed(precision).replace(/\.?0+$/, '');
            },
        },
    },
};

vm.runInNewContext(source, sandbox, { filename: 'proxmorph-sensors.js' });

const statusView = new StatusView();
statusView.initComponent();
const sensorItem = statusView.items.find((item) => item.itemId === 'sensors');
assert.ok(sensorItem, 'sensor widget is injected into the node StatusView');

const readings = JSON.stringify({
    'coretemp-isa-0000': {
        'Package id 0': { temp1_input: 47, temp1_max: 86, temp1_crit: 96 },
        'Core 0': { temp2_input: 45, temp2_max: 86, temp2_crit: 96 },
    },
    'coretemp-isa-0001': {
        'Package id 1': { temp1_input: 48, temp1_max: 86, temp1_crit: 96 },
        'Core 0': { temp2_input: 46, temp2_max: 86, temp2_crit: 96 },
    },
    'nvme-pci-0300': {
        Composite: { temp1_input: 35.9, temp1_max: 70, temp1_crit: 80 },
        'Sensor 1': { temp2_input: 40 },
    },
    'pch_lewisburg-virtual-0': {
        temp1: { temp1_input: 43 },
    },
    'bnxt_en-pci-1900': {
        temp1: { temp1_input: 57, temp1_max: 95, temp1_crit: 100 },
    },
    'power_meter-acpi-0': {
        power1: { power1_input: 155, power1_average: 160, power1_average_interval: 2 },
    },
});

function textContent(html) {
    return html.replace(/<[^>]+>/g, '');
}

const rendered = textContent(sensorItem.renderer(readings));
assert.match(rendered, /CPU 1: 47°C \(1 core\)/, 'first CPU socket is labeled');
assert.match(rendered, /CPU 2: 48°C \(1 core\)/, 'second CPU socket is labeled');
assert.match(rendered, /NVMe: 35\.9°C/, 'NVMe composite temperature is retained');
assert.match(rendered, /NVMe 0300 Sensor 1: 40°C/, 'additional NVMe temperature is displayed');
assert.match(rendered, /PCH: 43°C/, 'chipset temperature is displayed');
assert.match(rendered, /NIC 1900: 57°C/, 'network-adapter temperature is displayed');
assert.match(rendered, /Power: 160 W/, 'power average is preferred over instantaneous input');
assert.equal((rendered.match(/NVMe: 35\.9°C/g) || []).length, 1, 'NVMe composite is not duplicated');

const filteredRecord = {
    store: {
        findRecord(key, value) {
            if (key === 'key' && value === 'sensorsFilter') {
                return {
                    get() {
                        return 'bnxt_en-pci-1900:temp1\npower_meter-acpi-0:power1';
                    },
                };
            }
            return null;
        },
    },
};
const filtered = textContent(sensorItem.renderer(readings, filteredRecord));
assert.match(filtered, /NIC 1900: 57°C/, 'generic temperature honors the saved filter');
assert.match(filtered, /Power: 160 W/, 'power reading honors the saved filter');
assert.doesNotMatch(filtered, /CPU|NVMe|PCH/, 'unselected readings remain hidden');
assert.equal(sandbox.window.ProxMorphSensors.version, '1.3.0', 'sensor patch exposes the current version');

console.log('PASS: expanded sensor rendering and filtering');
