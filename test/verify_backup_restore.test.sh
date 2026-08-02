#!/usr/bin/env bash
# Full-footprint backup/restore tests using an isolated fake PVE filesystem.
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
JS_PATCHES_DIR="${work}/system/pve-manager/js/proxmorph"
NODES_PM="${work}/system/perl/PVE/API2/Nodes.pm"
PVE_CLUSTER_PM="${work}/system/perl/PVE/Cluster.pm"
PVE_API2_PM="${work}/system/perl/PVE/API2.pm"
PVE_PROXMORPH_API_PM="${work}/system/perl/PVE/API2/ProxMorph.pm"
PVE_PREFERENCES_FILE="${work}/etc/pve/priv/proxmorph-user-preferences.json"
INSTALL_DIR="${work}/opt/proxmorph"
INSTALLED_PATHS_FILE="${INSTALL_DIR}/.installed-paths"
CONFIG_DIR="${work}/etc/proxmorph"
DEFAULT_THEME_FILE="${CONFIG_DIR}/default-theme"
APT_HOOK_FILE="${work}/etc/apt/99proxmorph"
PROXMORPH_LOG_FILE="${work}/var/log/proxmorph.log"
PROXY_SERVICE=""
PDM_THEMES_DIR="${work}/unused/pdm-themes"
PDM_JS_PATCHES_DIR="${work}/unused/pdm-js"
SENSORS_CONFIG="${INSTALL_DIR}/.sensors-enabled"
SENSORS_FILTER="${INSTALL_DIR}/.sensors-filter"
SENSORS_PACKAGE_MARKER="${INSTALL_DIR}/.lm-sensors-installed-by-proxmorph"

theme_source="${work}/release/themes"
mkdir -p "$THEMES_DIR" "$(dirname "$INDEX_TEMPLATE")" "$(dirname "$NODES_PM")" "$theme_source"
printf '%s\n' 'ORIGINAL PROXMOXLIB' > "$PROXMOXLIB_JS"
printf '%s\n' 'ORIGINAL INDEX' > "$INDEX_TEMPLATE"
printf '%s\n' 'ORIGINAL NODES' > "$NODES_PM"
printf '%s\n' 'ORIGINAL CLUSTER MODULE' > "$PVE_CLUSTER_PM"
printf '%s\n' 'ORIGINAL API ROOT' > "$PVE_API2_PM"
printf '%s\n' 'ORIGINAL THEME' > "${THEMES_DIR}/theme-test.css"
printf '%s\n' '/*!Test*/' ':root {}' > "${theme_source}/theme-test.css"

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

create_backup "install" "$theme_source" >/dev/null
backup_id="$LAST_BACKUP_ID"
backup_dir="$(product_backup_dir)/${backup_id}"

check 'backup is marked complete' yes "$([[ -f "${backup_dir}/.complete" ]] && echo yes || echo no)"
verify_backup "$backup_dir" >/dev/null 2>&1
check 'backup checksums verify' 0 "$?"
check 'backup records optional package state' yes "$([[ -f "${backup_dir}/optional-packages.tsv" ]] && echo yes || echo no)"
check 'first clean snapshot becomes uninstall baseline' "$backup_id" "$(tr -d ' \t\r\n' < "$(product_backup_dir)/baseline")"
backup_listing=$(list_backups)
check 'backup listing exposes the restore ID' yes "$(grep -qF "$backup_id" <<< "$backup_listing" && echo yes || echo no)"
check 'backup listing identifies the uninstall baseline' yes "$(grep -qF '[baseline]' <<< "$backup_listing" && echo yes || echo no)"

printf '%s\n' 'CHANGED PROXMOXLIB' > "$PROXMOXLIB_JS"
printf '%s\n' 'CHANGED INDEX' > "$INDEX_TEMPLATE"
printf '%s\n' 'CHANGED NODES' > "$NODES_PM"
printf '%s\n' 'CHANGED CLUSTER MODULE' > "$PVE_CLUSTER_PM"
printf '%s\n' 'CHANGED API ROOT' > "$PVE_API2_PM"
printf '%s\n' 'CHANGED THEME' > "${THEMES_DIR}/theme-test.css"
mkdir -p "$JS_PATCHES_DIR" "$INSTALL_DIR" "$CONFIG_DIR" "$(dirname "$APT_HOOK_FILE")" \
    "$(dirname "$PROXMORPH_LOG_FILE")" "$(dirname "$PVE_PROXMORPH_API_PM")" "$(dirname "$PVE_PREFERENCES_FILE")"
printf '%s\n' 'new patch' > "${JS_PATCHES_DIR}/new.js"
printf '%s\n' 'new API module' > "$PVE_PROXMORPH_API_PM"
printf '%s\n' '{"schema":1,"users":{"root@pam":{"groupByNode":0}}}' > "$PVE_PREFERENCES_FILE"
printf '%s\n' 'new cache' > "${INSTALL_DIR}/new.txt"
printf '%s\n' 'new config' > "$DEFAULT_THEME_FILE"
printf '%s\n' 'new hook' > "$APT_HOOK_FILE"
printf '%s\n' 'new log' > "$PROXMORPH_LOG_FILE"

restore_backup_internal "$backup_id" true false >/dev/null 2>&1
check 'restore succeeds' 0 "$?"
check 'proxmoxlib is restored byte-for-byte' 'ORIGINAL PROXMOXLIB' "$(cat "$PROXMOXLIB_JS")"
check 'index template is restored byte-for-byte' 'ORIGINAL INDEX' "$(cat "$INDEX_TEMPLATE")"
check 'Nodes.pm is restored byte-for-byte' 'ORIGINAL NODES' "$(cat "$NODES_PM")"
check 'Cluster.pm is restored byte-for-byte' 'ORIGINAL CLUSTER MODULE' "$(cat "$PVE_CLUSTER_PM")"
check 'API2.pm is restored byte-for-byte' 'ORIGINAL API ROOT' "$(cat "$PVE_API2_PM")"
check 'new preferences API module is removed' no "$([[ -e "$PVE_PROXMORPH_API_PM" ]] && echo yes || echo no)"
check 'new cluster preference data is removed' no "$([[ -e "$PVE_PREFERENCES_FILE" ]] && echo yes || echo no)"
check 'pre-existing theme is restored byte-for-byte' 'ORIGINAL THEME' "$(cat "${THEMES_DIR}/theme-test.css")"
check 'new JavaScript directory is removed' no "$([[ -e "$JS_PATCHES_DIR" ]] && echo yes || echo no)"
check 'new install cache is removed' no "$([[ -e "$INSTALL_DIR" ]] && echo yes || echo no)"
check 'new configuration is removed' no "$([[ -e "$CONFIG_DIR" ]] && echo yes || echo no)"
check 'new apt hook is removed' no "$([[ -e "$APT_HOOK_FILE" ]] && echo yes || echo no)"
check 'new log is removed' no "$([[ -e "$PROXMORPH_LOG_FILE" ]] && echo yes || echo no)"

mkdir -p "$(dirname "$PVE_PREFERENCES_FILE")"
printf '%s\n' '{"schema":1,"users":{"root@pam":{"groupByNode":0}}}' > "$PVE_PREFERENCES_FILE"
create_backup "saved-preferences" "$theme_source" >/dev/null
preferences_backup_id="$LAST_BACKUP_ID"
printf '%s\n' '{"schema":1,"users":{}}' > "$PVE_PREFERENCES_FILE"
restore_backup_internal "$preferences_backup_id" true false >/dev/null 2>&1
check 'saved per-user preferences restore byte-for-byte' \
    '{"schema":1,"users":{"root@pam":{"groupByNode":0}}}' "$(cat "$PVE_PREFERENCES_FILE")"
rm -f "$PVE_PREFERENCES_FILE"

printf '%s\n' '/*!Future*/' ':root {}' > "${theme_source}/theme-future.css"
printf '%s\n' 'PRE-EXISTING FUTURE THEME' > "${THEMES_DIR}/theme-future.css"
begin_transaction "future-release" "$theme_source" >/dev/null
extend_uninstall_baseline "$theme_source" >/dev/null
commit_transaction
printf '%s\n' 'OVERWRITTEN FUTURE THEME' > "${THEMES_DIR}/theme-future.css"
restore_backup_internal "$backup_id" true false >/dev/null 2>&1
check 'baseline learns future destination names before first overwrite' 'PRE-EXISTING FUTURE THEME' "$(cat "${THEMES_DIR}/theme-future.css")"

printf '%s\n' 'MANUAL RESTORE CHANGE' > "$INDEX_TEMPLATE"
restore_backup "$backup_id" --yes >/dev/null 2>&1
check 'manual restore creates a safety transaction and succeeds' 0 "$?"
check 'manual restore restores its requested snapshot' 'ORIGINAL INDEX' "$(cat "$INDEX_TEMPLATE")"
check 'manual restore closes its transaction' false "$TRANSACTION_ACTIVE"

(
    begin_transaction "failure-test" "$theme_source" >/dev/null
    printf '%s\n' 'PARTIAL INSTALL' > "$INDEX_TEMPLATE"
    rollback_transaction 77 >/dev/null 2>&1
)
rollback_rc=$?
check 'failed transaction preserves the original exit status' 77 "$rollback_rc"
check 'failed transaction automatically restores changed files' 'ORIGINAL INDEX' "$(cat "$INDEX_TEMPLATE")"

# A same-package uninstall restores the clean baseline and retains all backups.
printf '%s\n' 'INSTALLED PROXMOXLIB' > "$PROXMOXLIB_JS"
printf '%s\n' 'INSTALLED INDEX' > "$INDEX_TEMPLATE"
mkdir -p "$JS_PATCHES_DIR" "$INSTALL_DIR"
printf '%s\n' 'installed patch' > "${JS_PATCHES_DIR}/installed.js"
printf '%s\n' 'installed theme' > "${THEMES_DIR}/theme-test.css"
printf '%s\n' "${THEMES_DIR}/theme-test.css" "$JS_PATCHES_DIR" > "$INSTALLED_PATHS_FILE"
printf '%s\n' '2.18.0' > "${INSTALL_DIR}/.version"
uninstall_themes --yes >/dev/null 2>&1
check 'uninstall succeeds from the clean baseline' 0 "$?"
check 'uninstall restores package-owned files' 'ORIGINAL PROXMOXLIB' "$(cat "$PROXMOXLIB_JS")"
check 'uninstall restores a pre-existing overwritten theme' 'ORIGINAL THEME' "$(cat "${THEMES_DIR}/theme-test.css")"
check 'uninstall removes the install cache' no "$([[ -e "$INSTALL_DIR" ]] && echo yes || echo no)"
check 'uninstall retains rollback backups' yes "$([[ -d "$(product_backup_dir)/${backup_id}" ]] && echo yes || echo no)"

create_backup "apt-repatch" "$theme_source" >/dev/null
clean_package_backup_id="$LAST_BACKUP_ID"
printf '%s\n' 'BROKEN CURRENT PACKAGE FILE' > "$INDEX_TEMPLATE"
mkdir -p "$CONFIG_DIR"
printf '%s\n' 'leave this non-package state alone' > "$DEFAULT_THEME_FILE"
check 'current clean package snapshot is discoverable' "$clean_package_backup_id" "$(find_current_clean_package_backup)"
restore_local_inventory "$(product_backup_dir)/${clean_package_backup_id}" package >/dev/null 2>&1
check 'package-only restore repairs package files' 'ORIGINAL INDEX' "$(cat "$INDEX_TEMPLATE")"
check 'package-only restore leaves non-package state untouched' 'leave this non-package state alone' "$(cat "$DEFAULT_THEME_FILE")"
rm -rf "$CONFIG_DIR"

create_backup "tamper-test" "$theme_source" >/dev/null
tampered_dir="$(product_backup_dir)/${LAST_BACKUP_ID}"
printf '%s\n' 'TAMPERED' > "${tampered_dir}/rootfs${PROXMOXLIB_JS}"
verify_backup "$tampered_dir" >/dev/null 2>&1
check 'tampered backup is rejected' 1 "$?"

original_version_function=$(declare -f get_installed_package_version)
get_installed_package_version() { printf '%s' 'different-version'; }
verify_backup_package_versions "$backup_dir" >/dev/null 2>&1
check 'package-version mismatch is rejected' 1 "$?"
eval "$original_version_function"

# PDM uses a different index and owns entire theme/patch directories.
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
pdm_source="${work}/pdm-release/themes/pdm"
mkdir -p "$(dirname "$INDEX_TEMPLATE")" "$pdm_source"
printf '%s\n' 'ORIGINAL PDM INDEX' > "$INDEX_TEMPLATE"
printf '%s\n' '/*!PDM Test*/' ':root {}' > "${pdm_source}/theme-pdm-test.css"

create_backup "pdm-install" "$pdm_source" >/dev/null
pdm_backup_id="$LAST_BACKUP_ID"
printf '%s\n' 'CHANGED PDM INDEX' > "$INDEX_TEMPLATE"
mkdir -p "$PDM_THEMES_DIR" "$PDM_JS_PATCHES_DIR"
printf '%s\n' 'new PDM theme' > "${PDM_THEMES_DIR}/theme-pdm-test.css"
printf '%s\n' 'new PDM patch' > "${PDM_JS_PATCHES_DIR}/selector.js"
restore_backup_internal "$pdm_backup_id" true false >/dev/null 2>&1
check 'PDM restore succeeds' 0 "$?"
check 'PDM index is restored byte-for-byte' 'ORIGINAL PDM INDEX' "$(cat "$INDEX_TEMPLATE")"
check 'new PDM themes directory is removed' no "$([[ -e "$PDM_THEMES_DIR" ]] && echo yes || echo no)"
check 'new PDM patch directory is removed' no "$([[ -e "$PDM_JS_PATCHES_DIR" ]] && echo yes || echo no)"

if [[ "$fail" -eq 0 ]]; then
    echo 'ALL PASS'
else
    echo 'FAILURES PRESENT'
fi
exit "$fail"
