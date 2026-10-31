'use strict';

// Optional browser test using an existing playwright-core installation. Runs a
// loopback fixture with long-lived asset caching; no packages or network needed.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { execFileSync } = require('node:child_process');
const { chromium } = require('playwright-core');
const root = path.resolve(__dirname, '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'proxmorph-cache-browser-'));
const dirs = {};
for (const name of ['themes', 'scripts', 'novnc', 'pdm-themes', 'pdm-scripts']) {
    dirs[name] = path.join(temporary, name);
    fs.mkdirSync(dirs[name]);
}
const pveIndex = path.join(temporary, 'pve.html');
const pdmIndex = path.join(temporary, 'pdm.html');
const library = path.join(temporary, 'proxmoxlib.js');
fs.writeFileSync(library, '/* fixture native library */');
const pveScript = path.join(dirs.scripts, 'inventory.js');
const pveTheme = path.join(dirs.themes, 'theme-test.css');
fs.writeFileSync(pveScript, 'document.documentElement.dataset.inventoryVersion = "old";');
fs.writeFileSync(pveTheme, 'body { color: rgb(10, 20, 30); }');
fs.writeFileSync(pveIndex, '<html><head><link rel="stylesheet" href="/pwt/themes/theme-[% theme %].css?ver=[% wtversion %]"><script src="/proxmoxlib.js"></script></head><body>Inventory fixture<script src="/pve2/js/proxmorph/inventory.js"></script></body></html>');
function refresh(product, index) {
    execFileSync('bash', ['-c', `
        source "$1" >/dev/null
        PRODUCT="$2"; INDEX_TEMPLATE="$3"; THEMES_DIR="$4"; PROXMOXLIB_JS="$5"
        JS_PATCHES_DIR="$6"; NOVNC_INDEX_TPL="$7"; NOVNC_PROXMORPH_DIR="$8"
        PDM_THEMES_DIR="$9"; PDM_JS_PATCHES_DIR="\${10}"
        refresh_browser_asset_versions
    `, 'cache-test',
        path.join(root, 'install.sh'), product, index, dirs.themes, library,
        dirs.scripts, path.join(temporary, 'missing-novnc.html'), dirs.novnc,
        dirs['pdm-themes'], dirs['pdm-scripts']], { encoding: 'utf8' });
}
const assets = new Map([
    ['/pwt/themes/theme-test.css', pveTheme],
    ['/proxmoxlib.js', library],
    ['/pve2/js/proxmorph/inventory.js', pveScript],
]);
const requests = [];
const server = http.createServer((request, response) => {
    const url = new URL(request.url, 'http://localhost');
    requests.push(url.pathname + url.search);
    if (url.pathname === '/' || url.pathname === '/pdm') {
        response.setHeader('Cache-Control', 'no-store');
        response.setHeader('Content-Type', 'text/html');
        response.end(fs.readFileSync(url.pathname === '/' ? pveIndex : pdmIndex, 'utf8')
            .replaceAll('[% theme %]', 'test').replaceAll('[% wtversion %]', '9.2.6'));
    } else if (assets.has(url.pathname)) {
        response.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
        response.setHeader('Content-Type', url.pathname.endsWith('.css') ? 'text/css' : 'application/javascript');
        response.end(fs.readFileSync(assets.get(url.pathname)));
    } else {
        response.writeHead(404).end();
    }
});

(async () => {
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const origin = `http://127.0.0.1:${server.address().port}`;
    const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
    try {
        const page = await browser.newPage();
        const errors = [];
        page.on('pageerror', error => errors.push(error.message));
        await page.goto(origin);
        assert.equal(await page.locator('html').getAttribute('data-inventory-version'), 'old');
        assert.equal(await page.locator('body').evaluate(el => getComputedStyle(el).color), 'rgb(10, 20, 30)');
        // Same filenames and installer version, new bytes, previously cached URL.
        fs.writeFileSync(pveScript, 'document.documentElement.dataset.inventoryVersion = "new";');
        fs.writeFileSync(pveTheme, 'body { color: rgb(30, 40, 50); }');
        refresh('PVE', pveIndex);
        await page.reload(); // Ordinary reload, not a hard/cache-bypassing reload.
        assert.equal(await page.locator('html').getAttribute('data-inventory-version'), 'new');
        assert.equal(await page.locator('body').evaluate(el => getComputedStyle(el).color), 'rgb(30, 40, 50)');
        assert.ok(requests.some(url => /^\/pve2\/js\/proxmorph\/inventory\.js\?pmver=[a-f0-9]{16}$/.test(url)));
        assert.ok(requests.some(url => /^\/pwt\/themes\/theme-test\.css\?ver=9\.2\.6&pmver=[a-f0-9]{16}$/.test(url)));
        const installed = fs.readFileSync(pveIndex, 'utf8');
        refresh('PVE', pveIndex);
        assert.equal(fs.readFileSync(pveIndex, 'utf8'), installed);
        await page.reload();
        assert.equal(await page.locator('html').getAttribute('data-inventory-version'), 'new');

        // Exercise the real PDM selector and existing bootstrap: saved filenames
        // must remain independent of URL fingerprints across reopen and upgrade.
        const selector = path.join(dirs['pdm-scripts'], 'pdm-theme-selector.js');
        fs.copyFileSync(path.join(root, 'themes/patches/pdm-theme-selector.js'), selector);
        assets.set('/js/proxmorph/pdm-theme-selector.js', selector);
        for (const name of ['proxmorph-pdm-base', 'theme-test-one', 'theme-test-two']) {
            const file = path.join(dirs['pdm-themes'], name + '.css');
            fs.writeFileSync(file, name === 'theme-test-one' ? 'body { color: rgb(70, 80, 90); }' : 'body { background: white; }');
            assets.set('/proxmorph-themes/' + name + '.css', file);
        }
        const installer = fs.readFileSync(path.join(root, 'install.sh'), 'utf8');
        const bootstrap = installer.match(/cat >> "\$tmpblock" << 'JSBLOCK'\n([\s\S]*?)\nJSBLOCK/)[1];
        fs.writeFileSync(pdmIndex, `<html><head>
            <link rel="stylesheet" class="proxmorph-base" href="/proxmorph-themes/proxmorph-pdm-base.css" disabled>
            <link rel="stylesheet" class="proxmorph-theme" data-title="Test One" href="/proxmorph-themes/theme-test-one.css" disabled>
            <link rel="stylesheet" class="proxmorph-theme" data-title="Test Two" href="/proxmorph-themes/theme-test-two.css" disabled>
            ${bootstrap}<script src="/js/proxmorph/pdm-theme-selector.js"></script>
            </head><body><button id="open">Theme settings</button><script>
            document.querySelector('#open').onclick = () => {
                const dialog = document.createElement('dialog'); dialog.open = true;
                dialog.innerHTML = '<input aria-label="Select Theme" value="Desktop"><table class="pwt-datatable-content"><tbody><tr role="row"><td class="pwt-datatable-cell">Desktop</td></tr><tr role="row"><td class="pwt-datatable-cell">Crisp</td></tr></tbody></table><button id="close">Close</button>';
                document.body.appendChild(dialog);
                dialog.querySelector('#close').onclick = () => dialog.remove();
            };</script></body></html>`);
        refresh('PDM', pdmIndex);
        await page.goto(origin + '/pdm');
        await page.getByRole('button', { name: 'Theme settings' }).click();
        await page.getByRole('row', { name: 'PM: Test One', exact: true }).click();
        assert.equal(await page.evaluate(() => localStorage.getItem('proxmorph-theme')), 'theme-test-one.css');
        assert.equal(await page.getByLabel('Select Theme').inputValue(), 'PM: Test One');
        await page.getByRole('button', { name: 'Close', exact: true }).click();
        // The existing selector observes modal closure on its 500 ms timer.
        await page.waitForTimeout(550);
        await page.getByRole('button', { name: 'Theme settings' }).click();
        assert.equal(await page.getByLabel('Select Theme').inputValue(), 'PM: Test One');
        const one = assets.get('/proxmorph-themes/theme-test-one.css');
        fs.writeFileSync(one, 'body { color: rgb(90, 100, 110); }');
        refresh('PDM', pdmIndex);
        await page.reload();
        assert.equal(await page.evaluate(() => localStorage.getItem('proxmorph-theme')), 'theme-test-one.css');
        await page.waitForFunction(() => getComputedStyle(document.body).color === 'rgb(90, 100, 110)');
        await page.getByRole('button', { name: 'Theme settings' }).click();
        assert.equal(await page.getByLabel('Select Theme').inputValue(), 'PM: Test One');
        await page.getByRole('row', { name: 'Desktop', exact: true }).click();
        assert.equal(await page.evaluate(() => localStorage.getItem('proxmorph-theme')), null);
        assert.equal(await page.locator('link.proxmorph-theme:not([disabled])').count(), 0);
        await page.getByRole('row', { name: 'PM: Test Two', exact: true }).click();
        assert.equal(await page.evaluate(() => localStorage.getItem('proxmorph-theme')), 'theme-test-two.css');
        assert.deepEqual(errors, []);
        console.log('PASS: cached old JS/CSS refresh on an ordinary reload; unchanged URLs remain stable; real PDM selector preserves saved choices through selection, reopen, upgraded CSS, reload, stock fallback, and retry');
    } finally {
        await browser.close();
    }
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => {
    server.close();
    fs.rmSync(temporary, { recursive: true, force: true });
});
