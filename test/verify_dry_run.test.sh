#!/usr/bin/env bash
# No-write preview tests using an isolated fake PVE filesystem.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../install.sh
source "${HERE}/../install.sh" >/dev/null 2>&1
set +e

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

PRODUCT="PVE"
BACKUP_ROOT="${work}/backups"
WIDGET_TOOLKIT_DIR="${work}/system/widget-toolkit"
THEMES_DIR="${WIDGET_TOOLKIT_DIR}/themes"
PROXMOXLIB_JS="${WIDGET_TOOLKIT_DIR}/proxmoxlib.js"
INDEX_TEMPLATE="${work}/system/pve-manager/index.html.tpl"
PVE_MANAGER_JS="${work}/system/pve-manager/js/pvemanagerlib.js"
JS_PATCHES_DIR="${work}/system/pve-manager/js/proxmorph"
NODES_PM="${work}/system/perl/PVE/API2/Nodes.pm"
PVE_CLUSTER_PM="${work}/system/perl/PVE/Cluster.pm"
PVE_API2_PM="${work}/system/perl/PVE/API2.pm"
PVE_PROXMORPH_API_PM="${work}/system/perl/PVE/API2/ProxMorph.pm"
PVE_PREFERENCES_FILE="${work}/etc/pve/priv/proxmorph-user-preferences.json"
NOVNC_INDEX_TPL="${work}/system/novnc/index.html.tpl"
NOVNC_PROXMORPH_DIR="${work}/system/novnc/proxmorph"
INSTALL_DIR="${work}/opt/proxmorph"
INSTALLED_PATHS_FILE="${INSTALL_DIR}/.installed-paths"
CONFIG_DIR="${work}/etc/proxmorph"
DEFAULT_THEME_FILE="${CONFIG_DIR}/default-theme"
APT_HOOK_FILE="${work}/etc/apt/99proxmorph"
POST_INVOKE_SCRIPT="${INSTALL_DIR}/post-update.sh"
PROXMORPH_LOG_FILE="${work}/var/log/proxmorph.log"
LOCK_FILE="${work}/run/proxmorph.lock"
PROXY_SERVICE="pveproxy"
PDM_THEMES_DIR="${work}/unused/pdm-themes"
PDM_JS_PATCHES_DIR="${work}/unused/pdm-js"
SENSORS_CONFIG="${INSTALL_DIR}/.sensors-enabled"
SENSORS_FILTER="${INSTALL_DIR}/.sensors-filter"
SENSORS_PACKAGE_MARKER="${INSTALL_DIR}/.lm-sensors-installed-by-proxmorph"
THEME_COOKIE="PVEThemeCookie"
THEME_WEB_PATH="/pwt/themes"

theme_source="${work}/release/themes"
mkdir -p "$THEMES_DIR" "$(dirname "$INDEX_TEMPLATE")" "$(dirname "$PVE_MANAGER_JS")" \
    "$(dirname "$NODES_PM")" "$(dirname "$NOVNC_INDEX_TPL")" "$theme_source/patches" "$theme_source/novnc"
printf '%s\n' 'Proxmox.Utils = { theme_map: {' > "$PROXMOXLIB_JS"
printf '%s\n' '<script src="/pve2/js/pvemanagerlib.js"></script>' '</head>' '</body>' > "$INDEX_TEMPLATE"
printf '%s\n' "Ext.define('PVE.form.ViewSelector');" "Ext.define('PVE.tree.ResourceTree');" \
    "Ext.define('PVE.node.StatusView');" "Ext.define('PVE.panel.Config');" \
    "Ext.define('PVE.sdn.VnetEdit');" "Ext.define('PVE.sdn.SubnetView');" \
    "Ext.define('PVE.sdn.VnetACLView');" "Ext.define('PVE.dc.CmdMenu');" \
    "Ext.define('PVE.node.CmdMenu');" > "$PVE_MANAGER_JS"
printf '%s\n' '        my $dinfo = df('\''/'\'', 1);' > "$NODES_PM"
printf '%s\n' 'my $observed = {' '};' > "$PVE_CLUSTER_PM"
printf '%s\n' 'package PVE::API2;' 'use base qw(PVE::RESTHandler);' '1;' > "$PVE_API2_PM"
printf '%s\n' '<html><head>' '  <script type="module">' \
    '    import UI from "/novnc/app.js?ver=1.7.0-2";' '  </script>' '</head><body>' \
    '  <input id="noVNC_clipboard_button">' '</body></html>' > "$NOVNC_INDEX_TPL"
printf '%s\n' 'ORIGINAL THEME' > "${THEMES_DIR}/theme-test.css"
printf '%s\n' '/*!Test*/' ':root {}' > "${theme_source}/theme-test.css"
printf '%s\n' '(function () {})();' > "${theme_source}/patches/test.js"
printf '%s\n' '(function () {})();' > "${theme_source}/novnc/proxmorph-novnc.js"
printf '%s\n' '.pmx-novnc-context-menu { display: none; }' > "${theme_source}/novnc/proxmorph-novnc.css"

fail=0
check() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $name"
    else
        echo "FAIL: $name (expected '$expected', got '$actual')"
        fail=1
    fi
}

tree_snapshot() {
    (
        cd "$work" || exit 1
        find . -type d -print | LC_ALL=C sort
        find . -type f -exec sha256sum {} \; | LC_ALL=C sort
        find . -type l -exec sh -c 'printf "%s -> %s\n" "$1" "$(readlink "$1")"' _ {} \; | LC_ALL=C sort
    )
}

# Install preview validates the exact patch points and enumerates changes, but
# it must not create a transaction backup, lock, or any other file.
before=$(tree_snapshot)
install_preview=$(preview_install_operation install)
install_rc=$?
after=$(tree_snapshot)
check 'install dry run succeeds' 0 "$install_rc"
check 'install dry run leaves the filesystem byte-for-byte unchanged' "$before" "$after"
check 'install dry run does not create a backup root' no "$([[ -e "$BACKUP_ROOT" ]] && echo yes || echo no)"
check 'install dry run shows package-owned modification' yes "$(grep -qF "[modify] ${INDEX_TEMPLATE}" <<< "$install_preview" && echo yes || echo no)"
check 'install dry run shows authenticated preference API changes' yes "$(grep -qF "[modify] ${PVE_API2_PM}" <<< "$install_preview" && echo yes || echo no)"
check 'install dry run shows the noVNC template change' yes "$(grep -qF "[modify] ${NOVNC_INDEX_TPL}" <<< "$install_preview" && echo yes || echo no)"
check 'install dry run records the noVNC asset directory as initially absent' yes "$(grep -qF "[record absent] ${NOVNC_PROXMORPH_DIR}" <<< "$install_preview" && echo yes || echo no)"
check 'install dry run records preference data as initially absent' yes "$(grep -qF "[record absent] ${PVE_PREFERENCES_FILE}" <<< "$install_preview" && echo yes || echo no)"
check 'install dry run shows proxy restart without performing it' yes "$(grep -qF '[restart] pveproxy' <<< "$install_preview" && echo yes || echo no)"

# Build a real fixture backup, then prove restore and uninstall previews only
# inspect it. The backup listing is also the source of the restore ID.
create_backup "install" "$theme_source" >/dev/null
backup_id="$LAST_BACKUP_ID"
printf '%s\n' 'CURRENT INDEX' > "$INDEX_TEMPLATE"
before=$(tree_snapshot)
restore_preview=$(preview_restore_operation "$backup_id")
restore_rc=$?
after=$(tree_snapshot)
check 'restore dry run succeeds' 0 "$restore_rc"
check 'restore dry run leaves the filesystem byte-for-byte unchanged' "$before" "$after"
check 'restore dry run resolves the listed backup ID' yes "$(grep -qF "Resolved backup ID: ${backup_id}" <<< "$restore_preview" && echo yes || echo no)"
check 'restore dry run previews its safety backup' yes "$(grep -qF 'Planned pre-restore safety backup:' <<< "$restore_preview" && echo yes || echo no)"
check 'restore dry run shows the exact restore path' yes "$(grep -qF "[restore] ${INDEX_TEMPLATE}" <<< "$restore_preview" && echo yes || echo no)"

before=$(tree_snapshot)
uninstall_preview=$(preview_uninstall_operation)
uninstall_rc=$?
after=$(tree_snapshot)
check 'uninstall dry run succeeds' 0 "$uninstall_rc"
check 'uninstall dry run leaves the filesystem byte-for-byte unchanged' "$before" "$after"
check 'uninstall dry run identifies the clean baseline' yes "$(grep -qF "exact clean baseline: ${backup_id}" <<< "$uninstall_preview" && echo yes || echo no)"
check 'uninstall dry run retains rollback backups' yes "$(grep -qF '[retain]' <<< "$uninstall_preview" && echo yes || echo no)"

before=$(tree_snapshot)
sensor_preview=$(
    package_is_installed() { return 1; }
    detect_sensors() { return 1; }
    get_remote_nodes() { :; }
    preview_sensor_operation enable
)
sensor_preview_rc=$?
after=$(tree_snapshot)
check 'sensor enable dry run succeeds before lm-sensors is installed' 0 "$sensor_preview_rc"
check 'sensor enable dry run leaves the filesystem byte-for-byte unchanged' "$before" "$after"
check 'sensor enable dry run previews lm-sensors installation' yes "$(grep -qF '[install optional package] lm-sensors' <<< "$sensor_preview" && echo yes || echo no)"
check 'sensor enable dry run previews automatic detection' yes "$(grep -qF '[hardware probe] sensors-detect --auto' <<< "$sensor_preview" && echo yes || echo no)"

saved_backup_root="$BACKUP_ROOT"
BACKUP_ROOT="${work}/no-backups"
before=$(tree_snapshot)
fallback_preview=$(preview_uninstall_operation)
fallback_rc=$?
after=$(tree_snapshot)
check 'fallback uninstall dry run succeeds without a baseline' 0 "$fallback_rc"
check 'fallback uninstall dry run leaves the filesystem byte-for-byte unchanged' "$before" "$after"
check 'fallback uninstall dry run shows current package recovery' yes "$(grep -qF '[reinstall package] pve-manager' <<< "$fallback_preview" && echo yes || echo no)"
BACKUP_ROOT="$saved_backup_root"

# Exercise the main argument parser in isolation. If lock acquisition is
# reached, this deliberately fails and writes a sentinel.
parser_preview=$(
    check_root() { :; }
    check_product() { :; }
    dry_run_dispatch() { printf 'dispatch=%s\n' "$*"; }
    acquire_operation_lock() { printf '%s\n' lock-called > "$LOCK_FILE"; return 99; }
    DRY_RUN=false
    main update 2.12.0 --dry-run
)
parser_rc=$?
check 'main accepts --dry-run after command arguments' 0 "$parser_rc"
check 'main preserves non-dry-run positional arguments' 'dispatch=update 2.12.0' "$parser_preview"
check 'main dry run exits before operation lock acquisition' no "$([[ -e "$LOCK_FILE" ]] && echo yes || echo no)"

parser_preview=$(
    check_root() { :; }
    check_product() { :; }
    dry_run_dispatch() { printf 'dispatch=%s\n' "$*"; }
    DRY_RUN=false
    main --dry-run restore "$backup_id" --force
)
check 'main accepts --dry-run before the command' "dispatch=restore ${backup_id} --force" "$parser_preview"

menu_output=$(
    check_root() { :; }
    check_product() { :; }
    acquire_operation_lock() { :; }
    list_themes() { printf '%s\n' menu-list-ran; return 9; }
    show_status() { printf '%s\n' menu-status-ran; }
    DRY_RUN=false
    main <<< $'5\n6\n0\n'
)
check 'menu mode runs the first selected action' yes "$(grep -qF 'menu-list-ran' <<< "$menu_output" && echo yes || echo no)"
check 'menu mode returns after a failed action' yes "$(grep -qF 'menu-status-ran' <<< "$menu_output" && echo yes || echo no)"
check 'menu mode reports an incomplete action' yes "$(grep -qF 'Action did not complete; returning to the main menu.' <<< "$menu_output" && echo yes || echo no)"
check 'menu mode remains open until Exit is selected' 3 "$(grep -cF 'Select an option:' <<< "$menu_output")"

rollback_probe() {
    trap 'printf "%s\n" rollback-ran > "${work}/menu-rollback"; exit 17' ERR
    false
}
run_menu_action rollback_probe >/dev/null
check 'menu action isolation preserves ERR rollback handling' rollback-ran "$(cat "${work}/menu-rollback" 2>/dev/null)"

# PDM has different live paths and injection rules; its install preview must
# remain no-write as well.
PRODUCT="PDM"
BACKUP_ROOT="${work}/pdm-backups"
INDEX_TEMPLATE="${work}/pdm/index.hbs"
PDM_THEMES_DIR="${work}/pdm/proxmorph-themes"
PDM_JS_PATCHES_DIR="${work}/pdm/js/proxmorph"
THEMES_DIR="$PDM_THEMES_DIR"
JS_PATCHES_DIR="$PDM_JS_PATCHES_DIR"
INSTALL_DIR="${work}/pdm-opt/proxmorph"
INSTALLED_PATHS_FILE="${INSTALL_DIR}/.installed-paths"
CONFIG_DIR="${work}/pdm-etc/proxmorph"
DEFAULT_THEME_FILE="${CONFIG_DIR}/default-theme"
APT_HOOK_FILE="${work}/pdm-etc/apt/99proxmorph"
PROXMORPH_LOG_FILE="${work}/pdm-var/log/proxmorph.log"
PROXY_SERVICE="proxmox-datacenter-api"
mkdir -p "$(dirname "$INDEX_TEMPLATE")"
printf '%s\n' '<html><head></head><body></body></html>' > "$INDEX_TEMPLATE"
before=$(tree_snapshot)
pdm_preview=$(preview_install_operation install)
pdm_rc=$?
after=$(tree_snapshot)
check 'PDM install dry run succeeds' 0 "$pdm_rc"
check 'PDM install dry run leaves the filesystem byte-for-byte unchanged' "$before" "$after"
check 'PDM install dry run shows index injection' yes "$(grep -qF "[modify] ${INDEX_TEMPLATE}" <<< "$pdm_preview" && echo yes || echo no)"
check 'PDM install dry run does not create a backup root' no "$([[ -e "$BACKUP_ROOT" ]] && echo yes || echo no)"

if [[ "$fail" -eq 0 ]]; then
    echo 'ALL PASS'
else
    echo 'FAILURES PRESENT'
fi
exit "$fail"
