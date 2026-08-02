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
PVE_CLUSTER_PM="${work}/Cluster.pm"
PVE_API2_PM="${work}/API2.pm"
PVE_PROXMORPH_API_PM="${work}/ProxMorph.pm"
PVE_PREFERENCES_FILE="${work}/proxmorph-user-preferences.json"
PRODUCT="PVE"

printf '%s\n' 'Proxmox.Utils = { theme_map: {' > "$PROXMOXLIB_JS"
printf '%s\n' '<script src="/pve2/js/pvemanagerlib.js"></script>' '</head>' '</body>' > "$INDEX_TEMPLATE"
printf '%s\n' '        my $dinfo = df('\''/'\'', 1);' > "$NODES_PM"
printf '%s\n' "Ext.define('PVE.form.ViewSelector');" "Ext.define('PVE.tree.ResourceTree');" "Ext.define('PVE.node.StatusView');" > "$PVE_MANAGER_JS"
printf '%s\n' 'my $observed = {' '};' > "$PVE_CLUSTER_PM"
printf '%s\n' 'package PVE::API2;' 'use base qw(PVE::RESTHandler);' '1;' > "$PVE_API2_PM"

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
printf '%s\n' 'my $observed = {' 'my $observed = {' > "$PVE_CLUSTER_PM"
validate_runtime_contracts >/dev/null 2>&1
check 'ambiguous cluster preference anchor fails closed' 1 "$?"

printf '%s\n' 'my $observed = {' '};' > "$PVE_CLUSTER_PM"
printf '%s\n' 'package PVE::API2;' '1;' > "$PVE_API2_PM"
validate_runtime_contracts >/dev/null 2>&1
check 'missing authenticated API anchor fails closed' 1 "$?"

printf '%s\n' 'package PVE::API2;' 'use base qw(PVE::RESTHandler);' '1;' > "$PVE_API2_PM"
INSTALL_DIR="${work}/install"
INSTALLED_PATHS_FILE="${INSTALL_DIR}/.installed-paths"
POST_INVOKE_SCRIPT="${work}/post-update.sh"
APT_HOOK_FILE="${work}/99proxmorph"
JS_PATCHES_DIR="${work}/js/proxmorph"
PROXY_SERVICE='pveproxy'
THEME_COOKIE='PVEThemeCookie'
THEME_WEB_PATH='/pwt/themes'
perl() { return 0; }
install_pve_preferences_api >/dev/null 2>&1
check 'authenticated preferences API patches clean PVE fixtures' 0 "$?"
install_pve_preferences_api >/dev/null 2>&1
check 'authenticated preferences API patch is idempotent' 0 "$?"
unset -f perl
check 'cluster preferences registration is singular' 1 "$(grep -cF "$PVE_CLUSTER_PREFS_MARKER" "$PVE_CLUSTER_PM")"
check 'API route registration is singular' 1 "$(grep -cF "$PVE_API_PREFS_MARKER" "$PVE_API2_PM")"
grep -qF "path => 'proxmorph'," "$PVE_API2_PM"
check 'API route patch preserves its Perl string quoting' 0 "$?"
install_apt_hook >/dev/null 2>&1
bash -n "$POST_INVOKE_SCRIPT"
check 'generated update hook is valid shell' 0 "$?"
grep -qF '\$dinfo = df' "$POST_INVOKE_SCRIPT"
check 'generated update hook preserves the sensor anchor' 0 "$?"
grep -qF 'backup "apt-repatch"' "$POST_INVOKE_SCRIPT"
check 'generated update hook snapshots clean package files before re-patching' 0 "$?"
grep -qF 'restore "$transaction_backup_id" --yes --force' "$POST_INVOKE_SCRIPT"
check 'generated update hook has automatic rollback' 0 "$?"
grep -qF 'reapply-preferences-api' "$POST_INVOKE_SCRIPT"
check 'generated update hook restores the authenticated preferences API' 0 "$?"
grep -qF "grep -cF 'my \$observed = {'" "$POST_INVOKE_SCRIPT"
check 'generated update hook preserves the cluster-module anchor literally' 0 "$?"
grep -qF 'systemctl restart pvedaemon "$PROXY_SERVICE"' "$POST_INVOKE_SCRIPT"
check 'generated update hook reloads the protected API daemon' 0 "$?"

if [[ "$fail" -eq 0 ]]; then
    echo 'ALL PASS'
else
    echo 'FAILURES PRESENT'
fi
exit "$fail"
