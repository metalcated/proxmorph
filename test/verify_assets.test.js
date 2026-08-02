'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');

function walk(directory, predicate) {
    return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
        const fullPath = path.join(directory, entry.name);
        if (entry.isDirectory()) {
            return walk(fullPath, predicate);
        }
        return predicate(fullPath) ? [fullPath] : [];
    });
}

const cssFiles = walk(path.join(root, 'themes'), (file) => file.endsWith('.css'));
const jsFiles = walk(path.join(root, 'themes', 'patches'), (file) => file.endsWith('.js'));
const releaseWorkflow = fs.readFileSync(path.join(root, '.github', 'workflows', 'release.yml'), 'utf8');
const preferencesApi = path.join(root, 'server', 'PVE', 'API2', 'ProxMorph.pm');
const pveThemeFiles = fs
    .readdirSync(path.join(root, 'themes'))
    .filter((file) => /^theme-.*\.css$/.test(file));

assert.ok(fs.existsSync(preferencesApi), 'authenticated preferences API source is present');
assert.match(releaseWorkflow, /cp -r server release\//, 'release archives include server-side modules');

for (const file of cssFiles) {
    const source = fs.readFileSync(file, 'utf8');
    const relative = path.relative(root, file);
    if (path.basename(file).startsWith('theme-')) {
        const firstLine = source.split(/\r?\n/, 1)[0];
        assert.match(firstLine, /^\/\*![^*]+\*\/$/, `${relative} has a valid theme title`);
    }

    const css = source
        .replace(/\/\*[\s\S]*?\*\//g, '')
        .replace(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/g, '');

    let depth = 0;
    let topLevelStatement = '';
    for (const char of css) {
        if (char === '{') {
            depth++;
            topLevelStatement = '';
        } else if (char === '}') {
            depth--;
            assert.ok(depth >= 0, `${relative} has an unmatched closing brace`);
            topLevelStatement = '';
        } else if (depth === 0) {
            topLevelStatement += char;
            if (char === ';') {
                assert.doesNotMatch(
                    topLevelStatement.trim(),
                    /^--[a-z0-9-]+\s*:/i,
                    `${relative} has a custom property outside a selector`,
                );
                topLevelStatement = '';
            }
        }
    }
    assert.equal(depth, 0, `${relative} has balanced braces`);
}

for (const file of pveThemeFiles) {
    const source = fs.readFileSync(path.join(root, 'themes', file), 'utf8');
    const usesGitHubTokens = source.includes('--gh-canvas-default:');
    const requiredTokens = usesGitHubTokens
        ? [
              '--gh-canvas-default:',
              '--gh-canvas-muted:',
              '--gh-fg-default:',
              '--gh-fg-muted:',
              '--gh-border-default:',
              '--gh-accent-fg:',
          ]
        : [
              '--pm-bg-base:',
              '--pm-bg-surface:',
              '--pm-text:',
              '--pm-text-dim:',
              '--pm-border:',
              '--pm-accent:',
          ];
    requiredTokens.forEach((token) => {
        assert.ok(source.includes(token), `${file} defines the shared semantic token ${token}`);
    });
    [
        '.x-treelist-item-text',
        '.x-menu-item-text-default',
        '.x-panel-header-title-default',
        '.x-toolbar-text-default',
        '.x-btn-default-toolbar-small',
        '.x-btn-menu-active',
        '.x-grid-item',
        '.x-grid-item-selected',
        '.x-menu-item-active',
        '.x-treelist-item-selected',
    ].forEach((selector) => {
        assert.ok(source.includes(selector), `${file} styles ${selector}`);
    });
}

for (const file of jsFiles) {
    const source = fs.readFileSync(file, 'utf8');
    assert.doesNotThrow(() => new Function(source), `${path.relative(root, file)} parses`);
}

console.log(`PASS: ${cssFiles.length} CSS assets and ${jsFiles.length} JavaScript patches parse`);
