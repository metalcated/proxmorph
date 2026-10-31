'use strict';

// Browser regression using the installed Proxmox base CSS, supplied externally:
// PROXMORPH_NATIVE_CSS_DIR=/path/to/css node test/esxi_light_colors.browser.cjs
// The directory contains crisp.css, pve.css and pmx.css from the host under test.
// Uses an existing playwright-core/browser installation; no npm install needed.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright-core');

const root = path.join(__dirname, '..');
const nativeDir = process.env.PROXMORPH_NATIVE_CSS_DIR;
assert.ok(nativeDir, 'provide the installed Proxmox styles through PROXMORPH_NATIVE_CSS_DIR');
const nativeCSS = ['crisp.css', 'pve.css', 'pmx.css']
    .map(file => fs.readFileSync(path.join(nativeDir, file), 'utf8')).join('\n');
const themeCSS = fs.readFileSync(path.join(root, 'themes/theme-esxi-light.css'), 'utf8');
// Reuse the integration harness to capture the real injected stylesheet, so a
// change in either stylesheet is checked through the browser's actual cascade.
const integration = fs.readFileSync(path.join(__dirname, 'proxmorph_inventory_integration.test.js'), 'utf8');
const sharedCSS = new Function('require', '__dirname', `${integration}\nreturn navigationStyle.css;`)(require, __dirname);
const states = ['', 'x-btn-over', 'x-btn-focus', 'x-btn-pressed', 'x-btn-menu-active', 'x-btn-disabled'];
// ExtJS normally supplies these positions. Arrange the state matrix without
// running layout code, while leaving the production color declarations intact.
const fixtureCSS = `
    body { margin: 24px; height: auto !important; width: auto !important; }
    header, main { padding: 18px; position: relative !important; height: auto !important; }
    header { display: flex !important; flex-wrap: wrap !important; gap: 8px; }
    #versioninfo { width: 100%; }
    .x-btn { margin: 4px; position: relative !important; display: inline-flex !important; flex: 0 0 150px !important; }
    .x-toolbar, .x-segmented-button { display: flex !important; flex-wrap: wrap !important; position: relative !important; margin-top: 16px; }
    .x-window { position: relative !important; margin-top: 16px; }
    aside .x-btn { flex: 0 0 34px !important; }
`;

function button(id, type, state, extra = '') {
    return `<a role="button" id="${id}" class="x-btn x-btn-${type} ${state} ${extra}" style="width:150px;height:30px"><span class="x-btn-wrap x-btn-wrap-${type} x-btn-arrow-right"><span class="x-btn-button x-btn-button-${type} x-btn-text x-btn-icon x-btn-icon-left"><span class="x-btn-icon-el x-btn-icon-el-${type}">&#9654;</span><span class="x-btn-inner x-btn-inner-${type}">Console</span></span></span></a>`;
}

// PVE renders the view controls in the west resource toolbar, separately from
// the application header. Native #view remains present even in icon mode.
const switcher = `<aside class="x-tree-panel"><div class="x-box-target"><div id="view" hidden></div>${['gear', 'server', 'sitemap', 'database', 'globe', 'settings'].map((name, i) => button(`view-${name}`, 'default-toolbar-small', i === 1 ? 'x-btn-pressed' : '', i > 0 && i < 5 ? 'pmx-view-nav-button' : '').replace('x-btn-text x-btn-icon', 'x-btn-no-text x-btn-icon').replace('>Console</span>', '></span>')).join('')}</div></aside>`;
const treelist = `<ul class="x-treelist x-treelist-pve-nav"><li class="x-treelist-item x-treelist-item-selected"><div class="x-treelist-row"><div class="x-treelist-item-wrap"><span class="x-treelist-item-icon">&#9654;</span><span class="x-treelist-item-text">Hardware</span></div></div><ul><li class="x-treelist-item"><div class="x-treelist-row"><div class="x-treelist-item-wrap"><span class="x-treelist-item-icon">&#9654;</span><span class="x-treelist-item-text">Nested navigation</span></div></div></li></ul></li></ul>`;

const controls = `<header class="x-plain" role="region"><div id="versioninfo">Proxmox</div>${states.map((s, i) => button(`header-${i}`, 'default-small', s) + button(`header-toolbar-${i}`, 'default-toolbar-small', s)).join('')}</header><main>${states.map((s, i) => button(`primary-${i}`, 'default-small', s) + button(`inline-${i}`, 'default-small', s, 'proxmox-inline-button')).join('')}<div class="x-toolbar x-toolbar-default">${states.map((s, i) => button(`toolbar-${i}`, 'default-toolbar-small', s)).join('')}</div><div class="x-segmented-button">${states.map((s, i) => button(`segment-${i}`, 'default-small', s, 'proxmox-inline-button')).join('')}</div><section class="x-window"><div class="x-tab x-tab-default x-tab-default-top x-tab-active"><span class="x-tab-inner x-tab-inner-default">Hardware</span></div><div class="x-toolbar x-toolbar-footer">${button('footer', 'default-small', '')}${states.map((s, i) => button(`secondary-${i}`, 'default-small', s, 'pmx-inventory-secondary-action')).join('')}</div></section></main>`;

(async () => {
    const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
    let checked = 0;
    try {
        const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
        await page.route('**/*', route => route.abort());
        for (const size of ['default', 'comfortable', 'large']) {
            // Secondary modal buttons belong to the shared PVE layer. All other
            // control states are also checked with the standalone PVE/PBS theme.
            for (const shared of [false, true]) {
                await page.setContent(`<html class="x-keyboard-mode proxmorph-theme-active proxmorph-font-default proxmorph-text-${size}"><head><style>${nativeCSS}</style><style>${themeCSS}</style>${shared ? `<style>${sharedCSS}</style>` : ''}<style>${fixtureCSS} aside{background:#425e70;padding:12px}.x-box-target{position:relative!important;display:flex!important}</style></head><body class="x-body">${controls}${switcher}${treelist}</body></html>`);
                const colors = await page.locator('.x-btn:not([id^="view-"])').evaluateAll(elements => elements.map(el => {
                    const style = getComputedStyle(el);
                    return {
                        id: el.id,
                        background: style.backgroundColor,
                        text: getComputedStyle(el.querySelector('.x-btn-inner')).color,
                        icon: getComputedStyle(el.querySelector('.x-btn-icon-el')).color,
                        arrow: getComputedStyle(el.querySelector('.x-btn-wrap'), '::after').color,
                    };
                }));
                for (const color of colors) {
                    if (!shared && color.id.startsWith('secondary')) continue;
                    const light = /^(header|primary|footer)/.test(color.id)
                        || (/^(inline|segment)/.test(color.id) && /-[34]$/.test(color.id));
                    for (const channel of ['text', 'icon', 'arrow']) {
                        const values = color[channel].match(/[\d.]+/g).map(Number);
                        const expectedLight = values.slice(0, 3).every(value => value > 230);
                        assert.equal(expectedLight, light, `${size}/${shared ? 'PVE shared' : 'standalone'}/${color.id}/${channel}: ${color[channel]} on ${color.background}`);
                        checked++;
                    }
                }
                const tab = await page.locator('.x-window .x-tab').evaluate(el => ({
                    background: getComputedStyle(el).backgroundColor,
                    text: getComputedStyle(el.querySelector('.x-tab-inner')).color,
                }));
                assert.equal(tab.background, 'rgb(197, 220, 232)', 'selected dialog tab keeps its pale surface');
                assert.equal(tab.text, 'rgb(0, 94, 133)', 'selected dialog tab uses readable dark text');
                if (shared) {
                    const selected = await page.locator('.x-treelist-item-selected > .x-treelist-row').evaluate(el => ({
                        background: getComputedStyle(el).backgroundColor,
                        text: getComputedStyle(el.querySelector('.x-treelist-item-text')).color,
                        icon: getComputedStyle(el.querySelector('.x-treelist-item-icon')).color,
                    }));
                    assert.equal(selected.background, 'rgb(80, 107, 123)', 'selected object navigation keeps the slate surface');
                    assert.equal(selected.text, 'rgb(244, 248, 251)', 'selected object navigation text is light on slate');
                    assert.equal(selected.icon, 'rgb(244, 248, 251)', 'selected object navigation icon is light on slate');
                    const nested = await page.locator('.x-treelist-item-selected .x-treelist-item .x-treelist-item-text').evaluate(el => getComputedStyle(el).color);
                    assert.equal(nested, 'rgb(72, 84, 95)', 'unselected nested navigation retains its dark body foreground');
                    for (const state of ['', 'x-btn-over', 'x-btn-focus', 'x-btn-pressed']) {
                        await page.locator('aside .x-btn').evaluateAll((elements, state) => elements.forEach(el => {
                            el.classList.remove('x-btn-over', 'x-btn-focus', 'x-btn-pressed');
                            if (state) el.classList.add(state);
                        }), state);
                        const icons = await page.locator('aside .x-btn').evaluateAll(elements => elements.map(el => ({
                            id: el.id,
                            color: getComputedStyle(el.querySelector('.x-btn-icon-el')).color,
                            background: getComputedStyle(el).backgroundColor,
                        })));
                        for (const icon of icons) {
                            assert.equal(icon.color, state === 'x-btn-pressed' ? 'rgb(191, 233, 255)' : 'rgb(244, 248, 251)', `${size}/${state}/${icon.id} remains visible on the slate toolbar`);
                            assert.equal(icon.background, 'rgba(0, 0, 0, 0)', `${icon.id} retains the transparent icon-switcher surface`);
                            checked++;
                        }
                    }
                }
            }
        }
        if (process.env.PROXMORPH_COLOR_SCREENSHOT) {
            await page.locator('header, main').evaluateAll(elements => elements.forEach(el => el.style.setProperty('display', 'none', 'important')));
            await page.locator('aside .x-btn').evaluateAll(elements => elements.forEach(el => {
                el.classList.remove('x-btn-over', 'x-btn-focus', 'x-btn-pressed');
                if (el.id === 'view-server') el.classList.add('x-btn-pressed');
            }));
            await page.screenshot({ path: process.env.PROXMORPH_COLOR_SCREENSHOT, fullPage: true });
        }
        console.log(`PASS: ${checked} ESXi Light control color checks plus dialog tabs, selected/nested navigation, and transparent switchers across 13/14/15 px`);
    } finally {
        await browser.close();
    }
})().catch(error => { console.error(error); process.exitCode = 1; });
