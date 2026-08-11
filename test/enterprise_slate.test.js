'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const pvePath = path.join(root, 'themes', 'theme-enterprise-slate.css');
const pdmPath = path.join(root, 'themes', 'pdm', 'theme-enterprise-slate.css');

assert.ok(fs.existsSync(pvePath), 'the PVE/PBS Enterprise Slate theme is present');
assert.ok(fs.existsSync(pdmPath), 'the PDM Enterprise Slate theme is present');

const pve = fs.readFileSync(pvePath, 'utf8');
const pdm = fs.readFileSync(pdmPath, 'utf8');

assert.match(pve, /^\/\*!Enterprise Slate\*\//, 'PVE exposes the public theme title');
assert.match(pdm, /^\/\*!Enterprise Slate\*\//, 'PDM exposes the public theme title');

[
    ['--pm-shell:', '#31485a'],
    ['--pm-bg-base:', '#1b2a32'],
    ['--pm-bg-surface:', '#22343c'],
    ['--pm-border:', '#485764'],
    ['--pm-text:', '#e9ecef'],
    ['--pm-accent:', '#0f789c'],
].forEach(([token, value]) => {
    assert.ok(pve.includes(`${token} ${value}`), `PVE defines ${token} as ${value}`);
    assert.ok(pdm.includes(`${token} ${value}`), `PDM defines ${token} as ${value}`);
});

assert.match(
    pve,
    /body > \.x-plain\[role="region"\]:has\(#versioninfo\)[^{]*\{[^}]*background: var\(--pm-shell\) !important;/s,
    'the PVE command shell uses the confirmed native Header and version hooks',
);
assert.match(
    pve,
    /\[id\^="pveGlobalSearchField-"\] \.x-form-trigger-wrap-default[^{]*\{[^}]*rgba\(16, 31, 39, 0\.52\)/s,
    'the native global search field belongs to the command shell',
);
assert.match(
    pve,
    /\.x-btn-default-toolbar-small:not\(\.pmx-view-nav-button\)[^{]*\{[^}]*background: transparent !important;[^}]*border-color: transparent !important;/s,
    'action bars use quiet ghost controls instead of boxy permanent fills',
);
assert.match(
    pve,
    /\.x-grid-item-selected \.x-grid-cell:first-child[^{]*\{[^}]*box-shadow: none !important;/s,
    'selected data rows use a quiet surface without an accent border',
);
assert.match(
    pve,
    /\.x-treelist-item-selected > \.x-treelist-row::before[^{]*\{[^}]*background: var\(--pm-row-selected\) !important;[^}]*box-shadow: none !important;/s,
    'object navigation uses a quiet full-row selection without a cyan leading edge',
);
assert.match(
    pve,
    /\[id\^="proxmoxHelpButton-"\][^{]*\{[^}]*border-color: var\(--pm-action-outline\) !important;/s,
    'Documentation keeps a restrained dark action outline while stationary',
);
assert.match(
    pve,
    /\.x-tab-default\.x-tab\.x-tab-active::after[^{]*\{[^}]*content: none !important;[^}]*display: none !important;/s,
    'selected tabs do not draw an accent edge',
);
assert.match(
    pve,
    /\.x-keyboard-mode \.x-grid-item-focused[^{]*\{[^}]*outline: none !important;/s,
    'focused grid rows do not gain a cyan perimeter',
);
assert.match(
    pve,
    /--pm-font-ui: "Clarity City", Metropolis, "Avenir Next"/,
    'the interface typography uses the deliberate Clarity-style font stack',
);
assert.match(
    pve,
    /--pm-font-data: "SFMono-Regular", "Cascadia Mono"/,
    'telemetry and identifiers have a dedicated utility font stack',
);
assert.match(
    pve,
    /@media \(prefers-reduced-motion: reduce\)/,
    'PVE respects the operating-system reduced-motion preference',
);

assert.match(
    pdm,
    /--pwt-color-primary-60: rgb\(15, 120, 156\) !important;/,
    'PDM maps its primary tonal system to the restrained Enterprise Slate action color',
);
assert.match(
    pdm,
    /--pwt-color-neutral-10: rgb\(27, 42, 50\) !important;/,
    'PDM maps its dark workspace to the same Enterprise Slate base',
);
assert.match(
    pdm,
    /--pwt-card-corner-shape: 4px !important;/,
    'PDM replaces the shared rounded-card treatment with disciplined corners',
);
assert.match(
    pdm,
    /\.pwt-nav-link\[aria-current="page"\][^{]*\{[^}]*var\(--pm-row-selected\)[^}]*box-shadow: none !important;/s,
    'PDM navigation uses the same borderless selected-row language as PVE',
);
assert.match(
    pdm,
    /\.pwt-tab-active-indicator[^{]*\{[^}]*background: transparent !important;[^}]*height: 0 !important;/s,
    'PDM selected tabs omit the cyan indicator edge',
);
assert.match(
    pdm,
    /@media \(prefers-reduced-motion: reduce\)/,
    'PDM respects the operating-system reduced-motion preference',
);

assert.doesNotMatch(
    `${pve}\n${pdm}`,
    /https?:\/\/(?!www\.w3\.org\/2000\/svg)/,
    'the theme loads no third-party runtime assets',
);

console.log('PASS: Enterprise Slate PVE/PBS and PDM design contracts');
