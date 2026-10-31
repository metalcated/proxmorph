#!/usr/bin/env bash
# Real installer functions, generated APT hook, and recovery on an isolated tree.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../install.sh" >/dev/null 2>&1
set +e
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
check() {
    if [[ "$2" == "$3" ]]; then printf 'PASS: %s\n' "$1";
    else printf 'FAIL: %s (expected %s, got %s)\n' "$1" "$2" "$3"; fail=1; fi
}
PRODUCT=PVE
WIDGET_TOOLKIT_DIR="${work}/widget"
THEMES_DIR="${WIDGET_TOOLKIT_DIR}/themes"
PROXMOXLIB_JS="${WIDGET_TOOLKIT_DIR}/proxmoxlib.js"
INDEX_TEMPLATE="${work}/index.html.tpl"
JS_PATCHES_DIR="${work}/scripts"
NOVNC_INDEX_TPL="${work}/novnc.html.tpl"
NOVNC_PROXMORPH_DIR="${work}/novnc"
PDM_THEMES_DIR="${work}/pdm-themes"
PDM_JS_PATCHES_DIR="${work}/pdm-scripts"
PDM_MANAGER_DIR="${work}/pdm"
INSTALL_DIR="${work}/opt"
INSTALLED_PATHS_FILE="${INSTALL_DIR}/.installed-paths"
CONFIG_DIR="${work}/config"
BACKUP_ROOT="${work}/backups"
DEFAULT_THEME_FILE="${CONFIG_DIR}/default-theme"
AUTO_THEME_FILE="${CONFIG_DIR}/auto-themes"
FONT_FILE="${CONFIG_DIR}/font"
FONT_CSS="${CONFIG_DIR}/font.css"
APT_HOOK_FILE="${work}/apt-hook"
POST_INVOKE_SCRIPT="${INSTALL_DIR}/post-update.sh"
PROXMORPH_LOG_FILE="${work}/hook.log"
LOCK_FILE="${work}/lock"
PROXY_SERVICE=""
mkdir -p "$THEMES_DIR" "$JS_PATCHES_DIR" "$NOVNC_PROXMORPH_DIR" "$PDM_THEMES_DIR" "$PDM_JS_PATCHES_DIR" "$CONFIG_DIR"
printf 'theme_map: {\n"test": "Test",\n}\n' > "$PROXMOXLIB_JS"
printf '/*!Test*/\n:root { --pm-accent: red; }\n' > "${THEMES_DIR}/theme-test.css"
printf '/* native widget-toolkit theme */\n' > "${THEMES_DIR}/theme-proxmox-dark.css"
printf 'console.log("old");\n' > "${JS_PATCHES_DIR}/inventory.js"
printf 'console.log("console");\n' > "${NOVNC_PROXMORPH_DIR}/proxmorph-novnc.js"
printf 'body { color: red; }\n' > "${NOVNC_PROXMORPH_DIR}/proxmorph-novnc.css"
cat > "$INDEX_TEMPLATE" <<'HTML'
<html><head>
<link href="/pwt/themes/theme-proxmox-dark.css?ver=stock">
<link href="/pwt/themes/theme-[% theme %].css?ver=[% wtversion %]">
<script src="/proxmoxlib.js?ver=[% wtversion %]"></script>
</head><body>
<!-- ProxMorph JS Patches -->
<script src="/pve2/js/proxmorph/inventory.js"></script>
<!-- /ProxMorph JS Patches -->
</body></html>
HTML
cat > "$NOVNC_INDEX_TPL" <<'HTML'
<head>
<script type="module">import UI from "/novnc/app.js?ver=stock";
import("/novnc/proxmorph/proxmorph-novnc.js?ver=old");</script>
<link href="/novnc/proxmorph/proxmorph-novnc.css?ver=old">
</head>
HTML
before=$(asset_fingerprint "$INDEX_TEMPLATE")
refresh_browser_asset_versions --check
check 'check mode identifies stale references' 1 "$?"
check 'check mode never writes the template' "$before" "$(asset_fingerprint "$INDEX_TEMPLATE")"
refresh_browser_asset_versions
check 'PVE refresh succeeds' 0 "$?"
check 'script URL fingerprints the installed content' yes "$(grep -qF "/inventory.js?pmver=$(asset_fingerprint "${JS_PATCHES_DIR}/inventory.js")" "$INDEX_TEMPLATE" && echo yes || echo no)"
check 'patched native theme selector library gets a content key' yes "$(grep -qF "proxmoxlib.js?ver=[% wtversion %]&pmver=$(asset_fingerprint "$PROXMOXLIB_JS")" "$INDEX_TEMPLATE" && echo yes || echo no)"
check 'native dynamic theme link preserves template expressions' yes "$(grep -qF 'theme-[% theme %].css?ver=[% wtversion %]&pmver=' "$INDEX_TEMPLATE" && echo yes || echo no)"
check 'stock theme URL is untouched' yes "$(grep -qF 'theme-proxmox-dark.css?ver=stock"' "$INDEX_TEMPLATE" && echo yes || echo no)"
check 'native noVNC module remains untouched' yes "$(grep -qF '/novnc/app.js?ver=stock"' "$NOVNC_INDEX_TPL" && echo yes || echo no)"
check 'noVNC enhancement module gets its own content key' yes "$(grep -qF "proxmorph-novnc.js?ver=old&pmver=$(asset_fingerprint "${NOVNC_PROXMORPH_DIR}/proxmorph-novnc.js")" "$NOVNC_INDEX_TPL" && echo yes || echo no)"
before=$(asset_fingerprint "$INDEX_TEMPLATE")
refresh_browser_asset_versions
check 'unchanged assets produce byte-identical references' "$before" "$(asset_fingerprint "$INDEX_TEMPLATE")"
printf '/* native package update does not change custom theme keys */\n' >> "${THEMES_DIR}/theme-proxmox-dark.css"
refresh_browser_asset_versions
check 'native stock styles do not perturb ProxMorph cache keys' "$before" "$(asset_fingerprint "$INDEX_TEMPLATE")"
refresh_browser_asset_versions --check
check 'current references pass the read-only check' 0 "$?"
asset_fingerprint "${work}/missing-asset.js" >/dev/null 2>&1
check 'missing asset cannot yield a successful blank fingerprint' 1 "$?"
old_script=$(grep 'inventory.js' "$INDEX_TEMPLATE")
old_theme=$(grep 'theme-\[%' "$INDEX_TEMPLATE")
printf 'console.log("new without a version bump");\n' > "${JS_PATCHES_DIR}/inventory.js"
refresh_browser_asset_versions
check 'changed script gets a fresh URL without an installer version bump' yes "$([[ "$old_script" != "$(grep 'inventory.js' "$INDEX_TEMPLATE")" ]] && echo yes || echo no)"
check 'unrelated CSS URL stays stable after a script change' "$old_theme" "$(grep 'theme-\[%' "$INDEX_TEMPLATE")"
old_library=$(grep 'proxmoxlib.js' "$INDEX_TEMPLATE")
printf 'theme_map: {\n"test": "Test",\n"extra": "Extra",\n}\n' > "$PROXMOXLIB_JS"
refresh_browser_asset_versions
check 'theme selector library gets a new key after registration changes' yes "$([[ "$old_library" != "$(grep 'proxmoxlib.js' "$INDEX_TEMPLATE")" ]] && echo yes || echo no)"
printf 'test\n' > "$DEFAULT_THEME_FILE"
THEME_WEB_PATH=/pwt/themes
THEME_COOKIE=PVEThemeCookie
inject_default_theme >/dev/null
check 'synchronous default-theme bootstrap has a cache key' yes "$(grep -qE "theme-' \+ k \+ '\.css\?pmver=[0-9a-f]{16}" "$INDEX_TEMPLATE" && echo yes || echo no)"
old_theme=$(grep 'theme-\[%' "$INDEX_TEMPLATE")
printf '/*!Test*/\n:root { --pm-accent: blue; }\n' > "${THEMES_DIR}/theme-test.css"
refresh_browser_asset_versions
check 'changed stylesheet refreshes the dynamic theme URL' yes "$([[ "$old_theme" != "$(grep 'theme-\[%' "$INDEX_TEMPLATE")" ]] && echo yes || echo no)"
check 'refresh preserves the template mode' 644 "$(stat -c %a "$INDEX_TEMPLATE")"
owner=$(stat -c '%u:%g' "$INDEX_TEMPLATE")
chmod 640 "$INDEX_TEMPLATE"
printf '/* change to trigger an atomic template rewrite */\n' >> "${JS_PATCHES_DIR}/inventory.js"
refresh_browser_asset_versions
check 'atomic rewrite preserves a restrictive template mode' 640 "$(stat -c %a "$INDEX_TEMPLATE")"
check 'atomic rewrite preserves template ownership' "$owner" "$(stat -c '%u:%g' "$INDEX_TEMPLATE")"
chmod 644 "$INDEX_TEMPLATE"

# PBS uses different native theme URLs and handlebars expressions.
PRODUCT=PBS
THEME_WEB_PATH=/widgettoolkit/themes
THEME_COOKIE=PBSThemeCookie
printf '<head><link href="/widgettoolkit/themes/theme-{{theme}}.css?ver={{wtversion}}"><script src="/widgettoolkit/proxmoxlib.js"></script><script src="/js/proxmorph/inventory.js?other=keep&pmver=old#part"></script></head>\n' > "$INDEX_TEMPLATE"
refresh_browser_asset_versions
check 'PBS native theme template gets a collection key' yes "$(grep -qF 'theme-{{theme}}.css?ver={{wtversion}}&pmver=' "$INDEX_TEMPLATE" && echo yes || echo no)"
check 'PBS uses its native widget-library URL' yes "$(grep -qF "widgettoolkit/proxmoxlib.js?pmver=$(asset_fingerprint "$PROXMOXLIB_JS")" "$INDEX_TEMPLATE" && echo yes || echo no)"
check 'old cache key is replaced while preserving other query and fragment' yes "$(grep -qF "inventory.js?other=keep&pmver=$(asset_fingerprint "${JS_PATCHES_DIR}/inventory.js")#part" "$INDEX_TEMPLATE" && echo yes || echo no)"

# A real restore must reinstate both the asset bytes and their matching URLs.
create_backup cache-version-fixture "$THEMES_DIR" >/dev/null
backup_id="$LAST_BACKUP_ID"
saved_index=$(asset_fingerprint "$INDEX_TEMPLATE")
saved_asset=$(asset_fingerprint "${JS_PATCHES_DIR}/inventory.js")
printf 'damaged upgrade\n' > "${JS_PATCHES_DIR}/inventory.js"
refresh_browser_asset_versions
restore_backup_internal "$backup_id" true false >/dev/null
check 'restore recovers the prior template byte-for-byte' "$saved_index" "$(asset_fingerprint "$INDEX_TEMPLATE")"
check 'restore recovers matching prior asset bytes' "$saved_asset" "$(asset_fingerprint "${JS_PATCHES_DIR}/inventory.js")"
refresh_browser_asset_versions --check
check 'restored assets and URLs remain consistent' 0 "$?"
( set -Ee
  begin_transaction 'cache-refresh-failure'
  printf 'partial asset upgrade\n' > "${JS_PATCHES_DIR}/inventory.js"
  # Rejecting an invalid mode injects a real error from the refresh helper.
  refresh_browser_asset_versions invalid-mode
) >/dev/null 2>&1
check 'failed cache refresh retains its failure status' 255 "$?"
check 'failed refresh rolls the asset upgrade back' "$saved_asset" "$(asset_fingerprint "${JS_PATCHES_DIR}/inventory.js")"
check 'failed refresh restores the matching template' "$saved_index" "$(asset_fingerprint "$INDEX_TEMPLATE")"
refresh_browser_asset_versions
check 'cache refresh can be retried after rollback' 0 "$?"

# The generated post-update hook must share the implementation, take its backup,
# repair stale keys even with existing markers, and be inert on a second pass.
mkdir -p "${INSTALL_DIR}/themes/patches"
cp "${THEMES_DIR}/theme-test.css" "${INSTALL_DIR}/themes/"
cp "${JS_PATCHES_DIR}/inventory.js" "${INSTALL_DIR}/themes/patches/"
cat > "${INSTALL_DIR}/install.sh" <<'HOOK_BACKUP'
#!/bin/bash
mkdir -p "$PROXMORPH_BACKUP_ROOT/pbs"
printf 'cache-fixture\n' > "$PROXMORPH_BACKUP_ROOT/pbs/latest"
printf '%s\n' "$1" >> "${PROXMORPH_BACKUP_ROOT}/calls"
HOOK_BACKUP
chmod +x "${INSTALL_DIR}/install.sh"
printf '<head><script src="/widgettoolkit/proxmoxlib.js?ver=stock"></script></head><body>\n<!-- ProxMorph JS Patches -->\n<script src="/js/proxmorph/inventory.js"></script>\n<!-- /ProxMorph JS Patches -->\n</body>\n' > "$INDEX_TEMPLATE"
install_apt_hook >/dev/null
bash -n "$POST_INVOKE_SCRIPT"
check 'generated hook syntax is valid' 0 "$?"
bash "$POST_INVOKE_SCRIPT" >/dev/null 2>&1
check 'APT hook refreshes stale references inside an existing loader block' yes "$(grep -qF 'inventory.js?pmver=' "$INDEX_TEMPLATE" && echo yes || echo no)"
check 'APT refresh still calls the backup gate' backup "$(head -1 "${BACKUP_ROOT}/calls")"
before=$(asset_fingerprint "$INDEX_TEMPLATE")
bash "$POST_INVOKE_SCRIPT" >/dev/null 2>&1
check 'second APT pass leaves references unchanged' "$before" "$(asset_fingerprint "$INDEX_TEMPLATE")"
check 'second APT pass creates no redundant backup' 1 "$(wc -l < "${BACKUP_ROOT}/calls" | tr -d ' ')"

# PDM links are explicit and each gets its own stable fingerprint.
PRODUCT=PDM
printf 'body {}\n' > "${PDM_THEMES_DIR}/theme-test.css"
printf 'body { margin: 0; }\n' > "${PDM_THEMES_DIR}/proxmorph-pdm-base.css"
printf '/* selector */\n' > "${PDM_JS_PATCHES_DIR}/pdm-theme-selector.js"
printf '<head><link class="proxmorph-base" disabled href="/proxmorph-themes/proxmorph-pdm-base.css"><link class="proxmorph-theme" disabled href="/proxmorph-themes/theme-test.css"><script src="/js/proxmorph/pdm-theme-selector.js"></script></head>\n' > "$INDEX_TEMPLATE"
refresh_browser_asset_versions
check 'PDM stylesheet keeps its disabled flag and gets a content key' yes "$(grep -qF "disabled href=\"/proxmorph-themes/theme-test.css?pmver=$(asset_fingerprint "${PDM_THEMES_DIR}/theme-test.css")" "$INDEX_TEMPLATE" && echo yes || echo no)"
check 'PDM selector script gets a content key' yes "$(grep -qF "pdm-theme-selector.js?pmver=$(asset_fingerprint "${PDM_JS_PATCHES_DIR}/pdm-theme-selector.js")" "$INDEX_TEMPLATE" && echo yes || echo no)"
exit "$fail"
