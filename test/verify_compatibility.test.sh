#!/usr/bin/env bash
# Source-level contract tests for the capability preflight in install.sh.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../install.sh
source "${HERE}/../install.sh" >/dev/null 2>&1
set +e

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

PROXMOXLIB_JS="${work}/proxmoxlib.js"
INDEX_TEMPLATE="${work}/index.html.tpl"
NODES_PM="${work}/Nodes.pm"
PVE_MANAGER_JS="${work}/pvemanagerlib.js"
PRODUCT="PVE"

printf '%s\n' 'Proxmox.Utils = { theme_map: {' > "$PROXMOXLIB_JS"
printf '%s\n' '<script src="/pve2/js/pvemanagerlib.js"></script>' '</head>' '</body>' > "$INDEX_TEMPLATE"
printf '%s\n' '        my $dinfo = df('\''/'\'', 1);' > "$NODES_PM"
printf '%s\n' "Ext.define('PVE.form.ViewSelector');" "Ext.define('PVE.tree.ResourceTree');" "Ext.define('PVE.node.StatusView');" > "$PVE_MANAGER_JS"

fail=0
check() {
    if [[ "$2" == "$3" ]]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1 (expected rc=$2, got rc=$3)"
        fail=1
    fi
}

validate_runtime_contracts >/dev/null 2>&1
check 'Proxmox 9.2.6 source contracts pass' 0 "$?"

printf '%s\n' 'Proxmox.Utils = {};' > "$PROXMOXLIB_JS"
validate_runtime_contracts >/dev/null 2>&1
check 'missing theme map fails closed' 1 "$?"

printf '%s\n' 'Proxmox.Utils = { theme_map: {' > "$PROXMOXLIB_JS"
printf '%s\n' '<script src="/pve2/js/pvemanagerlib.js"></script>' '</head>' > "$INDEX_TEMPLATE"
validate_runtime_contracts >/dev/null 2>&1
check 'missing index insertion point fails closed' 1 "$?"

printf '%s\n' '<script src="/pve2/js/pvemanagerlib.js"></script>' '</head>' '</body>' > "$INDEX_TEMPLATE"
printf '%s\n' 'my $dinfo = df('\''/'\'', 1);' 'my $dinfo = df('\''/'\'', 1);' > "$NODES_PM"
validate_runtime_contracts >/dev/null 2>&1
check 'ambiguous sensor insertion point fails closed' 1 "$?"

printf '%s\n' 'my $dinfo = df('\''/'\'', 1);' > "$NODES_PM"
printf '%s\n' "Ext.define('PVE.form.ViewSelector');" "Ext.define('PVE.node.StatusView');" > "$PVE_MANAGER_JS"
validate_runtime_contracts >/dev/null 2>&1
check 'missing inventory extension point fails closed' 1 "$?"

printf '%s\n' "Ext.define('PVE.form.ViewSelector');" "Ext.define('PVE.tree.ResourceTree');" "Ext.define('PVE.node.StatusView');" > "$PVE_MANAGER_JS"
INSTALL_DIR="${work}/install"
POST_INVOKE_SCRIPT="${work}/post-update.sh"
APT_HOOK_FILE="${work}/99proxmorph"
JS_PATCHES_DIR="${work}/js/proxmorph"
PROXY_SERVICE='pveproxy'
THEME_COOKIE='PVEThemeCookie'
THEME_WEB_PATH='/pwt/themes'
install_apt_hook >/dev/null 2>&1
bash -n "$POST_INVOKE_SCRIPT"
check 'generated update hook is valid shell' 0 "$?"
grep -qF '\$dinfo = df' "$POST_INVOKE_SCRIPT"
check 'generated update hook preserves the sensor anchor' 0 "$?"

if [[ "$fail" -eq 0 ]]; then
    echo 'ALL PASS'
else
    echo 'FAILURES PRESENT'
fi
exit "$fail"
