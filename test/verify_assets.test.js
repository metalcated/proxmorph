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

for (const file of jsFiles) {
    const source = fs.readFileSync(file, 'utf8');
    assert.doesNotThrow(() => new Function(source), `${path.relative(root, file)} parses`);
}

console.log(`PASS: ${cssFiles.length} CSS assets and ${jsFiles.length} JavaScript patches parse`);
