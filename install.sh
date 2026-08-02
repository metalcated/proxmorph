#!/bin/bash
# ProxMorph Theme Collection Installer for Proxmox VE, Proxmox Backup Server, and Proxmox Datacenter Manager
# Supports: PVE 8.x/9.x, PBS 3.x/4.x, PDM 1.x
# Integrates with native Proxmox theme selector

set -Ee

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Configuration
VERSION="2.19.1"
TARGET_VERSION="$VERSION"
WIDGET_TOOLKIT_DIR="/usr/share/javascript/proxmox-widget-toolkit"
THEMES_DIR="${WIDGET_TOOLKIT_DIR}/themes"
PROXMOXLIB_JS="${WIDGET_TOOLKIT_DIR}/proxmoxlib.js"
BACKUP_DIR="/root/.proxmorph-backup" # Legacy pre-v2.10 backup location
BACKUP_ROOT="${PROXMORPH_BACKUP_ROOT:-/root/.proxmorph-backups}"
BACKUP_SCHEMA_VERSION="1"
GITHUB_REPO="IT-BAER/proxmorph"
INSTALL_DIR="/opt/proxmorph"
INSTALLED_PATHS_FILE="${INSTALL_DIR}/.installed-paths"
CONFIG_DIR="${PROXMORPH_CONFIG_DIR:-/etc/proxmorph}"
PROXMORPH_LOG_FILE="${PROXMORPH_LOG_FILE:-/var/log/proxmorph.log}"
LOCK_FILE="${PROXMORPH_LOCK_FILE:-/run/lock/proxmorph.lock}"

# Sensor support paths
SENSORS_CONFIG="${INSTALL_DIR}/.sensors-enabled"
SENSORS_FILTER="${INSTALL_DIR}/.sensors-filter"
SENSORS_PACKAGE_MARKER="${INSTALL_DIR}/.lm-sensors-installed-by-proxmorph"
NODES_PM="/usr/share/perl5/PVE/API2/Nodes.pm"
SENSORS_PATCH_MARKER="# ProxMorph Sensors"

# PVE-specific paths
PVE_MANAGER_DIR="/usr/share/pve-manager"
PVE_INDEX_TPL="${PVE_MANAGER_DIR}/index.html.tpl"
PVE_MANAGER_JS="${PVE_MANAGER_DIR}/js/pvemanagerlib.js"
PVE_JS_PATCHES_DIR="${PVE_MANAGER_DIR}/js/proxmorph"
PVE_SERVICE="pveproxy"
PVE_CLUSTER_PM="/usr/share/perl5/PVE/Cluster.pm"
PVE_API2_PM="/usr/share/perl5/PVE/API2.pm"
PVE_PROXMORPH_API_PM="/usr/share/perl5/PVE/API2/ProxMorph.pm"
PVE_PREFERENCES_FILE="/etc/pve/priv/proxmorph-user-preferences.json"
PVE_API_SERVICE="pvedaemon"
PVE_PREFERENCES_SOURCE_RELATIVE="server/PVE/API2/ProxMorph.pm"
PVE_CLUSTER_PREFS_MARKER="# ProxMorph User Preferences BEGIN"
PVE_CLUSTER_PREFS_MARKER_END="# ProxMorph User Preferences END"
PVE_API_PREFS_MARKER="# ProxMorph Preferences API BEGIN"
PVE_API_PREFS_MARKER_END="# ProxMorph Preferences API END"

# Proxmox noVNC clipboard enhancement paths (PVE implementation)
NOVNC_DIR="/usr/share/novnc-pve"
NOVNC_INDEX_TPL="${NOVNC_DIR}/index.html.tpl"
NOVNC_PROXMORPH_DIR="${NOVNC_DIR}/proxmorph"

# PBS-specific paths
PBS_MANAGER_DIR="/usr/share/javascript/proxmox-backup"
PBS_INDEX_HBS="${PBS_MANAGER_DIR}/index.hbs"
PBS_JS_PATCHES_DIR="${PBS_MANAGER_DIR}/js/proxmorph"
PBS_SERVICE="proxmox-backup-proxy"

# PDM-specific paths (Proxmox Datacenter Manager)
PDM_MANAGER_DIR="/usr/share/javascript/proxmox-datacenter-manager"
PDM_INDEX_HBS="${PDM_MANAGER_DIR}/index.hbs"
PDM_JS_PATCHES_DIR="${PDM_MANAGER_DIR}/js/proxmorph"
PDM_THEMES_DIR="${PDM_MANAGER_DIR}/proxmorph-themes"
PDM_SERVICE="proxmox-datacenter-api"

# Product detection (set by check_product)
PRODUCT=""
PRODUCT_VERSION=""
INDEX_TEMPLATE=""
JS_PATCHES_DIR=""
PROXY_SERVICE=""

# Active mutation transaction. A failed install/update/reinstall/uninstall or
# sensor change restores this snapshot automatically before exiting.
TRANSACTION_BACKUP_ID=""
TRANSACTION_ACTIVE=false
TRANSACTION_ROLLING_BACK=false
LAST_BACKUP_ID=""
RELEASE_DOWNLOADED=false
DRY_RUN=false

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║   ProxMorph Theme Collection for Proxmox VE, PBS & PDM   ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Function to print colored messages
print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }
print_theme() { echo -e "${MAGENTA}[T]${NC} $1"; }

restart_proxmorph_services() {
    local background="${1:-false}"
    local services=()
    [[ -n "$PROXY_SERVICE" ]] || return 0
    [[ "$PRODUCT" == "PVE" ]] && services+=("$PVE_API_SERVICE")
    services+=("$PROXY_SERVICE")

    if [[ "$background" == "true" ]]; then
        nohup systemctl restart "${services[@]}" &>/dev/null &
    else
        systemctl restart "${services[@]}"
    fi
}

preview_service_restarts() {
    [[ "$PRODUCT" == "PVE" ]] && printf '  [restart] %s\n' "$PVE_API_SERVICE"
    printf '  [restart] %s\n' "$PROXY_SERVICE"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

acquire_operation_lock() {
    [[ "${PROXMORPH_SKIP_LOCK:-false}" == "true" ]] && return 0
    command -v flock &>/dev/null || {
        print_error "flock is required to protect backup and restore operations"
        return 1
    }
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    flock -n 9 || {
        print_error "Another ProxMorph operation is already running"
        return 1
    }
}

# Check if Proxmox VE is installed
check_pve() {
    if command -v pveversion &> /dev/null; then
        PRODUCT="PVE"
        PRODUCT_VERSION=$(pveversion | head -1)
        INDEX_TEMPLATE="$PVE_INDEX_TPL"
        JS_PATCHES_DIR="$PVE_JS_PATCHES_DIR"
        PROXY_SERVICE="$PVE_SERVICE"
        return 0
    fi
    return 1
}

# Check if Proxmox Backup Server is installed
check_pbs() {
    if command -v proxmox-backup-manager &> /dev/null; then
        PRODUCT="PBS"
        PRODUCT_VERSION=$(proxmox-backup-manager version 2>/dev/null | head -1)
        INDEX_TEMPLATE="$PBS_INDEX_HBS"
        JS_PATCHES_DIR="$PBS_JS_PATCHES_DIR"
        PROXY_SERVICE="$PBS_SERVICE"
        return 0
    fi
    return 1
}

# Check if Proxmox Datacenter Manager is installed
check_pdm() {
    if command -v proxmox-datacenter-manager &> /dev/null || \
       dpkg -l proxmox-datacenter-manager-ui &> /dev/null; then
        PRODUCT="PDM"
        PRODUCT_VERSION=$(dpkg -l proxmox-datacenter-manager 2>/dev/null | awk '/^ii/{print "PDM " $3}' || echo "PDM (unknown version)")
        INDEX_TEMPLATE="$PDM_INDEX_HBS"
        JS_PATCHES_DIR="$PDM_JS_PATCHES_DIR"
        PROXY_SERVICE="$PDM_SERVICE"
        THEMES_DIR="$PDM_THEMES_DIR"
        return 0
    fi
    return 1
}

# Detect which Proxmox product is installed
check_product() {
    if check_pve; then
        print_info "Detected: $PRODUCT_VERSION"
    elif check_pbs; then
        print_info "Detected: $PRODUCT_VERSION"
    elif check_pdm; then
        print_info "Detected: $PRODUCT_VERSION"
    else
        print_error "No supported Proxmox product detected."
        print_error "This script requires PVE 8.x/9.x, PBS 3.x/4.x, or PDM 1.x."
        exit 1
    fi

    # Theme cookie + web path for server-side default theme injection
    case "$PRODUCT" in
        PVE) THEME_COOKIE="PVEThemeCookie"; THEME_WEB_PATH="/pwt/themes" ;;
        PBS) THEME_COOKIE="PBSThemeCookie"; THEME_WEB_PATH="/widgettoolkit/themes" ;;
        *)   THEME_COOKIE=""; THEME_WEB_PATH="" ;;
    esac
}

# Validate the installed product by the files and source-level extension points
# ProxMorph actually patches. This is intentionally capability-based so future
# package versions can proceed when their layout remains compatible, while a
# changed contract fails before any package-owned file is edited.
validate_runtime_contracts() {
    local errors=0
    local package_version=""

    print_info "Checking ${PRODUCT} runtime compatibility..."

    case "$PRODUCT" in
        PVE)
            package_version=$(dpkg-query -W -f='${Version}' pve-manager 2>/dev/null || true)
            if [[ -n "$package_version" ]] && dpkg --compare-versions "$package_version" lt "8"; then
                print_error "Unsupported pve-manager version: ${package_version} (requires 8.x or newer)"
                errors=$((errors + 1))
            elif [[ -n "$package_version" ]] && dpkg --compare-versions "$package_version" ge "9.2.6"; then
                print_status "pve-manager ${package_version} is in the Proxmox 9.2.6+ compatibility range"
            elif [[ -n "$package_version" ]]; then
                print_info "pve-manager ${package_version} uses the legacy supported range; validating contracts"
            fi
            ;;
        PBS)
            package_version=$(dpkg-query -W -f='${Version}' proxmox-backup-server 2>/dev/null || true)
            ;;
        PDM)
            package_version=$(dpkg-query -W -f='${Version}' proxmox-datacenter-manager-ui 2>/dev/null || true)
            ;;
    esac

    if [[ ! -f "$INDEX_TEMPLATE" ]]; then
        print_error "Required index template not found: ${INDEX_TEMPLATE}"
        errors=$((errors + 1))
    else
        if ! grep -q '</head>' "$INDEX_TEMPLATE"; then
            print_error "Index template has no </head> insertion point: ${INDEX_TEMPLATE}"
            errors=$((errors + 1))
        fi
        if [[ "$PRODUCT" != "PDM" ]] && ! grep -q '</body>' "$INDEX_TEMPLATE"; then
            print_error "Index template has no </body> insertion point: ${INDEX_TEMPLATE}"
            errors=$((errors + 1))
        fi
    fi

    if [[ "$PRODUCT" != "PDM" ]]; then
        if [[ ! -f "$PROXMOXLIB_JS" ]]; then
            print_error "Required widget toolkit file not found: ${PROXMOXLIB_JS}"
            errors=$((errors + 1))
        else
            local theme_anchor_count
            theme_anchor_count=$(grep -cF 'theme_map: {' "$PROXMOXLIB_JS" 2>/dev/null || true)
            if [[ "$theme_anchor_count" -ne 1 ]]; then
                print_error "Expected one theme_map anchor in ${PROXMOXLIB_JS}; found ${theme_anchor_count}"
                errors=$((errors + 1))
            fi
        fi
    fi

    if [[ "$PRODUCT" == "PVE" ]]; then
        if ! grep -q '/pve2/js/pvemanagerlib.js' "$INDEX_TEMPLATE" 2>/dev/null; then
            print_error "PVE manager JavaScript loader was not found in ${INDEX_TEMPLATE}"
            errors=$((errors + 1))
        fi
        if [[ ! -f "$PVE_MANAGER_JS" ]]; then
            print_error "PVE manager JavaScript bundle not found: ${PVE_MANAGER_JS}"
            errors=$((errors + 1))
        else
            local pve_ui_contract
            for pve_ui_contract in 'PVE.form.ViewSelector' 'PVE.tree.ResourceTree' 'PVE.node.StatusView' 'PVE.panel.Config' 'PVE.sdn.VnetEdit' 'PVE.sdn.SubnetView' 'PVE.sdn.VnetACLView' 'PVE.dc.CmdMenu' 'PVE.node.CmdMenu'; do
                if ! grep -qF "$pve_ui_contract" "$PVE_MANAGER_JS"; then
                    print_error "Required PVE UI extension point not found: ${pve_ui_contract}"
                    errors=$((errors + 1))
                fi
            done
        fi
        if [[ ! -f "$NODES_PM" ]]; then
            print_error "PVE node API file not found: ${NODES_PM}"
            errors=$((errors + 1))
        else
            local sensor_anchor_count
            sensor_anchor_count=$(grep -cE '^[[:space:]]*my \$dinfo = df' "$NODES_PM" 2>/dev/null || true)
            if [[ "$sensor_anchor_count" -ne 1 ]]; then
                print_error "Expected one sensor insertion anchor in ${NODES_PM}; found ${sensor_anchor_count}"
                errors=$((errors + 1))
            fi
        fi
        if [[ ! -f "$PVE_CLUSTER_PM" ]]; then
            print_error "PVE cluster module not found: ${PVE_CLUSTER_PM}"
            errors=$((errors + 1))
        else
            local cluster_preferences_anchor_count
            cluster_preferences_anchor_count=$(grep -cF 'my $observed = {' "$PVE_CLUSTER_PM" 2>/dev/null || true)
            if [[ "$cluster_preferences_anchor_count" -ne 1 ]]; then
                print_error "Expected one cluster preferences anchor in ${PVE_CLUSTER_PM}; found ${cluster_preferences_anchor_count}"
                errors=$((errors + 1))
            fi
        fi
        if [[ ! -f "$PVE_API2_PM" ]]; then
            print_error "PVE API root module not found: ${PVE_API2_PM}"
            errors=$((errors + 1))
        else
            local preferences_api_anchor_count
            preferences_api_anchor_count=$(grep -cF 'use base qw(PVE::RESTHandler);' "$PVE_API2_PM" 2>/dev/null || true)
            if [[ "$preferences_api_anchor_count" -ne 1 ]]; then
                print_error "Expected one preferences API anchor in ${PVE_API2_PM}; found ${preferences_api_anchor_count}"
                errors=$((errors + 1))
            fi
        fi
        if [[ ! -f "$NOVNC_INDEX_TPL" ]]; then
            print_error "Proxmox noVNC template not found: ${NOVNC_INDEX_TPL}"
            errors=$((errors + 1))
        else
            local novnc_app_anchor_count
            local novnc_clipboard_anchor_count
            novnc_app_anchor_count=$(grep -cF 'import UI from "/novnc/app.js' "$NOVNC_INDEX_TPL" 2>/dev/null || true)
            novnc_clipboard_anchor_count=$(grep -cF 'id="noVNC_clipboard_button"' "$NOVNC_INDEX_TPL" 2>/dev/null || true)
            if [[ "$novnc_app_anchor_count" -ne 1 ]]; then
                print_error "Expected one noVNC application module anchor in ${NOVNC_INDEX_TPL}; found ${novnc_app_anchor_count}"
                errors=$((errors + 1))
            fi
            if [[ "$novnc_clipboard_anchor_count" -ne 1 ]]; then
                print_error "Expected one native noVNC clipboard control in ${NOVNC_INDEX_TPL}; found ${novnc_clipboard_anchor_count}"
                errors=$((errors + 1))
            fi
            if ! grep -q '</head>' "$NOVNC_INDEX_TPL"; then
                print_error "noVNC template has no </head> insertion point: ${NOVNC_INDEX_TPL}"
                errors=$((errors + 1))
            fi
        fi
    fi

    if [[ "$errors" -ne 0 ]]; then
        print_error "Compatibility check failed; no Proxmox files were changed"
        return 1
    fi

    print_status "Runtime file contracts are compatible${package_version:+ (${package_version})}"
    return 0
}

# Get latest release version from GitHub
get_latest_version() {
    curl -s "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | \
        grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/'
}

# Verify downloaded artifacts against a SHA256SUMS manifest.
# Args: $1 = directory containing the artifact(s) and the sums file,
#       $2 = sums filename (default SHA256SUMS).
# Returns 0 only if every present file listed in the manifest matches. Files in
# the manifest that are absent locally are ignored (we do not download the .zip);
# if NOTHING could be verified (e.g. the artifact is not listed at all), sha256sum
# exits non-zero, so this fails closed.
verify_checksum() {
    local dir="$1"
    local sums="${2:-SHA256SUMS}"

    [[ -f "${dir}/${sums}" ]] || return 1

    local line=""
    local candidate=""
    local listed_present=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:xdigit:]]{64}[[:space:]][\ \*](.+)$ ]]; then
            candidate="${BASH_REMATCH[1]}"
            case "$candidate" in
                /*|../*|*/../*|*/..) return 1 ;;
            esac
            if [[ -f "${dir}/${candidate}" ]]; then
                listed_present=true
            fi
        fi
    done < "${dir}/${sums}"

    [[ "$listed_present" == "true" ]] || return 1
    ( cd "$dir" && sha256sum --ignore-missing -c "$sums" )
}

# Download, verify, and extract a release.
# Source defaults to GitHub releases; set PROXMORPH_RELEASE_BASE to the directory
# that directly contains proxmorph-<ver>.tar.gz and SHA256SUMS to install from an
# internal mirror (or a local test server) instead.
download_release() {
    local version="${1:-$(get_latest_version)}"

    if [[ -z "$version" ]]; then
        print_error "Could not determine latest version"
        return 1
    fi

    print_info "Downloading ProxMorph v${version}..."

    local base="${PROXMORPH_RELEASE_BASE:-https://github.com/${GITHUB_REPO}/releases/download/v${version}}"
    local archive="proxmorph-${version}.tar.gz"
    local tmp_dir=$(mktemp -d)

    if ! curl -fsSL "${base}/${archive}" -o "${tmp_dir}/${archive}"; then
        print_error "Failed to download release v${version} from ${base}"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Fetch the checksum manifest. Absence is fatal: without it we cannot verify
    # what we just downloaded, and a soft-fail would defeat the purpose (anyone who
    # can swap the tarball can also drop the sums response).
    if ! curl -fsSL "${base}/SHA256SUMS" -o "${tmp_dir}/SHA256SUMS"; then
        print_error "Could not fetch SHA256SUMS for v${version} from ${base}"
        print_error "Refusing to install an unverifiable release. See README 'Verify before you run'."
        rm -rf "$tmp_dir"
        return 1
    fi

    print_info "Verifying checksum..."
    if ! verify_checksum "$tmp_dir" SHA256SUMS; then
        print_error "CHECKSUM VERIFICATION FAILED for ${archive}"
        print_error "The downloaded release does not match its published SHA256SUMS. Aborting."
        rm -rf "$tmp_dir"
        return 1
    fi
    print_status "Checksum verified"

    # Extract to install directory
    mkdir -p "$INSTALL_DIR"
    rm -rf "${INSTALL_DIR:?}"/*
    tar -xzf "${tmp_dir}/${archive}" -C "$INSTALL_DIR"
    rm -rf "$tmp_dir"

    # Save version info
    echo "$version" > "${INSTALL_DIR}/.version"
    TARGET_VERSION="$version"
    RELEASE_DOWNLOADED=true

    print_status "Downloaded ProxMorph v${version}"
}

# Check for updates
check_updates() {
    local current_version=""
    if [[ -f "${INSTALL_DIR}/.version" ]]; then
        current_version=$(cat "${INSTALL_DIR}/.version")
    fi
    
    local latest_version=$(get_latest_version)
    
    if [[ -z "$latest_version" ]]; then
        print_warning "Could not check for updates (no internet?)"
        return 1
    fi
    
    if [[ "$current_version" == "$latest_version" ]]; then
        print_status "Already on latest version (v${current_version})"
        return 0
    elif [[ -n "$current_version" ]]; then
        print_info "Update available: v${current_version} → v${latest_version}"
        return 2
    else
        print_info "Latest version: v${latest_version}"
        return 2
    fi
}

# ─── Versioned Backup and Transactional Restore ─────────────────

product_backup_dir() {
    printf '%s/%s' "$BACKUP_ROOT" "$(printf '%s' "$PRODUCT" | tr '[:upper:]' '[:lower:]')"
}

path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

proxmorph_install_detected() {
    local themes_source="${1:-}"
    local css_file=""
    local theme_key=""
    [[ -f "$APT_HOOK_FILE" || -f "${INSTALL_DIR}/.version" ]] && return 0
    [[ -f "$INDEX_TEMPLATE" ]] && grep -q 'ProxMorph' "$INDEX_TEMPLATE" 2>/dev/null && return 0
    if [[ "$PRODUCT" != "PDM" && -f "$PROXMOXLIB_JS" && -d "$themes_source" ]]; then
        for css_file in "$themes_source"/theme-*.css; do
            [[ -f "$css_file" ]] || continue
            theme_key=$(basename "$css_file" .css)
            theme_key=${theme_key#theme-}
            grep -qF "\"${theme_key}\":" "$PROXMOXLIB_JS" 2>/dev/null && return 0
        done
    fi
    return 1
}

get_product_package_names() {
    case "$PRODUCT" in
        PVE) printf '%s\n' pve-manager pve-cluster proxmox-widget-toolkit novnc-pve ;;
        PBS) printf '%s\n' proxmox-backup-server proxmox-widget-toolkit ;;
        PDM) printf '%s\n' proxmox-datacenter-manager proxmox-datacenter-manager-ui ;;
    esac
}

get_installed_package_version() {
    local package="$1"
    local version=""
    if command -v dpkg-query &>/dev/null; then
        version=$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true)
    fi
    printf '%s' "${version:-ABSENT}"
}

capture_package_versions() {
    local output="$1"
    local package=""
    : > "$output"
    while IFS= read -r package; do
        [[ -n "$package" ]] || continue
        printf '%s\t%s\n' "$package" "$(get_installed_package_version "$package")" >> "$output"
    done < <(get_product_package_names)
}

package_is_installed() {
    local package="$1"
    local status=""
    if command -v dpkg-query &>/dev/null; then
        status=$(dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null || true)
    fi
    [[ "$status" == ii* ]]
}

capture_optional_package_state() {
    local output="$1"
    : > "$output"
    [[ "$PRODUCT" == "PVE" ]] || return 0
    if package_is_installed lm-sensors; then
        printf 'lm-sensors\tpresent\n' >> "$output"
    else
        printf 'lm-sensors\tabsent\n' >> "$output"
    fi
}

write_backup_pointer() {
    local pointer="$1"
    local backup_id="$2"
    local temporary="${pointer}.tmp.$$"
    printf '%s\n' "$backup_id" > "$temporary"
    mv "$temporary" "$pointer"
}

add_backup_candidate() {
    local candidate="$1"
    local existing=""
    [[ "$candidate" == /* ]] || return 1
    [[ "$candidate" != *$'\n'* && "$candidate" != *$'\t'* ]] || return 1
    for existing in "${BACKUP_CANDIDATES[@]:-}"; do
        [[ "$existing" == "$candidate" ]] && return 0
    done
    BACKUP_CANDIDATES+=("$candidate")
}

collect_backup_candidates() {
    local themes_source="${1:-}"
    local source_dir=""
    local css_file=""
    local recorded_path=""
    BACKUP_CANDIDATES=()

    add_backup_candidate "$INDEX_TEMPLATE"
    add_backup_candidate "$INSTALL_DIR"
    add_backup_candidate "$APT_HOOK_FILE"
    add_backup_candidate "$CONFIG_DIR"
    add_backup_candidate "$PROXMORPH_LOG_FILE"

    if [[ "$PRODUCT" == "PDM" ]]; then
        add_backup_candidate "$PDM_THEMES_DIR"
        add_backup_candidate "$PDM_JS_PATCHES_DIR"
    else
        add_backup_candidate "$PROXMOXLIB_JS"
        add_backup_candidate "$JS_PATCHES_DIR"
    fi
    if [[ "$PRODUCT" == "PVE" ]]; then
        add_backup_candidate "$NODES_PM"
        add_backup_candidate "$PVE_CLUSTER_PM"
        add_backup_candidate "$PVE_API2_PM"
        add_backup_candidate "$PVE_PROXMORPH_API_PM"
        add_backup_candidate "$PVE_PREFERENCES_FILE"
        add_backup_candidate "$NOVNC_INDEX_TPL"
        add_backup_candidate "$NOVNC_PROXMORPH_DIR"
    fi

    # Preserve every live theme file that the current or incoming release owns,
    # without copying the package's entire stock theme directory.
    for source_dir in "$themes_source" "${INSTALL_DIR}/themes"; do
        [[ -n "$source_dir" && -d "$source_dir" ]] || continue
        if [[ "$PRODUCT" == "PDM" ]]; then
            continue
        fi
        for css_file in "$source_dir"/theme-*.css; do
            [[ -f "$css_file" ]] || continue
            add_backup_candidate "${THEMES_DIR}/$(basename "$css_file")"
        done
    done

    # The installed-path ledger carries destination names forward when a later
    # release removes or renames an asset.
    if [[ -f "$INSTALLED_PATHS_FILE" ]]; then
        while IFS= read -r recorded_path; do
            [[ -n "$recorded_path" ]] || continue
            if backup_path_is_allowed "$recorded_path"; then
                add_backup_candidate "$recorded_path"
            fi
        done < "$INSTALLED_PATHS_FILE"
    fi
}

backup_path_is_allowed() {
    local path="$1"
    case "$path" in
        "$INDEX_TEMPLATE"|"$INSTALL_DIR"|"$APT_HOOK_FILE"|"$CONFIG_DIR"|"$PROXMORPH_LOG_FILE") return 0 ;;
        "$PROXMOXLIB_JS") [[ "$PRODUCT" == "PVE" || "$PRODUCT" == "PBS" ]] && return 0 ;;
        "$JS_PATCHES_DIR") return 0 ;;
        "$NODES_PM") [[ "$PRODUCT" == "PVE" ]] && return 0 ;;
        "$PVE_CLUSTER_PM"|"$PVE_API2_PM"|"$PVE_PROXMORPH_API_PM"|"$PVE_PREFERENCES_FILE")
            [[ "$PRODUCT" == "PVE" ]] && return 0
            ;;
        "$NOVNC_INDEX_TPL"|"$NOVNC_PROXMORPH_DIR") [[ "$PRODUCT" == "PVE" ]] && return 0 ;;
        "$PDM_THEMES_DIR"|"$PDM_JS_PATCHES_DIR") [[ "$PRODUCT" == "PDM" ]] && return 0 ;;
        "$THEMES_DIR"/theme-*.css)
            [[ "$(dirname "$path")" == "$THEMES_DIR" ]] && return 0
            ;;
    esac
    return 1
}

regenerate_backup_checksums() {
    local backup_dir="$1"
    local checksum_file="${backup_dir}/SHA256SUMS"
    local relative=""
    (
        cd "$backup_dir"
        : > "${checksum_file}.tmp"
        for relative in metadata.env inventory.tsv package-versions.tsv optional-packages.tsv remote-inventory.tsv; do
            [[ -f "$relative" ]] && sha256sum "$relative" >> "${checksum_file}.tmp"
        done
        while IFS= read -r -d '' relative; do
            sha256sum "$relative" >> "${checksum_file}.tmp"
        done < <(find rootfs remote -type f -print0 2>/dev/null | sort -z)
        sort -k2 "${checksum_file}.tmp" > "${checksum_file}.new"
        mv "${checksum_file}.new" "$checksum_file"
        rm -f "${checksum_file}.tmp"
    )
}

create_backup() {
    local reason="${1:-manual}"
    local themes_source="${2:-}"
    local product_dir=""
    local backup_id=""
    local backup_dir=""
    local path=""
    local state=""
    local had_install=false

    proxmorph_install_detected "$themes_source" && had_install=true
    product_dir=$(product_backup_dir)
    backup_id="$(date -u '+%Y%m%dT%H%M%SZ')-$(printf '%s' "$PRODUCT" | tr '[:upper:]' '[:lower:]')-$$-${RANDOM}"
    backup_dir="${product_dir}/${backup_id}"

    mkdir -p "${backup_dir}/rootfs"
    chmod 700 "$BACKUP_ROOT" "$product_dir" "$backup_dir" 2>/dev/null || true
    reason=$(printf '%s' "$reason" | tr -cd '[:alnum:]_.-')

    {
        printf 'schema=%s\n' "$BACKUP_SCHEMA_VERSION"
        printf 'id=%s\n' "$backup_id"
        printf 'product=%s\n' "$PRODUCT"
        printf 'created_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'hostname=%s\n' "$(hostname 2>/dev/null || printf unknown)"
        printf 'reason=%s\n' "${reason:-manual}"
        printf 'proxmorph_version=%s\n' "$VERSION"
        printf 'preexisting_install=%s\n' "$had_install"
    } > "${backup_dir}/metadata.env"
    capture_package_versions "${backup_dir}/package-versions.tsv"
    capture_optional_package_state "${backup_dir}/optional-packages.tsv"
    : > "${backup_dir}/inventory.tsv"

    collect_backup_candidates "$themes_source"
    for path in "${BACKUP_CANDIDATES[@]}"; do
        backup_path_is_allowed "$path" || {
            print_error "Refusing to back up unexpected path: $path"
            return 1
        }
        state="absent"
        if path_exists "$path"; then
            state="present"
            mkdir -p "${backup_dir}/rootfs$(dirname "$path")"
            cp -a "$path" "${backup_dir}/rootfs${path}"
        fi
        printf '%s\t%s\n' "$state" "$path" >> "${backup_dir}/inventory.tsv"
    done

    regenerate_backup_checksums "$backup_dir"
    : > "${backup_dir}/.complete"
    write_backup_pointer "${product_dir}/latest" "$backup_id"
    if [[ ! -f "${product_dir}/baseline" && "$had_install" == "false" ]]; then
        write_backup_pointer "${product_dir}/baseline" "$backup_id"
        print_status "Created clean uninstall baseline: ${backup_id}"
    fi

    LAST_BACKUP_ID="$backup_id"
    print_status "Created full ${PRODUCT} backup: ${backup_id}"
}

extend_backup_inventory() {
    local backup_id="$1"
    local themes_source="${2:-}"
    local backup_dir=""
    local path=""
    local state=""
    backup_dir="$(product_backup_dir)/${backup_id}"
    [[ -d "$backup_dir" ]] || return 1

    collect_backup_candidates "$themes_source"
    for path in "${BACKUP_CANDIDATES[@]}"; do
        grep -qF $'\t'"${path}" "${backup_dir}/inventory.tsv" 2>/dev/null && continue
        backup_path_is_allowed "$path" || return 1
        state="absent"
        if path_exists "$path"; then
            state="present"
            mkdir -p "${backup_dir}/rootfs$(dirname "$path")"
            cp -a "$path" "${backup_dir}/rootfs${path}"
        fi
        printf '%s\t%s\n' "$state" "$path" >> "${backup_dir}/inventory.tsv"
    done
    regenerate_backup_checksums "$backup_dir"
}

extend_uninstall_baseline() {
    local themes_source="${1:-}"
    local product_dir=""
    local baseline_id=""
    product_dir=$(product_backup_dir)
    [[ -f "${product_dir}/baseline" ]] || return 0
    baseline_id=$(tr -d ' \t\r\n' < "${product_dir}/baseline")
    [[ -n "$baseline_id" && "$baseline_id" != "$TRANSACTION_BACKUP_ID" ]] || return 0
    verify_backup "${product_dir}/${baseline_id}" || return 1
    # Add only previously unknown destination names while they are still
    # untouched. Existing inventory entries are never replaced.
    extend_backup_inventory "$baseline_id" "$themes_source"
}

backup_metadata_value() {
    local backup_dir="$1"
    local key="$2"
    awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); print; exit }' "${backup_dir}/metadata.env"
}

resolve_backup_id() {
    local requested="${1:-latest}"
    local product_dir=""
    product_dir=$(product_backup_dir)
    case "$requested" in
        latest|baseline)
            [[ -f "${product_dir}/${requested}" ]] || return 1
            requested=$(tr -d ' \t\r\n' < "${product_dir}/${requested}")
            ;;
    esac
    [[ "$requested" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    [[ -d "${product_dir}/${requested}" ]] || return 1
    printf '%s' "$requested"
}

verify_backup() {
    local backup_dir="$1"
    [[ -f "${backup_dir}/.complete" && -f "${backup_dir}/SHA256SUMS" ]] || {
        print_error "Backup is incomplete: $(basename "$backup_dir")"
        return 1
    }
    (cd "$backup_dir" && sha256sum -c SHA256SUMS >/dev/null) || {
        print_error "Backup checksum verification failed: $(basename "$backup_dir")"
        return 1
    }
    return 0
}

verify_backup_package_versions() {
    local backup_dir="$1"
    local package=""
    local saved_version=""
    local current_version=""
    while IFS=$'\t' read -r package saved_version; do
        [[ -n "$package" ]] || continue
        current_version=$(get_installed_package_version "$package")
        if [[ "$saved_version" != "$current_version" ]]; then
            print_error "Package version mismatch for ${package}: backup=${saved_version}, current=${current_version}"
            return 1
        fi
    done < "${backup_dir}/package-versions.tsv"
    return 0
}

confirm_destructive_action() {
    local prompt="$1"
    local assume_yes="${2:-false}"
    local reply=""
    [[ "$assume_yes" == "true" ]] && return 0
    if [[ ! -t 0 ]]; then
        print_error "Confirmation required; re-run with --yes"
        return 1
    fi
    read -r -p "${prompt} [y/N]: " reply
    case "$reply" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) print_info "Cancelled"; return 1 ;;
    esac
}

remove_exact_path() {
    local path="$1"
    backup_path_is_allowed "$path" || {
        print_error "Refusing to remove unexpected path: $path"
        return 1
    }
    if [[ -d "$path" && ! -L "$path" ]]; then
        rm -rf -- "$path"
    else
        rm -f -- "$path"
    fi
}

restore_local_inventory() {
    local backup_dir="$1"
    local scope="${2:-all}"
    local state=""
    local path=""
    local source_path=""
    while IFS=$'\t' read -r state path; do
        [[ -n "$path" ]] || continue
        backup_path_is_allowed "$path" || {
            print_error "Backup contains an unexpected restore path: $path"
            return 1
        }
        if [[ "$scope" == "nonpackage" ]]; then
            case "$path" in
                "$INDEX_TEMPLATE"|"$PROXMOXLIB_JS"|"$NODES_PM"|"$PVE_CLUSTER_PM"|"$PVE_API2_PM"|"$NOVNC_INDEX_TPL") continue ;;
            esac
            # On a cross-version uninstall, the currently installed package
            # wins if it has since claimed a formerly custom destination.
            if command -v dpkg &>/dev/null && dpkg -S "$path" &>/dev/null; then
                continue
            fi
        elif [[ "$scope" == "package" ]]; then
            case "$path" in
                "$INDEX_TEMPLATE"|"$PROXMOXLIB_JS"|"$NODES_PM"|"$PVE_CLUSTER_PM"|"$PVE_API2_PM"|"$NOVNC_INDEX_TPL") ;;
                *) continue ;;
            esac
        fi
        source_path="${backup_dir}/rootfs${path}"
        case "$state" in
            present)
                path_exists "$source_path" || {
                    print_error "Backup payload is missing: $path"
                    return 1
                }
                if path_exists "$path"; then
                    remove_exact_path "$path" || return 1
                fi
                mkdir -p "$(dirname "$path")" || return 1
                if [[ "$path" == "$PVE_PREFERENCES_FILE" ]]; then
                    # pmxcfs derives ownership and modes from the path and does
                    # not implement chmod/chown, so restore its contents without
                    # cp -a metadata operations.
                    cp "$source_path" "$path" || return 1
                else
                    cp -a "$source_path" "$path" || return 1
                fi
                ;;
            absent)
                if path_exists "$path"; then
                    remove_exact_path "$path" || return 1
                fi
                ;;
            *)
                print_error "Invalid backup inventory state '${state}' for ${path}"
                return 1
                ;;
        esac
    done < "${backup_dir}/inventory.tsv"
}

restore_remote_inventory() {
    local backup_dir="$1"
    local state=""
    local node=""
    local path=""
    local safe_node=""
    local source_path=""
    [[ -f "${backup_dir}/remote-inventory.tsv" ]] || return 0

    while IFS=$'\t' read -r state node path; do
        [[ "$node" =~ ^[A-Za-z0-9._-]+$ ]] || {
            print_error "Backup contains an invalid remote node name: $node"
            return 1
        }
        case "$path" in
            "$NODES_PM"|"$SENSORS_FILTER") ;;
            *) print_error "Backup contains an unexpected remote path: $path"; return 1 ;;
        esac
        safe_node=$(printf '%s' "$node" | tr -cd 'A-Za-z0-9._-')
        source_path="${backup_dir}/remote/${safe_node}/rootfs${path}"
        if [[ "$state" == "present" ]]; then
            [[ -f "$source_path" ]] || {
                print_error "Remote backup payload is missing for ${node}:${path}"
                return 1
            }
            ssh -n -o ConnectTimeout=5 "root@${node}" "mkdir -p '$(dirname "$path")'" >/dev/null || return 1
            scp -o ConnectTimeout=5 -p -q "$source_path" "root@${node}:${path}" || return 1
        elif [[ "$state" == "absent" && "$path" == "$SENSORS_FILTER" ]]; then
            ssh -n -o ConnectTimeout=5 "root@${node}" "rm -f -- '${path}'" >/dev/null || return 1
        elif [[ "$state" != "absent" ]]; then
            print_error "Invalid remote backup inventory state '${state}'"
            return 1
        fi
        ssh -n -o ConnectTimeout=5 "root@${node}" "systemctl restart pvedaemon pveproxy" >/dev/null || return 1
        print_status "Restored remote sensor state on ${node}"
    done < "${backup_dir}/remote-inventory.tsv"
}

install_debian_package() {
    local package="$1"
    command -v apt-get &>/dev/null || {
        print_error "apt-get is required to install ${package}"
        return 1
    }
    DEBIAN_FRONTEND=noninteractive apt-get -qq -o Dpkg::Use-Pty=0 install -y "$package"
}

remove_debian_package() {
    local package="$1"
    command -v apt-get &>/dev/null || {
        print_error "apt-get is required to remove ${package}"
        return 1
    }
    DEBIAN_FRONTEND=noninteractive apt-get -qq -o Dpkg::Use-Pty=0 remove -y "$package"
}

restore_optional_package_state() {
    local backup_dir="$1"
    local sensor_package_owned_before_restore="${2:-false}"
    local package=""
    local saved_state=""
    [[ -f "${backup_dir}/optional-packages.tsv" ]] || return 0

    while IFS=$'\t' read -r package saved_state; do
        [[ -n "$package" ]] || continue
        [[ "$package" == "lm-sensors" ]] || {
            print_error "Backup contains an unexpected optional package: ${package}"
            return 1
        }
        case "$saved_state" in
            present)
                if ! package_is_installed "$package"; then
                    print_info "Restoring optional package: ${package}"
                    install_debian_package "$package" || return 1
                fi
                ;;
            absent)
                if package_is_installed "$package" && [[ "$sensor_package_owned_before_restore" == "true" ]]; then
                    print_info "Removing ProxMorph-installed optional package: ${package}"
                    remove_debian_package "$package" || return 1
                fi
                ;;
            *)
                print_error "Backup contains an invalid optional-package state for ${package}: ${saved_state}"
                return 1
                ;;
        esac
    done < "${backup_dir}/optional-packages.tsv"
}

snapshot_remote_nodes_before_restore() {
    local backup_dir="$1"
    local node=""
    [[ -f "${backup_dir}/remote-inventory.tsv" ]] || return 0
    [[ "$TRANSACTION_ACTIVE" == "true" && -n "$TRANSACTION_BACKUP_ID" ]] || {
        print_error "A transaction backup is required before restoring remote sensor files"
        return 1
    }
    while IFS= read -r node; do
        [[ -n "$node" ]] || continue
        backup_remote_sensor_state "$node" || return 1
    done < <(awk -F '\t' '{print $2}' "${backup_dir}/remote-inventory.tsv" | sort -u)
}

restore_backup_internal() {
    local requested="${1:-latest}"
    local assume_yes="${2:-false}"
    local force_version="${3:-false}"
    local backup_id=""
    local backup_dir=""
    local backup_product=""
    local sensor_package_owned_before_restore=false

    backup_id=$(resolve_backup_id "$requested") || {
        print_error "Backup not found for ${PRODUCT}: ${requested}"
        return 1
    }
    backup_dir="$(product_backup_dir)/${backup_id}"
    verify_backup "$backup_dir" || return 1
    backup_product=$(backup_metadata_value "$backup_dir" product)
    [[ "$backup_product" == "$PRODUCT" ]] || {
        print_error "Backup product ${backup_product} does not match detected product ${PRODUCT}"
        return 1
    }
    if [[ "$force_version" != "true" ]]; then
        verify_backup_package_versions "$backup_dir" || {
            print_error "Refusing to overwrite files from a different package version. Use --force only after reviewing the mismatch."
            return 1
        }
    fi
    confirm_destructive_action "Restore backup ${backup_id}? Current ProxMorph-managed files will be replaced" "$assume_yes" || return 1

    [[ -f "$SENSORS_PACKAGE_MARKER" ]] && sensor_package_owned_before_restore=true
    if [[ "$TRANSACTION_ACTIVE" == "true" && "$TRANSACTION_BACKUP_ID" != "$backup_id" ]]; then
        snapshot_remote_nodes_before_restore "$backup_dir" || return 1
    fi
    restore_local_inventory "$backup_dir" || return 1
    restore_remote_inventory "$backup_dir" || return 1
    restore_optional_package_state "$backup_dir" "$sensor_package_owned_before_restore" || return 1
    if command -v systemctl &>/dev/null && [[ -n "$PROXY_SERVICE" ]]; then
        restart_proxmorph_services false 2>/dev/null || true
    fi
    print_status "Restored ${PRODUCT} backup: ${backup_id}"
}

restore_backup() {
    local requested="${1:-latest}"
    shift || true
    local assume_yes=false
    local force_version=false
    local arg=""
    local backup_id=""
    local backup_dir=""
    local backup_product=""
    for arg in "$@"; do
        case "$arg" in
            --yes) assume_yes=true ;;
            --force) force_version=true ;;
            *) print_error "Unknown restore option: $arg"; return 1 ;;
        esac
    done

    # Resolve "latest" before creating the pre-restore transaction snapshot,
    # otherwise the new safety snapshot would become the restore target.
    backup_id=$(resolve_backup_id "$requested") || {
        print_error "Backup not found for ${PRODUCT}: ${requested}"
        return 1
    }
    backup_dir="$(product_backup_dir)/${backup_id}"
    verify_backup "$backup_dir" || return 1
    backup_product=$(backup_metadata_value "$backup_dir" product)
    [[ "$backup_product" == "$PRODUCT" ]] || {
        print_error "Backup product ${backup_product} does not match detected product ${PRODUCT}"
        return 1
    }
    if [[ "$force_version" != "true" ]]; then
        verify_backup_package_versions "$backup_dir" || {
            print_error "Refusing to overwrite files from a different package version. Use --force only after reviewing the mismatch."
            return 1
        }
    fi
    confirm_destructive_action "Restore backup ${backup_id}? Current ProxMorph-managed files will be replaced" "$assume_yes" || return 1

    if [[ "$TRANSACTION_ACTIVE" != "true" ]]; then
        begin_transaction "pre-restore" "$(get_themes_source || true)"
    fi
    restore_backup_internal "$backup_id" true "$force_version" || return 1
    commit_transaction
}

list_backups() {
    local product_dir=""
    local backup_dir=""
    local backup_id=""
    local baseline_id=""
    product_dir=$(product_backup_dir)
    [[ -d "$product_dir" ]] || {
        print_info "No ${PRODUCT} backups found"
        return 0
    }
    [[ -f "${product_dir}/baseline" ]] && baseline_id=$(tr -d ' \t\r\n' < "${product_dir}/baseline")
    print_info "Available ${PRODUCT} backups:"
    for backup_dir in "${product_dir}"/*; do
        [[ -d "$backup_dir" && -f "${backup_dir}/.complete" ]] || continue
        backup_id=$(basename "$backup_dir")
        printf '  %s  %s  reason=%s%s\n' \
            "$backup_id" \
            "$(backup_metadata_value "$backup_dir" created_utc)" \
            "$(backup_metadata_value "$backup_dir" reason)" \
            "$([[ "$backup_id" == "$baseline_id" ]] && printf '  [baseline]')"
    done
}

find_current_clean_package_backup() {
    local product_dir=""
    local backup_dir=""
    local found=""
    product_dir=$(product_backup_dir)
    [[ -d "$product_dir" ]] || return 1
    for backup_dir in "${product_dir}"/*; do
        [[ -d "$backup_dir" && -f "${backup_dir}/.complete" ]] || continue
        [[ "$(backup_metadata_value "$backup_dir" reason)" == "apt-repatch" ]] || continue
        if verify_backup "$backup_dir" >/dev/null 2>&1 && \
           verify_backup_package_versions "$backup_dir" >/dev/null 2>&1; then
            found=$(basename "$backup_dir")
        fi
    done
    [[ -n "$found" ]] || return 1
    printf '%s' "$found"
}

# ─── No-write operation previews ───────────────────────────────

print_dry_run_header() {
    local operation="$1"
    echo ""
    print_info "DRY RUN: ${operation}"
    print_info "No files, backups, packages, services, or remote nodes will be changed."
    echo ""
}

preview_backup_plan() {
    local reason="$1"
    local themes_source="${2:-}"
    local path=""
    local package=""
    print_info "Backup destination: $(product_backup_dir)/<timestamped-id>"
    print_info "Backup reason: ${reason}"
    print_info "Package versions to record:"
    while IFS= read -r package; do
        [[ -n "$package" ]] || continue
        printf '  [record] %s=%s\n' "$package" "$(get_installed_package_version "$package")"
    done < <(get_product_package_names)
    if [[ "$PRODUCT" == "PVE" ]]; then
        if package_is_installed lm-sensors; then
            printf '  [record optional] lm-sensors=present\n'
        else
            printf '  [record optional] lm-sensors=absent\n'
        fi
    fi

    collect_backup_candidates "$themes_source"
    print_info "Backup inventory:"
    for path in "${BACKUP_CANDIDATES[@]}"; do
        if path_exists "$path"; then
            printf '  [back up] %s\n' "$path"
        else
            printf '  [record absent] %s\n' "$path"
        fi
    done
}

preview_install_operation() {
    local operation="$1"
    local version="${2:-}"
    local version_label="latest release"
    local themes_source=""
    local css_file=""
    local js_file=""
    local restore_package="proxmox-widget-toolkit"

    print_dry_run_header "$operation"
    validate_runtime_contracts || return 1
    themes_source=$(get_themes_source || true)

    if [[ "$operation" == "update" ]]; then
        [[ -n "$version" ]] && version_label="v${version}"
        print_info "Would download and checksum-verify ProxMorph ${version_label} before replacing ${INSTALL_DIR}."
        if [[ -n "$themes_source" ]]; then
            print_warning "Destination names below are based on the currently available source: ${themes_source}"
            print_warning "A newer release may introduce additional names; the real update adds them to the backup before copying."
        fi
    elif [[ "$operation" == "reinstall" ]]; then
        [[ "$PRODUCT" == "PDM" ]] && restore_package="proxmox-datacenter-manager-ui"
        print_info "Would reinstall the currently selected ${restore_package} package before reapplying ProxMorph."
    fi

    if [[ -z "$themes_source" ]]; then
        print_warning "No local or cached theme source is available; incoming theme filenames cannot be enumerated without downloading the release."
    else
        print_info "Theme source: ${themes_source}"
    fi
    preview_backup_plan "$operation" "$themes_source"

    echo ""
    print_info "Planned installation actions:"
    if [[ "$PRODUCT" == "PDM" ]]; then
        if [[ -n "$themes_source" ]]; then
            [[ -f "${themes_source}/proxmorph-pdm-base.css" ]] && \
                printf '  [copy] %s -> %s/\n' "${themes_source}/proxmorph-pdm-base.css" "$PDM_THEMES_DIR"
            for css_file in "$themes_source"/theme-*.css; do
                [[ -f "$css_file" ]] || continue
                printf '  [copy] %s -> %s/\n' "$css_file" "$PDM_THEMES_DIR"
            done
            js_file="$(dirname "$themes_source")/patches/pdm-theme-selector.js"
            [[ -f "$js_file" ]] && printf '  [copy] %s -> %s/\n' "$js_file" "$PDM_JS_PATCHES_DIR"
        fi
        printf '  [modify] %s (inject PDM theme links and selector loader)\n' "$INDEX_TEMPLATE"
    else
        if [[ -n "$themes_source" ]]; then
            for css_file in "$themes_source"/theme-*.css; do
                [[ -f "$css_file" ]] || continue
                printf '  [copy] %s -> %s/\n' "$css_file" "$THEMES_DIR"
            done
            for js_file in "$themes_source"/patches/*.js; do
                [[ -f "$js_file" ]] || continue
                printf '  [copy] %s -> %s/\n' "$js_file" "$JS_PATCHES_DIR"
            done
        fi
        printf '  [modify] %s (register theme keys)\n' "$PROXMOXLIB_JS"
        printf '  [modify] %s (load JavaScript patches/default theme)\n' "$INDEX_TEMPLATE"
        if [[ "$PRODUCT" == "PVE" ]]; then
            if [[ -n "$themes_source" && -d "${themes_source}/novnc" ]]; then
                for js_file in "${themes_source}/novnc"/*; do
                    [[ -f "$js_file" ]] || continue
                    printf '  [copy] %s -> %s/\n' "$js_file" "$NOVNC_PROXMORPH_DIR"
                done
            fi
            printf '  [modify] %s (load native noVNC clipboard enhancement)\n' "$NOVNC_INDEX_TPL"
            printf '  [optional] %s (only if hardware sensors are enabled)\n' "$NODES_PM"
            printf '  [optional package] lm-sensors (installed noninteractively only after consent)\n'
            printf '  [optional hardware probe] sensors-detect --auto (only if readings are unavailable)\n'
            printf '  [modify] %s (register replicated preference file)\n' "$PVE_CLUSTER_PM"
            printf '  [modify] %s (register authenticated preferences API)\n' "$PVE_API2_PM"
            printf '  [copy] %s -> %s\n' "$PVE_PREFERENCES_SOURCE_RELATIVE" "$PVE_PROXMORPH_API_PM"
            printf '  [on first Apply] %s (per-user Inventory, Appearance, and Console settings)\n' "$PVE_PREFERENCES_FILE"
        fi
    fi
    printf '  [write] %s (release cache and installed-path ledger)\n' "$INSTALL_DIR"
    printf '  [write] %s\n' "$APT_HOOK_FILE"
    preview_service_restarts
}

preview_inventory_actions() {
    local backup_dir="$1"
    local scope="${2:-all}"
    local state=""
    local path=""
    local node=""
    while IFS=$'\t' read -r state path; do
        [[ -n "$path" ]] || continue
        if [[ "$scope" == "nonpackage" ]]; then
            case "$path" in
                "$INDEX_TEMPLATE"|"$PROXMOXLIB_JS"|"$NODES_PM"|"$PVE_CLUSTER_PM"|"$PVE_API2_PM"|"$NOVNC_INDEX_TPL") continue ;;
            esac
            if command -v dpkg &>/dev/null && dpkg -S "$path" &>/dev/null; then
                printf '  [preserve current package] %s\n' "$path"
                continue
            fi
        elif [[ "$scope" == "package" ]]; then
            case "$path" in
                "$INDEX_TEMPLATE"|"$PROXMOXLIB_JS"|"$NODES_PM"|"$PVE_CLUSTER_PM"|"$PVE_API2_PM"|"$NOVNC_INDEX_TPL") ;;
                *) continue ;;
            esac
        fi

        if [[ "$state" == "present" ]]; then
            printf '  [restore] %s\n' "$path"
        elif path_exists "$path"; then
            printf '  [remove; originally absent] %s\n' "$path"
        else
            printf '  [leave absent] %s\n' "$path"
        fi
    done < "${backup_dir}/inventory.tsv"

    if [[ "$scope" == "all" && -f "${backup_dir}/remote-inventory.tsv" ]]; then
        while IFS=$'\t' read -r state node path; do
            if [[ "$state" == "present" ]]; then
                printf '  [restore remote] %s:%s\n' "$node" "$path"
            else
                printf '  [remove remote; originally absent] %s:%s\n' "$node" "$path"
            fi
        done < "${backup_dir}/remote-inventory.tsv"
    fi
}

preview_optional_package_actions() {
    local backup_dir="$1"
    local package=""
    local saved_state=""
    [[ -f "${backup_dir}/optional-packages.tsv" ]] || return 0

    while IFS=$'\t' read -r package saved_state; do
        [[ "$package" == "lm-sensors" ]] || continue
        if [[ "$saved_state" == "present" ]] && ! package_is_installed "$package"; then
            printf '  [install optional package] %s\n' "$package"
        elif [[ "$saved_state" == "absent" ]] && package_is_installed "$package" && [[ -f "$SENSORS_PACKAGE_MARKER" ]]; then
            printf '  [remove ProxMorph-installed package] %s\n' "$package"
        fi
    done < "${backup_dir}/optional-packages.tsv"
}

preview_restore_operation() {
    local requested="${1:-latest}"
    shift || true
    local force_version=false
    local arg=""
    local backup_id=""
    local backup_dir=""
    local backup_product=""
    for arg in "$@"; do
        case "$arg" in
            --force) force_version=true ;;
            --yes) ;;
            *) print_error "Unknown restore option: $arg"; return 1 ;;
        esac
    done

    print_dry_run_header "restore ${requested}"
    backup_id=$(resolve_backup_id "$requested") || {
        print_error "Backup not found for ${PRODUCT}: ${requested}"
        return 1
    }
    backup_dir="$(product_backup_dir)/${backup_id}"
    verify_backup "$backup_dir" || return 1
    backup_product=$(backup_metadata_value "$backup_dir" product)
    [[ "$backup_product" == "$PRODUCT" ]] || {
        print_error "Backup product ${backup_product} does not match detected product ${PRODUCT}"
        return 1
    }
    if ! verify_backup_package_versions "$backup_dir"; then
        if [[ "$force_version" == "true" ]]; then
            print_warning "Package-version mismatch would be overridden by --force."
        else
            print_error "Restore would be blocked by the package-version guard. Review the mismatch before using --force."
            return 1
        fi
    fi

    print_info "Resolved backup ID: ${backup_id}"
    print_info "Created: $(backup_metadata_value "$backup_dir" created_utc)"
    print_info "Reason: $(backup_metadata_value "$backup_dir" reason)"
    echo ""
    print_info "Planned pre-restore safety backup:"
    preview_backup_plan "pre-restore" "$(get_themes_source || true)"
    echo ""
    print_info "Planned restore actions:"
    preview_inventory_actions "$backup_dir" all
    preview_optional_package_actions "$backup_dir"
    preview_service_restarts
}

preview_uninstall_assets() {
    local themes_source="${1:-}"
    local path=""
    local css_file=""
    if [[ -f "$INSTALLED_PATHS_FILE" ]]; then
        while IFS= read -r path; do
            [[ -n "$path" ]] && printf '  [remove current release asset] %s\n' "$path"
        done < "$INSTALLED_PATHS_FILE"
    elif [[ "$PRODUCT" == "PDM" ]]; then
        printf '  [remove current release asset] %s\n' "$PDM_THEMES_DIR" "$PDM_JS_PATCHES_DIR"
    else
        for css_file in "$themes_source"/theme-*.css; do
            [[ -f "$css_file" ]] || continue
            printf '  [remove current release asset] %s/%s\n' "$THEMES_DIR" "$(basename "$css_file")"
        done
        printf '  [remove current release asset] %s\n' "$JS_PATCHES_DIR"
    fi
}

preview_uninstall_fallback_cleanup() {
    local node=""
    if [[ "$PRODUCT" == "PDM" ]]; then
        printf '  [remove] %s\n' "$PDM_THEMES_DIR" "$PDM_JS_PATCHES_DIR"
        printf '  [modify] %s (remove PDM theme injection)\n' "$INDEX_TEMPLATE"
    else
        printf '  [remove] %s\n' "$JS_PATCHES_DIR"
        printf '  [modify] %s (remove JavaScript/default-theme injection)\n' "$INDEX_TEMPLATE"
        if [[ "$PRODUCT" == "PVE" ]]; then
            printf '  [modify] %s (remove noVNC clipboard loader)\n' "$NOVNC_INDEX_TPL"
            printf '  [remove] %s\n' "$NOVNC_PROXMORPH_DIR"
            printf '  [modify] %s (remove sensor API block)\n' "$NODES_PM"
            printf '  [remove] %s\n' "$SENSORS_CONFIG" "$SENSORS_FILTER"
            if [[ -f "$SENSORS_PACKAGE_MARKER" ]] && package_is_installed lm-sensors; then
                printf '  [remove ProxMorph-installed package] lm-sensors\n'
            fi
            printf '  [modify] %s (remove preferences file registration)\n' "$PVE_CLUSTER_PM"
            printf '  [modify] %s (remove preferences API registration)\n' "$PVE_API2_PM"
            printf '  [remove] %s\n' "$PVE_PROXMORPH_API_PM" "$PVE_PREFERENCES_FILE"
            while IFS= read -r node; do
                [[ -n "$node" ]] || continue
                printf '  [back up] %s:%s\n' "$node" "$NODES_PM"
                printf '  [back up] %s:%s\n' "$node" "$SENSORS_FILTER"
                printf '  [modify remote] %s:%s (remove sensor API block)\n' "$node" "$NODES_PM"
                printf '  [restart remote] %s:pveproxy\n' "$node"
            done < <(get_remote_nodes)
        fi
    fi
    printf '  [remove] %s\n' "$APT_HOOK_FILE" "$CONFIG_DIR" "$PROXMORPH_LOG_FILE" "$INSTALL_DIR"
}

preview_current_package_reinstall() {
    local package=""
    print_info "Would reinstall the current ${PRODUCT} web package(s):"
    case "$PRODUCT" in
        PVE) printf '%s\n' pve-manager pve-cluster proxmox-widget-toolkit ;;
        PBS) printf '%s\n' proxmox-backup-server proxmox-widget-toolkit ;;
        PDM) printf '%s\n' proxmox-datacenter-manager-ui ;;
    esac | while IFS= read -r package; do
        [[ -n "$package" ]] && printf '  [reinstall package] %s\n' "$package"
    done
}

preview_uninstall_operation() {
    local themes_source=""
    local baseline_id=""
    local baseline_dir=""
    local clean_id=""
    local clean_dir=""
    local baseline_verified=false
    local used_baseline=false

    print_dry_run_header "uninstall"
    themes_source=$(get_themes_source || true)
    preview_backup_plan "uninstall" "$themes_source"
    echo ""
    print_info "Planned uninstall actions:"
    preview_uninstall_assets "$themes_source"

    if baseline_id=$(resolve_backup_id baseline 2>/dev/null); then
        baseline_dir="$(product_backup_dir)/${baseline_id}"
        if verify_backup "$baseline_dir"; then
            baseline_verified=true
        fi
        if [[ "$baseline_verified" == "true" ]] && verify_backup_package_versions "$baseline_dir"; then
            print_info "Would restore exact clean baseline: ${baseline_id}"
            preview_inventory_actions "$baseline_dir" all
            preview_optional_package_actions "$baseline_dir"
            used_baseline=true
        else
            print_warning "The baseline cannot safely restore current package files; the fallback uninstall path would be used."
        fi
    else
        print_warning "No clean baseline exists; the fallback uninstall path would be used."
    fi

    if [[ "$used_baseline" != "true" ]]; then
        preview_uninstall_fallback_cleanup
        clean_id=$(find_current_clean_package_backup || true)
        if [[ -n "$clean_id" ]]; then
            clean_dir="$(product_backup_dir)/${clean_id}"
            print_info "Would restore current clean package files from: ${clean_id}"
            preview_inventory_actions "$clean_dir" package
        else
            preview_current_package_reinstall
        fi
        if [[ "$baseline_verified" == "true" ]]; then
            print_info "Would restore pre-existing non-package files from baseline: ${baseline_id}"
            preview_inventory_actions "$baseline_dir" nonpackage
        fi
    fi
    printf '  [retain] %s (all rollback backups)\n' "$(product_backup_dir)"
    preview_service_restarts
}

preview_default_theme_operation() {
    local arg="${1:-}"
    [[ -n "$arg" ]] || {
        manage_default_theme
        return 0
    }
    print_dry_run_header "default-theme ${arg}"
    if [[ "$arg" != "none" ]]; then
        if [[ "$PRODUCT" == "PDM" ]]; then
            [[ -f "${PDM_THEMES_DIR}/theme-${arg}.css" ]] || {
                print_error "Theme 'theme-${arg}.css' is not installed"
                return 1
            }
        else
            [[ -f "${THEMES_DIR}/theme-${arg}.css" ]] || {
                print_error "Theme 'theme-${arg}.css' is not installed"
                return 1
            }
        fi
    fi
    preview_backup_plan "default-theme" ""
    if [[ "$arg" == "none" ]]; then
        printf '  [remove] %s\n' "$DEFAULT_THEME_FILE"
    else
        printf '  [write] %s = %s\n' "$DEFAULT_THEME_FILE" "$arg"
    fi
    printf '  [refresh injection] %s\n' "$INDEX_TEMPLATE"
    printf '  [restart] %s\n' "$PROXY_SERVICE"
}

preview_sensor_operation() {
    local action="${1:-status}"
    local node=""
    if [[ "$action" == "status" ]]; then
        manage_sensors status
        return
    elif [[ "$action" == "detect" ]]; then
        detect_sensors
        return
    fi
    [[ "$PRODUCT" == "PVE" ]] || {
        print_error "Hardware sensor support is only available for Proxmox VE"
        return 1
    }
    print_dry_run_header "sensors ${action}"
    case "$action" in
        enable)
            preview_backup_plan "sensors-enable" ""
            if package_is_installed lm-sensors; then
                printf '  [keep optional package] lm-sensors (already installed)\n'
            else
                printf '  [install optional package] lm-sensors\n'
                printf '  [write ownership marker] %s\n' "$SENSORS_PACKAGE_MARKER"
            fi
            if ! detect_sensors >/dev/null 2>&1; then
                printf '  [hardware probe] sensors-detect --auto (readings unavailable)\n'
            fi
            printf '  [modify] %s (sensor API block)\n' "$NODES_PM"
            printf '  [write] %s\n' "$SENSORS_CONFIG"
            while IFS= read -r node; do
                [[ -n "$node" ]] || continue
                printf '  [optional back up] %s:%s\n' "$node" "$NODES_PM"
                printf '  [optional back up] %s:%s\n' "$node" "$SENSORS_FILTER"
                printf '  [optional deploy] %s:%s\n' "$node" "$NODES_PM"
                [[ -f "$SENSORS_FILTER" ]] && printf '  [optional deploy] %s:%s\n' "$node" "$SENSORS_FILTER"
                printf '  [optional restart] %s:pveproxy\n' "$node"
            done < <(get_remote_nodes)
            ;;
        disable)
            preview_backup_plan "sensors-disable" ""
            printf '  [modify] %s (remove sensor API block)\n' "$NODES_PM"
            printf '  [remove] %s\n' "$SENSORS_CONFIG" "$SENSORS_FILTER"
            while IFS= read -r node; do
                [[ -n "$node" ]] || continue
                printf '  [back up] %s:%s\n' "$node" "$NODES_PM"
                printf '  [back up] %s:%s\n' "$node" "$SENSORS_FILTER"
                printf '  [modify remote] %s:%s (remove sensor API block)\n' "$node" "$NODES_PM"
                printf '  [restart remote] %s:pveproxy\n' "$node"
            done < <(get_remote_nodes)
            ;;
        configure)
            if ! check_sensors; then
                print_error "Sensors are not enabled. Enable them first with: install.sh sensors enable"
                return 1
            fi
            preview_backup_plan "sensors-configure" ""
            printf '  [write] %s\n' "$SENSORS_FILTER"
            printf '  [refresh] %s\n' "$NODES_PM"
            ;;
        *) print_error "Unknown sensor action: $action"; return 1 ;;
    esac
    preview_service_restarts
}

dry_run_dispatch() {
    local command="${1:-install}"
    shift || true
    case "$command" in
        install) preview_install_operation install ;;
        update) preview_install_operation update "${1:-}" ;;
        reinstall) preview_install_operation reinstall ;;
        backup)
            print_dry_run_header "backup ${1:-manual}"
            preview_backup_plan "${1:-manual}" "$(get_themes_source || true)"
            ;;
        restore) preview_restore_operation "${1:-latest}" "${@:2}" ;;
        uninstall) preview_uninstall_operation ;;
        default-theme) preview_default_theme_operation "${1:-}" ;;
        sensors) preview_sensor_operation "${1:-status}" ;;
        compatibility) validate_runtime_contracts ;;
        list) list_themes ;;
        status) show_status ;;
        check) check_updates ;;
        backups|list-backups) list_backups ;;
        *) print_error "Dry run is not supported for command: $command"; return 1 ;;
    esac
}

begin_transaction() {
    local reason="$1"
    local themes_source="${2:-}"
    if [[ "$TRANSACTION_ACTIVE" == "true" ]]; then
        return 0
    fi
    create_backup "$reason" "$themes_source"
    TRANSACTION_BACKUP_ID="$LAST_BACKUP_ID"
    TRANSACTION_ACTIVE=true
    trap 'rollback_transaction $?' ERR
    trap 'rollback_transaction 130' INT
    trap 'rollback_transaction 143' TERM
}

commit_transaction() {
    trap - ERR INT TERM
    TRANSACTION_ACTIVE=false
    TRANSACTION_BACKUP_ID=""
}

rollback_transaction() {
    local status="${1:-1}"
    trap - ERR INT TERM
    [[ "$TRANSACTION_ROLLING_BACK" == "true" ]] && exit "$status"
    TRANSACTION_ROLLING_BACK=true
    set +e
    if [[ "$TRANSACTION_ACTIVE" == "true" && -n "$TRANSACTION_BACKUP_ID" ]]; then
        print_error "Operation failed; restoring backup ${TRANSACTION_BACKUP_ID}"
        if restore_backup_internal "$TRANSACTION_BACKUP_ID" true true; then
            print_status "Automatic rollback completed"
        else
            print_error "Automatic rollback failed. Run: $0 restore ${TRANSACTION_BACKUP_ID} --yes --force"
        fi
    fi
    exit "$status"
}

backup_remote_path_to() {
    local backup_id="$1"
    local node="$2"
    local path="$3"
    local backup_dir=""
    local safe_node=""
    local state="absent"
    local destination=""
    local remote_state=""

    [[ "$node" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    case "$path" in
        "$NODES_PM"|"$SENSORS_FILTER") ;;
        *) return 1 ;;
    esac
    backup_dir="$(product_backup_dir)/${backup_id}"
    [[ -d "$backup_dir" ]] || return 1
    [[ -f "${backup_dir}/remote-inventory.tsv" ]] || : > "${backup_dir}/remote-inventory.tsv"
    grep -qF $'\t'"${node}"$'\t'"${path}" "${backup_dir}/remote-inventory.tsv" 2>/dev/null && return 0

    safe_node=$(printf '%s' "$node" | tr -cd 'A-Za-z0-9._-')
    destination="${backup_dir}/remote/${safe_node}/rootfs${path}"
    remote_state=$(ssh -n -o ConnectTimeout=5 "root@${node}" \
        "if [ -e '${path}' ]; then printf PRESENT; else printf ABSENT; fi" 2>/dev/null) || return 1
    if [[ "$remote_state" == "PRESENT" ]]; then
        state="present"
        mkdir -p "$(dirname "$destination")" || return 1
        scp -o ConnectTimeout=5 -p -q "root@${node}:${path}" "$destination" || return 1
    elif [[ "$remote_state" != "ABSENT" || "$path" == "$NODES_PM" ]]; then
        return 1
    fi
    printf '%s\t%s\t%s\n' "$state" "$node" "$path" >> "${backup_dir}/remote-inventory.tsv"
    regenerate_backup_checksums "$backup_dir" || return 1
}

backup_remote_sensor_state() {
    local node="$1"
    local product_dir=""
    local baseline_id=""
    [[ "$TRANSACTION_ACTIVE" == "true" && -n "$TRANSACTION_BACKUP_ID" ]] || return 1
    backup_remote_path_to "$TRANSACTION_BACKUP_ID" "$node" "$NODES_PM" || return 1
    backup_remote_path_to "$TRANSACTION_BACKUP_ID" "$node" "$SENSORS_FILTER" || return 1

    product_dir=$(product_backup_dir)
    if [[ -f "${product_dir}/baseline" ]]; then
        baseline_id=$(tr -d ' \t\r\n' < "${product_dir}/baseline")
        if [[ "$baseline_id" != "$TRANSACTION_BACKUP_ID" ]]; then
            backup_remote_path_to "$baseline_id" "$node" "$NODES_PM" || return 1
            backup_remote_path_to "$baseline_id" "$node" "$SENSORS_FILTER" || return 1
        fi
    fi
}

record_installed_path() {
    local path="$1"
    backup_path_is_allowed "$path" || return 1
    mkdir -p "$INSTALL_DIR"
    touch "$INSTALLED_PATHS_FILE"
    grep -qxF "$path" "$INSTALLED_PATHS_FILE" 2>/dev/null || printf '%s\n' "$path" >> "$INSTALLED_PATHS_FILE"
}

# Restore package-owned files before a reinstall. This deliberately uses the
# currently installed package version instead of the stale legacy snapshot.
restore_packages() {
    local package="proxmox-widget-toolkit"
    [[ "$PRODUCT" == "PDM" ]] && package="proxmox-datacenter-manager-ui"
    print_info "Reinstalling ${package} to clean package-owned files..."
    apt-get -qq -o Dpkg::Use-Pty=0 reinstall "$package" 2>/dev/null
    print_status "Restored ${package}"
}

restore_all_product_packages() {
    local packages=()
    case "$PRODUCT" in
        PVE) packages=(pve-manager pve-cluster proxmox-widget-toolkit novnc-pve) ;;
        PBS) packages=(proxmox-backup-server proxmox-widget-toolkit) ;;
        PDM) packages=(proxmox-datacenter-manager-ui) ;;
    esac
    print_info "Reinstalling current ${PRODUCT} web packages for a clean uninstall..."
    apt-get -qq -o Dpkg::Use-Pty=0 reinstall "${packages[@]}" 2>/dev/null
    print_status "Restored current ${PRODUCT} package-owned files"
}

# Extract theme title from CSS file (first line comment)
get_theme_title() {
    local css_file="$1"
    # First line should be: /*!Theme Name*/
    local title=$(head -1 "$css_file" | sed -n 's|^/\*!\(.*\)\*/.*|\1|p')
    if [[ -z "$title" ]]; then
        # Fallback to filename
        title=$(basename "$css_file" .css | sed 's/theme-//' | sed 's/-/ /g' | sed 's/\b\(.\)/\u\1/g')
    fi
    echo "$title"
}

# Extract theme key from filename
get_theme_key() {
    local css_file="$1"
    basename "$css_file" .css | sed 's/^theme-//'
}

# Add theme to theme_map in proxmoxlib.js
patch_theme_map() {
    local theme_key="$1"
    local theme_title="$2"
    
    # Check if theme already exists
    if grep -q "\"${theme_key}\":" "$PROXMOXLIB_JS"; then
        print_info "Theme '${theme_key}' already registered"
        return 0
    fi

    local theme_anchor_count
    theme_anchor_count=$(grep -cF 'theme_map: {' "$PROXMOXLIB_JS" 2>/dev/null || true)
    if [[ "$theme_anchor_count" -ne 1 ]]; then
        print_error "Cannot safely register ${theme_title}: expected one theme_map anchor, found ${theme_anchor_count}"
        return 1
    fi
    
    # Add theme to theme_map
    sed -i "s/theme_map: {/theme_map: {\n\t\"${theme_key}\": \"${theme_title}\",/" "$PROXMOXLIB_JS"
    
    if grep -q "\"${theme_key}\":" "$PROXMOXLIB_JS"; then
        print_theme "Registered: ${theme_title}"
        return 0
    else
        print_error "Failed to register ${theme_title}"
        return 1
    fi
}

# JavaScript Patches Configuration (Dynamic markers)
JS_PATCH_MARKER="<!-- ProxMorph JS Patches -->"
JS_PATCH_MARKER_END="<!-- /ProxMorph JS Patches -->"
NOVNC_PATCH_MARKER="<!-- ProxMorph noVNC Clipboard -->"
NOVNC_PATCH_MARKER_END="<!-- /ProxMorph noVNC Clipboard -->"

# Server-side default theme (issue #52)
DEFAULT_THEME_FILE="${CONFIG_DIR}/default-theme"
DEFAULT_THEME_MARKER="<!-- ProxMorph Default Theme -->"
DEFAULT_THEME_MARKER_END="<!-- /ProxMorph Default Theme -->"

# PDM CSS Theme Override Configuration (Dynamic markers)
PDM_CSS_MARKER="<!-- ProxMorph PDM Theme -->"
PDM_CSS_MARKER_END="<!-- /ProxMorph PDM Theme -->"

get_pve_preferences_api_source() {
    local installer_source="${BASH_SOURCE[0]:-}"
    local candidate=""

    for candidate in \
        "$(dirname "$installer_source")/${PVE_PREFERENCES_SOURCE_RELATIVE}" \
        "${INSTALL_DIR}/${PVE_PREFERENCES_SOURCE_RELATIVE}"; do
        [[ -f "$candidate" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done

    return 1
}

validate_marker_pair() {
    local path="$1"
    local start_marker="$2"
    local end_marker="$3"
    local start_count=0
    local end_count=0

    start_count=$(grep -cF "$start_marker" "$path" 2>/dev/null || true)
    end_count=$(grep -cF "$end_marker" "$path" 2>/dev/null || true)
    if [[ "$start_count" -eq 0 && "$end_count" -eq 0 ]]; then
        return 0
    fi
    if [[ "$start_count" -eq 1 && "$end_count" -eq 1 ]]; then
        return 0
    fi

    print_error "Unbalanced ProxMorph marker block in ${path}"
    return 1
}

remove_marker_block() {
    local path="$1"
    local start_marker="$2"
    local end_marker="$3"
    local temporary=""

    validate_marker_pair "$path" "$start_marker" "$end_marker" || return 1
    grep -qF "$start_marker" "$path" 2>/dev/null || return 0
    temporary=$(mktemp)
    awk \
        -v start="$start_marker" \
        -v finish="$end_marker" \
        'BEGIN { skipping = 0 }
         index($0, start) { skipping = 1; next }
         index($0, finish) { skipping = 0; next }
         !skipping { print }
         END { if (skipping) exit 42 }' \
        "$path" > "$temporary" || {
            rm -f "$temporary"
            return 1
        }
    mv "$temporary" "$path"
    chmod 644 "$path"
}

install_pve_preferences_api() {
    [[ "$PRODUCT" == "PVE" ]] || return 0

    local source=""
    local cached_source="${INSTALL_DIR}/${PVE_PREFERENCES_SOURCE_RELATIVE}"
    local temporary=""

    source=$(get_pve_preferences_api_source) || {
        print_error "ProxMorph preferences API source is missing: ${PVE_PREFERENCES_SOURCE_RELATIVE}"
        return 1
    }
    [[ -f "$PVE_CLUSTER_PM" && -f "$PVE_API2_PM" ]] || {
        print_error "Required PVE Perl modules are missing"
        return 1
    }

    mkdir -p "$(dirname "$cached_source")"
    if [[ "$source" != "$cached_source" ]]; then
        cp "$source" "$cached_source"
    fi

    remove_marker_block "$PVE_CLUSTER_PM" "$PVE_CLUSTER_PREFS_MARKER" "$PVE_CLUSTER_PREFS_MARKER_END"
    temporary=$(mktemp)
    awk \
        -v start="$PVE_CLUSTER_PREFS_MARKER" \
        -v finish="$PVE_CLUSTER_PREFS_MARKER_END" \
        -v config="    'priv/proxmorph-user-preferences.json' => 1," \
        'BEGIN { inserted = 0 }
         { print }
         !inserted && $0 == "my $observed = {" {
             print "    " start
             print config
             print "    " finish
             inserted = 1
         }
         END { if (!inserted) exit 42 }' \
        "$PVE_CLUSTER_PM" > "$temporary" || {
            rm -f "$temporary"
            print_error "Could not patch the PVE cluster preferences registry"
            return 1
        }
    mv "$temporary" "$PVE_CLUSTER_PM"
    chmod 644 "$PVE_CLUSTER_PM"

    mkdir -p "$(dirname "$PVE_PROXMORPH_API_PM")"
    cp "$cached_source" "$PVE_PROXMORPH_API_PM"
    chmod 644 "$PVE_PROXMORPH_API_PM"
    if ! perl -c "$PVE_PROXMORPH_API_PM" >/dev/null; then
        print_error "ProxMorph preferences API failed its Perl syntax/load check"
        return 1
    fi

    remove_marker_block "$PVE_API2_PM" "$PVE_API_PREFS_MARKER" "$PVE_API_PREFS_MARKER_END"
    temporary=$(mktemp)
    awk \
        -v start="$PVE_API_PREFS_MARKER" \
        -v finish="$PVE_API_PREFS_MARKER_END" \
        'BEGIN { inserted = 0 }
         !inserted && $0 == "use base qw(PVE::RESTHandler);" {
             print
             print ""
             print start
             print "use PVE::API2::ProxMorph;"
             print ""
             print "__PACKAGE__->register_method({"
             print "    subclass => \"PVE::API2::ProxMorph\","
             print "    path => '\''proxmorph'\'',"
             print "});"
             print finish
             inserted = 1
             next
         }
         { print }
         END { if (!inserted) exit 42 }' \
        "$PVE_API2_PM" > "$temporary" || {
            rm -f "$temporary"
            print_error "Could not register the ProxMorph preferences API"
            return 1
        }
    mv "$temporary" "$PVE_API2_PM"
    chmod 644 "$PVE_API2_PM"
    if ! perl -c "$PVE_API2_PM" >/dev/null; then
        print_error "PVE API root failed its Perl syntax/load check after registration"
        return 1
    fi

    record_installed_path "$PVE_PROXMORPH_API_PM"
    record_installed_path "$PVE_PREFERENCES_FILE"
    print_status "Enabled cluster-wide per-user Inventory View preferences"
}

remove_pve_preferences_api() {
    [[ "$PRODUCT" == "PVE" ]] || return 0

    if [[ -f "$PVE_API2_PM" ]]; then
        remove_marker_block "$PVE_API2_PM" "$PVE_API_PREFS_MARKER" "$PVE_API_PREFS_MARKER_END"
    fi
    if [[ -f "$PVE_CLUSTER_PM" ]]; then
        remove_marker_block "$PVE_CLUSTER_PM" "$PVE_CLUSTER_PREFS_MARKER" "$PVE_CLUSTER_PREFS_MARKER_END"
    fi
    if path_exists "$PVE_PROXMORPH_API_PM"; then
        remove_exact_path "$PVE_PROXMORPH_API_PM"
    fi
    if path_exists "$PVE_PREFERENCES_FILE"; then
        remove_exact_path "$PVE_PREFERENCES_FILE"
    fi
}

install_novnc_clipboard() {
    [[ "$PRODUCT" == "PVE" ]] || return 0

    local themes_source="${1:-}"
    local novnc_source=""
    local module_url=""
    local temporary_block=""
    local temporary_output=""

    if [[ -z "$themes_source" ]]; then
        themes_source=$(get_themes_source || true)
    fi
    novnc_source="${themes_source}/novnc"

    if [[ ! -f "${novnc_source}/proxmorph-novnc.js" || ! -f "${novnc_source}/proxmorph-novnc.css" ]]; then
        print_error "ProxMorph noVNC clipboard assets are missing from ${novnc_source}"
        return 1
    fi
    if [[ ! -f "$NOVNC_INDEX_TPL" ]]; then
        print_error "Proxmox noVNC template not found: ${NOVNC_INDEX_TPL}"
        return 1
    fi

    module_url=$(sed -nE 's@.*import UI from "([^"]*/novnc/app\.js[^"]*)";.*@\1@p' "$NOVNC_INDEX_TPL" | head -1)
    if [[ -z "$module_url" ]]; then
        print_error "Could not resolve the native noVNC application module from ${NOVNC_INDEX_TPL}"
        return 1
    fi

    mkdir -p "$NOVNC_PROXMORPH_DIR"
    cp "${novnc_source}/proxmorph-novnc.js" "${NOVNC_PROXMORPH_DIR}/proxmorph-novnc.js"
    cp "${novnc_source}/proxmorph-novnc.css" "${NOVNC_PROXMORPH_DIR}/proxmorph-novnc.css"
    chmod 644 "${NOVNC_PROXMORPH_DIR}/proxmorph-novnc.js" "${NOVNC_PROXMORPH_DIR}/proxmorph-novnc.css"

    remove_marker_block "$NOVNC_INDEX_TPL" "$NOVNC_PATCH_MARKER" "$NOVNC_PATCH_MARKER_END"
    temporary_block=$(mktemp)
    cat > "$temporary_block" << BLOCK
${NOVNC_PATCH_MARKER}
<link rel="stylesheet" href="/novnc/proxmorph/proxmorph-novnc.css?ver=${TARGET_VERSION}">
<script type="module">
import ProxMorphUI from "${module_url}";
window.ProxMorphNoVNCUI = ProxMorphUI;
import("/novnc/proxmorph/proxmorph-novnc.js?ver=${TARGET_VERSION}");
</script>
${NOVNC_PATCH_MARKER_END}
BLOCK
    temporary_output=$(mktemp)
    awk -v blockfile="$temporary_block" \
        'BEGIN { inserted = 0; while ((getline line < blockfile) > 0) block = block (block ? "\n" : "") line }
         !inserted && /<\/head>/ { print block; inserted = 1 }
         { print }
         END { if (!inserted) exit 42 }' \
        "$NOVNC_INDEX_TPL" > "$temporary_output" || {
            rm -f "$temporary_block" "$temporary_output"
            print_error "Could not inject the ProxMorph noVNC clipboard loader"
            return 1
        }
    mv "$temporary_output" "$NOVNC_INDEX_TPL"
    chmod 644 "$NOVNC_INDEX_TPL"
    rm -f "$temporary_block"

    record_installed_path "$NOVNC_PROXMORPH_DIR"
    print_status "Enabled the native noVNC clipboard toolbar and Option/Alt + right-click menu"
}

remove_novnc_clipboard() {
    [[ "$PRODUCT" == "PVE" ]] || return 0

    if [[ -f "$NOVNC_INDEX_TPL" ]]; then
        remove_marker_block "$NOVNC_INDEX_TPL" "$NOVNC_PATCH_MARKER" "$NOVNC_PATCH_MARKER_END"
    fi
    if path_exists "$NOVNC_PROXMORPH_DIR"; then
        remove_exact_path "$NOVNC_PROXMORPH_DIR"
    fi
}

# Install JavaScript patches
install_js_patches() {
    local patches_source="${1:-}"
    
    if [[ -z "$patches_source" ]]; then
        local themes_source=$(get_themes_source)
        if [[ -n "$themes_source" ]] && [[ -d "${themes_source}/patches" ]]; then
            patches_source="${themes_source}/patches"
        fi
    fi
    
    if [[ -z "$patches_source" ]] || [[ ! -d "$patches_source" ]]; then
        print_info "No JavaScript patches found (optional)"
        return 0
    fi
    
    local js_count=$(find "$patches_source" -name "*.js" 2>/dev/null | wc -l)
    if [[ $js_count -eq 0 ]]; then
        print_info "No JavaScript patches to install"
        return 0
    fi
    
    print_info "Installing $js_count JavaScript patch(es) for ${PRODUCT}..."
    
    # Create JS patches directory
    mkdir -p "$JS_PATCHES_DIR"
    
    # Copy JS files
    for js_file in "$patches_source"/*.js; do
        if [[ -f "$js_file" ]]; then
            cp "$js_file" "${JS_PATCHES_DIR}/"
            chmod 644 "${JS_PATCHES_DIR}/$(basename "$js_file")"
            print_theme "Installed: $(basename "$js_file")"
        fi
    done
    record_installed_path "$JS_PATCHES_DIR"
    
    # Patch index template to load JS files
    if [[ -f "$INDEX_TEMPLATE" ]]; then
        if ! grep -q '</body>' "$INDEX_TEMPLATE"; then
            print_error "Cannot install JavaScript patches: no </body> insertion point in ${INDEX_TEMPLATE}"
            return 1
        fi
        # If already patched, remove old block so we re-generate with current file list
        if grep -q "$JS_PATCH_MARKER" "$INDEX_TEMPLATE"; then
            local escaped_start_jp=$(printf '%s\n' "$JS_PATCH_MARKER" | sed 's/[]\/$*.^[]/\\&/g')
            local escaped_end_jp=$(printf '%s\n' "$JS_PATCH_MARKER_END" | sed 's/[]\/$*.^[]/\\&/g')
            sed -i "/${escaped_start_jp}/,/${escaped_end_jp}/d" "$INDEX_TEMPLATE"
            print_info "Refreshing JS patch list in $(basename "$INDEX_TEMPLATE")"
        fi
        {
            local script_tags="$JS_PATCH_MARKER"
            local js_web_path=""
            
            if [[ "$PRODUCT" == "PVE" ]]; then
                js_web_path="/pve2/js/proxmorph"
            elif [[ "$PRODUCT" == "PDM" ]]; then
                js_web_path="/pdm/js/proxmorph"
            else
                js_web_path="/js/proxmorph"
            fi
            
            for js_file in "${JS_PATCHES_DIR}"/*.js; do
                if [[ -f "$js_file" ]]; then
                    local js_name=$(basename "$js_file")
                    script_tags="${script_tags}\n<script src=\"${js_web_path}/${js_name}\"></script>"
                fi
            done
            script_tags="${script_tags}\n${JS_PATCH_MARKER_END}"
            
            # Insert before </body>
            sed -i "s|</body>|${script_tags}\n</body>|" "$INDEX_TEMPLATE"
            print_status "Patched $(basename "$INDEX_TEMPLATE") with JS loader"
        }
    else
        print_warning "$(basename "$INDEX_TEMPLATE") not found - JS patches may not load"
    fi
}

# Remove JavaScript patches
remove_js_patches() {
    if [[ -d "$JS_PATCHES_DIR" ]]; then
        rm -rf "$JS_PATCHES_DIR"
        print_info "Removed JS patches directory"
    fi
    
    if [[ -f "$INDEX_TEMPLATE" ]] && grep -q "$JS_PATCH_MARKER" "$INDEX_TEMPLATE"; then
        local escaped_start=$(printf '%s\n' "$JS_PATCH_MARKER" | sed 's/[]\/$*.^[]/\\&/g')
        local escaped_end=$(printf '%s\n' "$JS_PATCH_MARKER_END" | sed 's/[]\/$*.^[]/\\&/g')
        sed -i "\|${escaped_start}|,\|${escaped_end}|d" "$INDEX_TEMPLATE"
        print_info "Removed JS patch from $(basename "$INDEX_TEMPLATE")"
    fi
}

# --- Server-side default theme (issue #52) ---

# Print configured default theme key (empty if none)
get_default_theme() {
    [[ -f "$DEFAULT_THEME_FILE" ]] && tr -d ' \t\r\n' < "$DEFAULT_THEME_FILE"
    return 0
}

# Remove the default-theme block from the index template
remove_default_theme_injection() {
    if [[ -f "$INDEX_TEMPLATE" ]] && grep -q "$DEFAULT_THEME_MARKER" "$INDEX_TEMPLATE"; then
        local esc_start=$(printf '%s\n' "$DEFAULT_THEME_MARKER" | sed 's/[]\/$*.^[]/\\&/g')
        local esc_end=$(printf '%s\n' "$DEFAULT_THEME_MARKER_END" | sed 's/[]\/$*.^[]/\\&/g')
        sed -i "\|${esc_start}|,\|${esc_end}|d" "$INDEX_TEMPLATE"
        print_info "Removed default theme injection from $(basename "$INDEX_TEMPLATE")"
    fi
}

# Inject the default-theme bootstrap script into the index template (PVE/PBS).
# When no theme cookie exists, it sets the cookie to the configured default and
# writes the theme <link> synchronously so the first paint is already themed.
# An existing cookie (any user choice, incl. stock themes) always wins.
inject_default_theme() {
    [[ "$PRODUCT" == "PDM" ]] && return 0
    [[ -f "$INDEX_TEMPLATE" ]] || return 0

    # Always start clean (also handles default changed/removed)
    remove_default_theme_injection

    local default_key=$(get_default_theme)
    [[ -z "$default_key" ]] && return 0

    # Key must satisfy the proxy's cookie validation regex
    if ! [[ "$default_key" =~ ^[a-z]{1,10}(-[a-z]{1,10}){0,5}$ ]]; then
        print_warning "Default theme key '${default_key}' is invalid (lowercase kebab-case, segments max 10 chars) - skipping"
        return 0
    fi
    if [[ ! -f "${THEMES_DIR}/theme-${default_key}.css" ]]; then
        print_warning "Default theme 'theme-${default_key}.css' not installed - skipping injection"
        return 0
    fi

    local tmpblock=$(mktemp)
    cat > "$tmpblock" << BLOCK
${DEFAULT_THEME_MARKER}
<script>
(function() {
    if (document.cookie.indexOf('${THEME_COOKIE}=') !== -1) { return; }
    var k = '${default_key}';
    var d = new Date(); d.setFullYear(d.getFullYear() + 10);
    document.cookie = '${THEME_COOKIE}=' + k + '; expires=' + d.toUTCString() + '; path=/';
    document.write('<link rel="stylesheet" type="text/css" href="${THEME_WEB_PATH}/theme-' + k + '.css">');
})();
</script>
${DEFAULT_THEME_MARKER_END}
BLOCK
    local tmpout=$(mktemp)
    awk -v blockfile="$tmpblock" 'BEGIN{done=0; while((getline line < blockfile)>0) block=block (block?"\n":"") line} !done && /<\/head>/{print block; done=1} {print}' "$INDEX_TEMPLATE" > "$tmpout"
    mv "$tmpout" "$INDEX_TEMPLATE"
    chmod 644 "$INDEX_TEMPLATE"
    rm -f "$tmpblock"
    print_status "Default theme '${default_key}' injected into $(basename "$INDEX_TEMPLATE")"
}

# CLI: ./install.sh default-theme [key|none]
manage_default_theme() {
    local arg="${1:-}"
    local owns_transaction=false

    if [[ -z "$arg" ]]; then
        local current=$(get_default_theme)
        if [[ -n "$current" ]]; then
            print_info "Server-side default theme: ${current}"
        else
            print_info "No server-side default theme configured"
        fi
        print_info "Usage: $0 default-theme <key|none>"
        print_info "Installed theme keys:"
        for css_file in "${THEMES_DIR}"/theme-*.css; do
            [[ -f "$css_file" ]] && print_theme "  $(basename "$css_file" .css | sed 's/^theme-//')"
        done
        return 0
    fi

    if [[ "$arg" != "none" ]]; then
        if [[ "$PRODUCT" == "PDM" ]]; then
            if [[ ! -f "${PDM_THEMES_DIR}/theme-${arg}.css" ]]; then
                print_error "Theme 'theme-${arg}.css' is not installed"
                return 1
            fi
        elif [[ ! -f "${THEMES_DIR}/theme-${arg}.css" ]]; then
            print_error "Theme 'theme-${arg}.css' is not installed"
            return 1
        fi
    fi

    if [[ "$TRANSACTION_ACTIVE" != "true" ]]; then
        begin_transaction "default-theme"
        owns_transaction=true
    fi

    if [[ "$arg" == "none" ]]; then
        rm -f "$DEFAULT_THEME_FILE"
        if [[ "$PRODUCT" == "PDM" ]]; then
            local pdm_src=$(get_themes_source)
            [[ -n "$pdm_src" ]] && install_pdm_themes "$pdm_src"
        else
            remove_default_theme_injection
        fi
        print_status "Server-side default theme removed"
    else
        mkdir -p "$(dirname "$DEFAULT_THEME_FILE")"
        echo "$arg" > "$DEFAULT_THEME_FILE"
        if [[ "$PRODUCT" == "PDM" ]]; then
            local pdm_src=$(get_themes_source)
            [[ -n "$pdm_src" ]] && install_pdm_themes "$pdm_src"
        else
            inject_default_theme
        fi
        print_status "Server-side default theme set to '${arg}'"
    fi

    print_info "Restarting ${PROXY_SERVICE} service in background..."
    nohup systemctl restart "${PROXY_SERVICE}" &>/dev/null &
    if [[ "$owns_transaction" == "true" ]]; then
        commit_transaction
    fi
}

# Install PDM CSS theme overrides into index.hbs
# PDM themes work by injecting a <link> tag that overrides --pwt-color-* tokens
# from the WASM-loaded base theme (Crisp/Desktop/Material)
install_pdm_themes() {
    local themes_source="$1"

    print_info "Installing PDM theme overrides..."

    mkdir -p "$PDM_THEMES_DIR"
    mkdir -p "$PDM_JS_PATCHES_DIR"

    # Copy base component CSS (always-on styling: rounded corners, shadows, etc.)
    local base_css="${themes_source}/proxmorph-pdm-base.css"
    if [[ -f "$base_css" ]]; then
        cp "$base_css" "${PDM_THEMES_DIR}/"
        chmod 644 "${PDM_THEMES_DIR}/proxmorph-pdm-base.css"
        print_info "Installed PDM base component styles"
    fi

    local theme_count=0
    for css_file in "$themes_source"/theme-*.css; do
        if [[ -f "$css_file" ]]; then
            cp "$css_file" "${PDM_THEMES_DIR}/"
            chmod 644 "${PDM_THEMES_DIR}/$(basename "$css_file")"
            local title=$(get_theme_title "$css_file")
            print_theme "Installed: ${title}"
            theme_count=$((theme_count + 1))
        fi
    done

    if [[ $theme_count -eq 0 ]]; then
        print_warning "No PDM theme files found"
        return 1
    fi

    # Copy theme selector JS patch
    # themes_source is either .../themes/pdm or /opt/proxmorph/themes/pdm
    # The JS patch lives in .../themes/patches/ (sibling to pdm/)
    local patches_dir="$(dirname "$themes_source")/patches"
    local selector_js="${patches_dir}/pdm-theme-selector.js"
    if [[ -f "$selector_js" ]]; then
        cp "$selector_js" "${PDM_JS_PATCHES_DIR}/"
        chmod 644 "${PDM_JS_PATCHES_DIR}/pdm-theme-selector.js"
        print_info "Installed PDM theme selector patch"
    fi

    # Inject CSS <link> tags + JS into index.hbs
    if [[ -f "$INDEX_TEMPLATE" ]]; then
        # Remove old block if present
        if grep -q "$PDM_CSS_MARKER" "$INDEX_TEMPLATE"; then
            local esc_start=$(printf '%s\n' "$PDM_CSS_MARKER" | sed 's/[]\/$*.^[]/\\&/g')
            local esc_end=$(printf '%s\n' "$PDM_CSS_MARKER_END" | sed 's/[]\/$*.^[]/\\&/g')
            sed -i "\|${esc_start}|,\|${esc_end}|d" "$INDEX_TEMPLATE"
            print_info "Refreshing PDM theme links in $(basename "$INDEX_TEMPLATE")"
        fi

        # Build injection block as a temp file (avoids sed multiline issues)
        local tmpblock=$(mktemp)
        echo "$PDM_CSS_MARKER" > "$tmpblock"

        # Base CSS — always enabled (component styles)
        echo "<link rel=\"stylesheet\" href=\"/proxmorph-themes/proxmorph-pdm-base.css\" class=\"proxmorph-base\" disabled>" >> "$tmpblock"

        # Theme CSS links — disabled by default, activated by JS
        for css_file in "${PDM_THEMES_DIR}"/theme-*.css; do
            if [[ -f "$css_file" ]]; then
                local css_name=$(basename "$css_file")
                echo "<link rel=\"stylesheet\" href=\"/proxmorph-themes/${css_name}\" class=\"proxmorph-theme\" disabled>" >> "$tmpblock"
            fi
        done

        # Server-side default theme (fallback only, user choice in localStorage wins)
        local pdm_default=$(get_default_theme)
        if [[ -n "$pdm_default" ]] && [[ -f "${PDM_THEMES_DIR}/theme-${pdm_default}.css" ]]; then
            echo "<script>window.__PM_DEFAULT = 'theme-${pdm_default}.css';</script>" >> "$tmpblock"
            print_info "PDM default theme: theme-${pdm_default}.css"
        fi

        # Inline activation script (runs before WASM loads)
        cat >> "$tmpblock" << 'JSBLOCK'
<script>
(function() {
    var saved = localStorage.getItem('proxmorph-theme') || window.__PM_DEFAULT;
    if (!saved) return;
    // Enable base component styles
    var base = document.querySelector('link.proxmorph-base');
    if (base) base.removeAttribute('disabled');
    // Enable the saved theme
    var links = document.querySelectorAll('link.proxmorph-theme');
    links.forEach(function(l) {
        if (l.href.indexOf(saved) !== -1) l.removeAttribute('disabled');
    });
})();
</script>
JSBLOCK

        # Theme selector patch (injects themes into native PDM Theme dialog)
        echo "<script src=\"/js/proxmorph/pdm-theme-selector.js\"></script>" >> "$tmpblock"

        echo "$PDM_CSS_MARKER_END" >> "$tmpblock"

        # Insert block before first </head> using awk
        local tmpout=$(mktemp)
        awk -v blockfile="$tmpblock" 'BEGIN{done=0; while((getline line < blockfile)>0) block=block (block?"\n":"") line} !done && /<\/head>/{print block; done=1} {print}' "$INDEX_TEMPLATE" > "$tmpout"
        mv "$tmpout" "$INDEX_TEMPLATE"
        chmod 644 "$INDEX_TEMPLATE"
        rm -f "$tmpblock"

        print_status "Injected ${theme_count} theme(s) + base styles + selector patch into $(basename "$INDEX_TEMPLATE")"
        record_installed_path "$PDM_THEMES_DIR"
        record_installed_path "$PDM_JS_PATCHES_DIR"
    else
        print_warning "$(basename "$INDEX_TEMPLATE") not found — PDM themes may not load"
    fi

    print_status "PDM themes installed — ${theme_count} theme(s)"
}

# Remove PDM CSS theme overrides
remove_pdm_themes() {
    if [[ -d "$PDM_THEMES_DIR" ]]; then
        rm -rf "$PDM_THEMES_DIR"
        print_info "Removed PDM theme overrides directory"
    fi
    if [[ -d "$PDM_JS_PATCHES_DIR" ]]; then
        rm -rf "$PDM_JS_PATCHES_DIR"
        print_info "Removed PDM JS patches directory"
    fi
    if [[ -f "$INDEX_TEMPLATE" ]] && grep -q "$PDM_CSS_MARKER" "$INDEX_TEMPLATE"; then
        local esc_start=$(printf '%s\n' "$PDM_CSS_MARKER" | sed 's/[]\/$*.^[]/\\&/g')
        local esc_end=$(printf '%s\n' "$PDM_CSS_MARKER_END" | sed 's/[]\/$*.^[]/\\&/g')
        sed -i "\|${esc_start}|,\|${esc_end}|d" "$INDEX_TEMPLATE"
        print_info "Removed PDM theme links from $(basename "$INDEX_TEMPLATE")"
    fi
}

# APT hook configuration for persistence across updates
APT_HOOK_FILE="/etc/apt/apt.conf.d/99proxmorph"
POST_INVOKE_SCRIPT="${INSTALL_DIR}/post-update.sh"

# Install apt hook for automatic re-patching after updates
install_apt_hook() {
    print_info "Installing apt hook for automatic re-patching..."
    
    mkdir -p "${INSTALL_DIR}"
    cat > "${POST_INVOKE_SCRIPT}" << SCRIPT
#!/bin/bash
# ProxMorph post-update hook - automatically re-patches after updates

PRODUCT="${PRODUCT}"
INSTALL_DIR="${INSTALL_DIR}"
PROXMOXLIB_JS="${PROXMOXLIB_JS}"
WIDGET_TOOLKIT_DIR="${WIDGET_TOOLKIT_DIR}"
INDEX_TEMPLATE="${INDEX_TEMPLATE}"
PVE_MANAGER_JS="${PVE_MANAGER_JS}"
JS_PATCHES_DIR="${JS_PATCHES_DIR}"
PROXY_SERVICE="${PROXY_SERVICE}"
LOG_FILE="${PROXMORPH_LOG_FILE}"
JS_PATCH_MARKER="${JS_PATCH_MARKER}"
JS_PATCH_MARKER_END="${JS_PATCH_MARKER_END}"
PDM_CSS_MARKER="${PDM_CSS_MARKER}"
PDM_CSS_MARKER_END="${PDM_CSS_MARKER_END}"
PDM_THEMES_DIR="${PDM_THEMES_DIR}"
PVE_CLUSTER_PM="${PVE_CLUSTER_PM}"
PVE_API2_PM="${PVE_API2_PM}"
PVE_PROXMORPH_API_PM="${PVE_PROXMORPH_API_PM}"
PVE_PREFERENCES_SOURCE_RELATIVE="${PVE_PREFERENCES_SOURCE_RELATIVE}"
PVE_CLUSTER_PREFS_MARKER="${PVE_CLUSTER_PREFS_MARKER}"
PVE_API_PREFS_MARKER="${PVE_API_PREFS_MARKER}"
NOVNC_INDEX_TPL="${NOVNC_INDEX_TPL}"
NOVNC_PROXMORPH_DIR="${NOVNC_PROXMORPH_DIR}"
NOVNC_PATCH_MARKER="${NOVNC_PATCH_MARKER}"
DEFAULT_THEME_FILE="${DEFAULT_THEME_FILE}"
DEFAULT_THEME_MARKER="${DEFAULT_THEME_MARKER}"
DEFAULT_THEME_MARKER_END="${DEFAULT_THEME_MARKER_END}"
THEME_COOKIE="${THEME_COOKIE}"
THEME_WEB_PATH="${THEME_WEB_PATH}"
BACKUP_ROOT="${BACKUP_ROOT}"
LOCK_FILE="${LOCK_FILE}"

# Set themes source based on product
if [ "\$PRODUCT" = "PDM" ]; then
    THEMES_SOURCE="\${INSTALL_DIR}/themes/pdm"
else
    THEMES_SOURCE="\${INSTALL_DIR}/themes"
fi

log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" >> "\$LOG_FILE"
}

mkdir -p "\$(dirname "\$LOCK_FILE")"
exec 9>"\$LOCK_FILE"
if ! flock -n 9; then
    log "Another ProxMorph operation is active; skipping this re-patch pass"
    exit 0
fi

# Only proceed if themes are installed
if [ ! -d "\$THEMES_SOURCE" ]; then
    exit 0
fi

needs_repatch=false

# PDM repatch check: see if CSS injection is still in index.hbs
if [ "\$PRODUCT" = "PDM" ]; then
    if ! grep -q "\$PDM_CSS_MARKER" "\$INDEX_TEMPLATE" 2>/dev/null; then
        needs_repatch=true
    fi
else
    # PVE/PBS: check if proxmoxlib.js needs patching
    for css_file in "\${THEMES_SOURCE}"/theme-*.css; do
        if [ -f "\$css_file" ]; then
            theme_key=\$(basename "\$css_file" .css | sed 's/^theme-//')
            if ! grep -q "\"\${theme_key}\":" "\$PROXMOXLIB_JS" 2>/dev/null; then
                needs_repatch=true
            fi
            break
        fi
    done
fi

# Check if template needs JS patch (PVE/PBS only)
if [ "\$PRODUCT" != "PDM" ] && [ -d "\${THEMES_SOURCE}/patches" ] && ! grep -q "\$JS_PATCH_MARKER" "\$INDEX_TEMPLATE" 2>/dev/null; then
    needs_repatch=true
fi

# Default theme injection lost after template update? (PVE/PBS)
if [ "\$PRODUCT" != "PDM" ] && [ -f "\$DEFAULT_THEME_FILE" ] && ! grep -q "\$DEFAULT_THEME_MARKER" "\$INDEX_TEMPLATE" 2>/dev/null; then
    needs_repatch=true
fi

# PVE package updates replace both Perl registration points. The custom module
# is compared with the cached release so source updates are also applied.
if [ "\$PRODUCT" = "PVE" ]; then
    preferences_source="\${INSTALL_DIR}/\${PVE_PREFERENCES_SOURCE_RELATIVE}"
    if ! grep -qF "\$PVE_CLUSTER_PREFS_MARKER" "\$PVE_CLUSTER_PM" 2>/dev/null || \
       ! grep -qF "\$PVE_API_PREFS_MARKER" "\$PVE_API2_PM" 2>/dev/null || \
       [ ! -f "\$PVE_PROXMORPH_API_PM" ] || \
       [ ! -f "\$preferences_source" ] || \
       ! cmp -s "\$preferences_source" "\$PVE_PROXMORPH_API_PM"; then
        needs_repatch=true
    fi
fi

# novnc-pve updates replace its template and may replace the managed asset
# directory. Compare both the loader marker and cached release assets.
if [ "\$PRODUCT" = "PVE" ] && [ -d "\${THEMES_SOURCE}/novnc" ]; then
    if ! grep -qF "\$NOVNC_PATCH_MARKER" "\$NOVNC_INDEX_TPL" 2>/dev/null || \
       [ ! -f "\${NOVNC_PROXMORPH_DIR}/proxmorph-novnc.js" ] || \
       [ ! -f "\${NOVNC_PROXMORPH_DIR}/proxmorph-novnc.css" ] || \
       ! cmp -s "\${THEMES_SOURCE}/novnc/proxmorph-novnc.js" "\${NOVNC_PROXMORPH_DIR}/proxmorph-novnc.js" || \
       ! cmp -s "\${THEMES_SOURCE}/novnc/proxmorph-novnc.css" "\${NOVNC_PROXMORPH_DIR}/proxmorph-novnc.css"; then
        needs_repatch=true
    fi
fi

if [ "\$needs_repatch" = "true" ]; then
    # Re-run the same capability checks after a package update. If Proxmox has
    # changed a patch point, leave the new package files untouched and log the
    # exact incompatible contract for the administrator.
    compatibility_error=""
    if [ ! -f "\$INDEX_TEMPLATE" ]; then
        compatibility_error="missing index template: \$INDEX_TEMPLATE"
    elif ! grep -q '</head>' "\$INDEX_TEMPLATE" 2>/dev/null; then
        compatibility_error="missing </head> insertion point in \$INDEX_TEMPLATE"
    elif [ "\$PRODUCT" != "PDM" ] && ! grep -q '</body>' "\$INDEX_TEMPLATE" 2>/dev/null; then
        compatibility_error="missing </body> insertion point in \$INDEX_TEMPLATE"
    fi

    if [ -z "\$compatibility_error" ] && [ "\$PRODUCT" != "PDM" ]; then
        theme_anchor_count=\$(grep -cF 'theme_map: {' "\$PROXMOXLIB_JS" 2>/dev/null || true)
        if [ "\$theme_anchor_count" -ne 1 ]; then
            compatibility_error="expected one theme_map anchor, found \$theme_anchor_count"
        fi
    fi

    if [ -z "\$compatibility_error" ] && [ "\$PRODUCT" = "PVE" ]; then
        if [ ! -f "\$PVE_MANAGER_JS" ]; then
            compatibility_error="missing PVE manager JavaScript bundle: \$PVE_MANAGER_JS"
        else
            for pve_ui_contract in 'PVE.form.ViewSelector' 'PVE.tree.ResourceTree' 'PVE.node.StatusView' 'PVE.panel.Config' 'PVE.sdn.VnetEdit' 'PVE.sdn.SubnetView' 'PVE.sdn.VnetACLView' 'PVE.dc.CmdMenu' 'PVE.node.CmdMenu'; do
                if ! grep -qF "\$pve_ui_contract" "\$PVE_MANAGER_JS"; then
                    compatibility_error="missing PVE UI extension point: \$pve_ui_contract"
                    break
                fi
            done
        fi
    fi

    if [ -z "\$compatibility_error" ] && [ "\$PRODUCT" = "PVE" ]; then
        if [ ! -f "\$NOVNC_INDEX_TPL" ]; then
            compatibility_error="missing Proxmox noVNC template: \$NOVNC_INDEX_TPL"
        else
            novnc_app_anchor_count=\$(grep -cF 'import UI from "/novnc/app.js' "\$NOVNC_INDEX_TPL" 2>/dev/null || true)
            novnc_clipboard_anchor_count=\$(grep -cF 'id="noVNC_clipboard_button"' "\$NOVNC_INDEX_TPL" 2>/dev/null || true)
            if [ "\$novnc_app_anchor_count" -ne 1 ]; then
                compatibility_error="expected one noVNC application module anchor, found \$novnc_app_anchor_count"
            elif [ "\$novnc_clipboard_anchor_count" -ne 1 ]; then
                compatibility_error="expected one native noVNC clipboard control, found \$novnc_clipboard_anchor_count"
            elif ! grep -q '</head>' "\$NOVNC_INDEX_TPL" 2>/dev/null; then
                compatibility_error="missing </head> insertion point in \$NOVNC_INDEX_TPL"
            fi
        fi
    fi

    if [ -z "\$compatibility_error" ] && [ "\$PRODUCT" = "PVE" ]; then
        preferences_source="\${INSTALL_DIR}/\${PVE_PREFERENCES_SOURCE_RELATIVE}"
        if [ ! -f "\$preferences_source" ]; then
            compatibility_error="missing cached preferences API: \$preferences_source"
        elif [ ! -f "\$PVE_CLUSTER_PM" ]; then
            compatibility_error="missing PVE cluster module: \$PVE_CLUSTER_PM"
        elif [ ! -f "\$PVE_API2_PM" ]; then
            compatibility_error="missing PVE API root module: \$PVE_API2_PM"
        else
            cluster_preferences_anchor_count=\$(grep -cF 'my \$observed = {' "\$PVE_CLUSTER_PM" 2>/dev/null || true)
            preferences_api_anchor_count=\$(grep -cF 'use base qw(PVE::RESTHandler);' "\$PVE_API2_PM" 2>/dev/null || true)
            if [ "\$cluster_preferences_anchor_count" -ne 1 ]; then
                compatibility_error="expected one cluster preferences anchor, found \$cluster_preferences_anchor_count"
            elif [ "\$preferences_api_anchor_count" -ne 1 ]; then
                compatibility_error="expected one preferences API anchor, found \$preferences_api_anchor_count"
            fi
        fi
    fi

    if [ -z "\$compatibility_error" ] && [ "\$PRODUCT" = "PVE" ] && [ -f "\${INSTALL_DIR}/.sensors-enabled" ]; then
        nodes_pm="/usr/share/perl5/PVE/API2/Nodes.pm"
        sensor_anchor_count=\$(grep -cE '^[[:space:]]*my \\\$dinfo = df' "\$nodes_pm" 2>/dev/null || true)
        if [ "\$sensor_anchor_count" -ne 1 ]; then
            compatibility_error="expected one Nodes.pm sensor anchor, found \$sensor_anchor_count"
        fi
    fi

    if [ -n "\$compatibility_error" ]; then
        log "ERROR: Proxmox update is not compatible with the installed ProxMorph patch set: \$compatibility_error. No files changed."
        exit 0
    fi

    # The package update has now supplied clean, current-version files. Snapshot
    # the complete ProxMorph footprint before re-patching them, then restore that
    # snapshot automatically if any command below fails.
    if ! PROXMORPH_SKIP_LOCK=true PROXMORPH_BACKUP_ROOT="\$BACKUP_ROOT" "\${INSTALL_DIR}/install.sh" backup "apt-repatch" >> "\$LOG_FILE" 2>&1; then
        log "ERROR: Could not create the pre-repatch backup. New package files were left untouched."
        exit 0
    fi
    product_slug=\$(printf '%s' "\$PRODUCT" | tr '[:upper:]' '[:lower:]')
    transaction_backup_id=\$(tr -d ' \t\r\n' < "\${BACKUP_ROOT}/\${product_slug}/latest" 2>/dev/null || true)
    if [ -z "\$transaction_backup_id" ]; then
        log "ERROR: Backup completed without a resolvable backup ID. New package files were left untouched."
        exit 0
    fi
    rollback_repatch() {
        trap - ERR
        set +e
        log "ERROR: Re-patch failed; restoring backup \$transaction_backup_id"
        if PROXMORPH_SKIP_LOCK=true PROXMORPH_BACKUP_ROOT="\$BACKUP_ROOT" "\${INSTALL_DIR}/install.sh" restore "\$transaction_backup_id" --yes --force >> "\$LOG_FILE" 2>&1; then
            log "Automatic re-patch rollback completed"
        else
            log "CRITICAL: Automatic rollback failed. Run \${INSTALL_DIR}/install.sh restore \$transaction_backup_id --yes --force"
        fi
        exit 0
    }
    set -Ee
    trap rollback_repatch ERR

    log "Detected \$PRODUCT update, re-applying ProxMorph patches..."

    if [ "\$PRODUCT" = "PDM" ]; then
        # PDM: Re-inject CSS overrides into index.hbs
        mkdir -p "\$PDM_THEMES_DIR"
        mkdir -p "\$PDM_JS_PATCHES_DIR"

        # Copy base component CSS
        base_css="\${THEMES_SOURCE}/proxmorph-pdm-base.css"
        if [ -f "\$base_css" ]; then
            cp "\$base_css" "\${PDM_THEMES_DIR}/"
            chmod 644 "\${PDM_THEMES_DIR}/proxmorph-pdm-base.css"
        fi

        for css_file in "\${THEMES_SOURCE}"/theme-*.css; do
            if [ -f "\$css_file" ]; then
                cp "\$css_file" "\${PDM_THEMES_DIR}/"
                chmod 644 "\${PDM_THEMES_DIR}/\$(basename "\$css_file")"
                log "Installed PDM theme: \$(basename "\$css_file")"
            fi
        done

        # Copy theme selector JS patch
        selector_js="\${INSTALL_DIR}/themes/patches/pdm-theme-selector.js"
        if [ -f "\$selector_js" ]; then
            cp "\$selector_js" "\${PDM_JS_PATCHES_DIR}/"
            chmod 644 "\${PDM_JS_PATCHES_DIR}/pdm-theme-selector.js"
        fi

        # Re-inject CSS link tags + JS
        if [ -f "\$INDEX_TEMPLATE" ] && ! grep -q "\$PDM_CSS_MARKER" "\$INDEX_TEMPLATE"; then
            tmpblock=\$(mktemp)
            echo "\$PDM_CSS_MARKER" > "\$tmpblock"

            # Base CSS (always enabled when theme active)
            echo "<link rel=\"stylesheet\" href=\"/proxmorph-themes/proxmorph-pdm-base.css\" class=\"proxmorph-base\" disabled>" >> "\$tmpblock"

            for css_file in "\${PDM_THEMES_DIR}"/theme-*.css; do
                if [ -f "\$css_file" ]; then
                    css_name=\$(basename "\$css_file")
                    echo "<link rel=\"stylesheet\" href=\"/proxmorph-themes/\${css_name}\" class=\"proxmorph-theme\" disabled>" >> "\$tmpblock"
                fi
            done
            if [ -f "\$DEFAULT_THEME_FILE" ]; then
                pdm_default=\$(tr -d ' \t\r\n' < "\$DEFAULT_THEME_FILE")
                if [ -n "\$pdm_default" ] && [ -f "\${PDM_THEMES_DIR}/theme-\${pdm_default}.css" ]; then
                    echo "<script>window.__PM_DEFAULT = 'theme-\${pdm_default}.css';</script>" >> "\$tmpblock"
                fi
            fi
            cat >> "\$tmpblock" << 'JSBLK'
<script>
(function() {
    var saved = localStorage.getItem('proxmorph-theme') || window.__PM_DEFAULT;
    if (!saved) return;
    var base = document.querySelector('link.proxmorph-base');
    if (base) base.removeAttribute('disabled');
    var links = document.querySelectorAll('link.proxmorph-theme');
    links.forEach(function(l) {
        if (l.href.indexOf(saved) !== -1) l.removeAttribute('disabled');
    });
})();
</script>
JSBLK
            echo "<script src=\"/js/proxmorph/pdm-theme-selector.js\"></script>" >> "\$tmpblock"
            echo "\$PDM_CSS_MARKER_END" >> "\$tmpblock"
            tmpout=\$(mktemp)
            awk -v blockfile="\$tmpblock" 'BEGIN{done=0; while((getline line < blockfile)>0) block=block (block?"\n":"") line} !done && /<\/head>/{print block; done=1} {print}' "\$INDEX_TEMPLATE" > "\$tmpout"
            mv "\$tmpout" "\$INDEX_TEMPLATE"
            chmod 644 "\$INDEX_TEMPLATE"
            rm -f "\$tmpblock"
            log "Re-injected PDM theme CSS into \$(basename "\$INDEX_TEMPLATE")"
        fi
    else
        # PVE/PBS: Re-register all themes in proxmoxlib.js
        for css_file in "\${THEMES_SOURCE}"/theme-*.css; do
            if [ -f "\$css_file" ]; then
                theme_key=\$(basename "\$css_file" .css | sed 's/^theme-//')
                theme_title=\$(head -1 "\$css_file" | sed -n 's|^/\*!\(.*\)\*/.*|\1|p')
                if [ -z "\$theme_title" ]; then
                    theme_title=\$(echo "\$theme_key" | sed 's/-/ /g' | sed 's/\b\(.\)/\u\1/g')
                fi

                if ! grep -q "\"\${theme_key}\":" "\$PROXMOXLIB_JS"; then
                    sed -i "s/theme_map: {/theme_map: {\n\t\"\${theme_key}\": \"\${theme_title}\",/" "\$PROXMOXLIB_JS"
                    log "Registered theme: \${theme_title}"
                fi
            fi
        done

        # Re-apply JavaScript patches
        if [ -d "\${THEMES_SOURCE}/patches" ]; then
            mkdir -p "\$JS_PATCHES_DIR"
            for js_file in "\${THEMES_SOURCE}/patches"/*.js; do
                if [ -f "\$js_file" ]; then
                    cp "\$js_file" "\$JS_PATCHES_DIR/"
                    chmod 644 "\$JS_PATCHES_DIR/\$(basename "\$js_file")"
                    log "Installed JS patch: \$(basename "\$js_file")"
                fi
            done

            # Patch template if needed
            if [ -f "\$INDEX_TEMPLATE" ] && ! grep -q "\$JS_PATCH_MARKER" "\$INDEX_TEMPLATE"; then
                script_tags="\$JS_PATCH_MARKER"
                js_web_path=""
                if [ "\$PRODUCT" = "PVE" ]; then
                    js_web_path="/pve2/js/proxmorph"
                else
                    js_web_path="/js/proxmorph"
                fi

                for js_file in "\$JS_PATCHES_DIR"/*.js; do
                    if [ -f "\$js_file" ]; then
                        js_name=\$(basename "\$js_file")
                        script_tags="\${script_tags}\n<script src=\"\${js_web_path}/\${js_name}\"></script>"
                    fi
                done
                script_tags="\${script_tags}\n\$JS_PATCH_MARKER_END"

                sed -i "s|</body>|\${script_tags}\n</body>|" "\$INDEX_TEMPLATE"
                log "Patched \$(basename "\$INDEX_TEMPLATE") with JS loader"
            fi
        fi

        # Re-inject server-side default theme bootstrap (PVE/PBS)
        if [ -f "\$DEFAULT_THEME_FILE" ] && [ -f "\$INDEX_TEMPLATE" ] && ! grep -q "\$DEFAULT_THEME_MARKER" "\$INDEX_TEMPLATE"; then
            default_key=\$(tr -d ' \t\r\n' < "\$DEFAULT_THEME_FILE")
            if [ -n "\$default_key" ] && [ -f "\${WIDGET_TOOLKIT_DIR}/themes/theme-\${default_key}.css" ]; then
                dt_block=\$(mktemp)
                cat > "\$dt_block" << DTBLOCK
\$DEFAULT_THEME_MARKER
<script>
(function() {
    if (document.cookie.indexOf('\${THEME_COOKIE}=') !== -1) { return; }
    var k = '\${default_key}';
    var d = new Date(); d.setFullYear(d.getFullYear() + 10);
    document.cookie = '\${THEME_COOKIE}=' + k + '; expires=' + d.toUTCString() + '; path=/';
    document.write('<link rel="stylesheet" type="text/css" href="\${THEME_WEB_PATH}/theme-' + k + '.css">');
})();
</script>
\$DEFAULT_THEME_MARKER_END
DTBLOCK
                dt_out=\$(mktemp)
                awk -v blockfile="\$dt_block" 'BEGIN{done=0; while((getline line < blockfile)>0) block=block (block?"\n":"") line} !done && /<\/head>/{print block; done=1} {print}' "\$INDEX_TEMPLATE" > "\$dt_out"
                mv "\$dt_out" "\$INDEX_TEMPLATE"
                chmod 644 "\$INDEX_TEMPLATE"
                rm -f "\$dt_block"
                log "Re-injected default theme '\$default_key' into \$(basename "\$INDEX_TEMPLATE")"
            fi
        fi

        # Re-apply Nodes.pm sensor patch if enabled
        SENSORS_CONFIG="\${INSTALL_DIR}/.sensors-enabled"
        SENSORS_FILTER="\${INSTALL_DIR}/.sensors-filter"
        NODES_PM="/usr/share/perl5/PVE/API2/Nodes.pm"
        SENSORS_PATCH_MARKER="# ProxMorph Sensors"
        if [ -f "\$SENSORS_CONFIG" ] && [ -f "\$NODES_PM" ]; then
            sensor_needs_patch=false
            if ! grep -q "\$SENSORS_PATCH_MARKER" "\$NODES_PM" 2>/dev/null; then
                sensor_needs_patch=true
            elif ! grep -q "safe_ups_name" "\$NODES_PM" 2>/dev/null || ! grep -q "/usr/bin/timeout -k 1 3 /usr/bin/upsc" "\$NODES_PM" 2>/dev/null; then
                sed -i "/\${SENSORS_PATCH_MARKER}/,/\${SENSORS_PATCH_MARKER} END/d" "\$NODES_PM"
                sensor_needs_patch=true
                log "Detected legacy Nodes.pm sensor patch, refreshing"
            fi

            if [ "\$sensor_needs_patch" = "true" ]; then
                sed -i "/^[[:space:]]*my \\\$dinfo = df/i\\\\
    \${SENSORS_PATCH_MARKER}\\\\
    local \\\$ENV{PATH} = '/usr/bin:/bin';\\\\
    \\\$res->{sensorsOutput} = \\\`sensors -j 2>/dev/null\\\`;\\\\
    if (-e '\${SENSORS_FILTER}') {\\\\
        if (open(my \\\$fh, '<', '\${SENSORS_FILTER}')) {\\\\
            local \\\$/;\\\\
            \\\$res->{sensorsFilter} = <\\\$fh>;\\\\
            close(\\\$fh);\\\\
        }\\\\
    }\\\\
    if (-x '/usr/bin/upsc') {\\\\
        my \@ups_list = \\\`if [ -x /usr/bin/timeout ]; then /usr/bin/timeout -k 1 3 /usr/bin/upsc -l; else /usr/bin/upsc -l; fi 2>/dev/null\\\`;\\\\
        if (\@ups_list) {\\\\
            chomp(my \\\$ups_name = \\\$ups_list[0]);\\\\
            if (\\\$ups_name && \\\$ups_name =~ /^([A-Za-z0-9_.:-]+)\\\$/) {\\\\
                my \\\$safe_ups_name = \\\$1;\\\\
                \\\$res->{upsData} = \\\`if [ -x /usr/bin/timeout ]; then /usr/bin/timeout -k 1 3 /usr/bin/upsc \\\$safe_ups_name; else /usr/bin/upsc \\\$safe_ups_name; fi 2>/dev/null\\\`;\\\\
            }\\\\
        }\\\\
    }\\\\
    \${SENSORS_PATCH_MARKER} END" "\$NODES_PM"
                if perl -c "\$NODES_PM" 2>/dev/null; then
                    log "Re-patched Nodes.pm for sensor data"
                else
                    log "ERROR: Nodes.pm syntax broken after sensor patch, rolling back"
                    sed -i "/\${SENSORS_PATCH_MARKER}/,/\${SENSORS_PATCH_MARKER} END/d" "\$NODES_PM"
                fi
            fi
        fi

        if [ "\$PRODUCT" = "PVE" ]; then
            PROXMORPH_APT_REPATCH=true \
                PROXMORPH_SKIP_LOCK=true \
                PROXMORPH_BACKUP_ROOT="\$BACKUP_ROOT" \
                "\${INSTALL_DIR}/install.sh" reapply-preferences-api >> "\$LOG_FILE" 2>&1
            log "Re-applied authenticated Inventory View preferences API"
            PROXMORPH_APT_REPATCH=true \
                PROXMORPH_SKIP_LOCK=true \
                PROXMORPH_BACKUP_ROOT="\$BACKUP_ROOT" \
                "\${INSTALL_DIR}/install.sh" reapply-novnc-clipboard >> "\$LOG_FILE" 2>&1
            log "Re-applied native noVNC clipboard enhancement"
        fi
    fi  # end PVE/PBS else branch

    # Protected PVE API routes execute in pvedaemon, while the browser connects
    # through pveproxy. Reload both after a Perl API patch.
    if [ "\$PRODUCT" = "PVE" ]; then
        systemctl restart pvedaemon "\$PROXY_SERVICE" 2>/dev/null || true
    else
        systemctl restart "\$PROXY_SERVICE" 2>/dev/null || true
    fi
    trap - ERR
    log "ProxMorph patches re-applied successfully"
fi
SCRIPT
    chmod +x "${POST_INVOKE_SCRIPT}"
    
    # Create apt hook
    cat > "${APT_HOOK_FILE}" << HOOK
// ProxMorph: Automatically re-patch after updates
DPkg::Post-Invoke { "if [ -x ${POST_INVOKE_SCRIPT} ]; then ${POST_INVOKE_SCRIPT}; fi"; };
HOOK
    
    print_status "Apt hook installed - themes will persist across ${PRODUCT} updates"
}

# Remove apt hook
remove_apt_hook() {
    if [[ -f "${APT_HOOK_FILE}" ]]; then
        rm -f "${APT_HOOK_FILE}"
        print_info "Removed apt hook"
    fi
    if [[ -f "${POST_INVOKE_SCRIPT}" ]]; then
        rm -f "${POST_INVOKE_SCRIPT}"
    fi
}

# Check if apt hook is installed
check_apt_hook() {
    if [[ -f "${APT_HOOK_FILE}" ]] && [[ -f "${POST_INVOKE_SCRIPT}" ]]; then
        return 0
    fi
    return 1
}

# ─── Hardware Sensor Support (PVE only) ─────────────────────────

# Check if lm-sensors is available and what sensors exist
detect_sensors() {
    if [[ "$PRODUCT" != "PVE" ]]; then
        print_warning "Hardware sensor support is only available for Proxmox VE"
        return 1
    fi

    if ! command -v sensors &> /dev/null; then
        print_warning "lm-sensors is not installed"
        print_info "Run '$0 sensors enable' to install and configure it automatically"
        return 1
    fi

    local sensor_output
    sensor_output=$(sensors -j 2>/dev/null) || true

    if [[ -z "$sensor_output" ]]; then
        print_warning "No sensor data is currently available"
        return 1
    fi

    # Report detected sensors
    local has_cpu=false has_nvme=false has_hdd=false has_fan=false has_ups=false

    echo "$sensor_output" | grep -q '"coretemp-isa-\|"k10temp-pci-' && has_cpu=true
    echo "$sensor_output" | grep -q '"nvme-pci-' && has_nvme=true
    echo "$sensor_output" | grep -q '"drivetemp-scsi-' && has_hdd=true
    echo "$sensor_output" | grep -q 'fan[0-9]*_input' && has_fan=true
    command -v upsc &> /dev/null && has_ups=true

    echo ""
    print_info "Detected hardware sensors:"
    [[ "$has_cpu"  == "true" ]] && echo -e "  ${GREEN}●${NC} CPU temperature (coretemp/k10temp)"
    [[ "$has_nvme" == "true" ]] && echo -e "  ${GREEN}●${NC} NVMe drive temperature"
    [[ "$has_hdd"  == "true" ]] && echo -e "  ${GREEN}●${NC} HDD drive temperature (drivetemp)"
    [[ "$has_fan"  == "true" ]] && echo -e "  ${GREEN}●${NC} Fan speed"
    [[ "$has_ups"  == "true" ]] && echo -e "  ${GREEN}●${NC} UPS monitoring (NUT)"

    [[ "$has_cpu" == "false" && "$has_nvme" == "false" && "$has_hdd" == "false" && "$has_fan" == "false" ]] && {
        print_warning "No supported sensors found in lm-sensors output"
        return 1
    }
    echo ""
    return 0
}

install_sensor_package() {
    if package_is_installed lm-sensors; then
        command -v sensors &>/dev/null || {
            print_error "lm-sensors is installed but the sensors command is unavailable"
            print_info "Repair it with: apt-get install --reinstall lm-sensors"
            return 1
        }
        return 0
    fi

    print_info "Installing lm-sensors noninteractively..."
    mkdir -p "$INSTALL_DIR"
    printf 'installed-by-proxmorph\n' > "$SENSORS_PACKAGE_MARKER"
    install_debian_package lm-sensors || return 1
    command -v sensors &>/dev/null || {
        print_error "lm-sensors installed, but the sensors command is unavailable"
        return 1
    }
    print_status "Installed lm-sensors"
}

setup_sensor_runtime() {
    install_sensor_package || return 1
    if detect_sensors; then
        return 0
    fi

    command -v sensors-detect &>/dev/null || {
        print_error "sensors-detect is unavailable after installing lm-sensors"
        return 1
    }
    print_warning "No supported readings are available; automatic hardware detection is required."
    print_warning "sensors-detect probes hardware and cannot be guaranteed safe on every system."
    print_info "Running sensors-detect --auto because sensor setup was explicitly enabled..."
    sensors-detect --auto || {
        print_error "Automatic hardware sensor detection failed"
        return 1
    }
    if ! detect_sensors; then
        print_warning "Detection completed, but supported readings are still unavailable. A reboot may be required."
        return 1
    fi
}

# Enumerate individual sensors from sensors -j output for selection
# Populates SENSOR_LIST array with entries like:
#   "CPU|coretemp-isa-0000|Package id 0|42.0°C"
#   "Fan|it8689-isa-0a40|fan1|850 RPM"
enumerate_sensors() {
    SENSOR_LIST=()
    local sensor_output
    sensor_output=$(sensors -j 2>/dev/null) || true
    if [[ -z "$sensor_output" ]]; then
        return 1
    fi

    # Parse JSON with awk to extract chip keys, labels, and values
    # CPU chips (coretemp, k10temp)
    local cpu_chips
    cpu_chips=$(echo "$sensor_output" | grep -oP '"(coretemp-isa-[^"]+|k10temp-pci-[^"]+)"' | tr -d '"' | sort -u)
    for chip in $cpu_chips; do
        # Get package/Tctl temp
        local temp
        temp=$(echo "$sensor_output" | python3 -c "
import sys,json
try:
    d=json.loads(sys.stdin.read())
    chip=d.get('$chip',{})
    for lbl,v in chip.items():
        if lbl=='Adapter': continue
        if not isinstance(v,dict): continue
        for k,val in v.items():
            if 'input' in k and val is not None:
                print(f'{lbl}|{val}')
                break
except: pass
" 2>/dev/null)
        if [[ -n "$temp" ]]; then
            while IFS='|' read -r label val; do
                SENSOR_LIST+=("CPU|${chip}|${label}|${val}°C")
            done <<< "$temp"
        fi
    done

    # NVMe drives
    local nvme_chips
    nvme_chips=$(echo "$sensor_output" | grep -oP '"(nvme-pci-[^"]+)"' | tr -d '"' | sort -u)
    for chip in $nvme_chips; do
        local temp
        temp=$(echo "$sensor_output" | python3 -c "
import sys,json
try:
    d=json.loads(sys.stdin.read())
    chip=d.get('$chip',{})
    for lbl,v in chip.items():
        if lbl=='Adapter': continue
        if not isinstance(v,dict): continue
        for k,val in v.items():
            if 'input' in k and val is not None:
                print(f'{lbl}|{val}')
                break
except: pass
" 2>/dev/null)
        if [[ -n "$temp" ]]; then
            while IFS='|' read -r label val; do
                SENSOR_LIST+=("NVMe|${chip}|${label}|${val}°C")
            done <<< "$temp"
        fi
    done

    # HDD/SATA drives
    local hdd_chips
    hdd_chips=$(echo "$sensor_output" | grep -oP '"(drivetemp-scsi-[^"]+)"' | tr -d '"' | sort -u)
    for chip in $hdd_chips; do
        local temp
        temp=$(echo "$sensor_output" | python3 -c "
import sys,json
try:
    d=json.loads(sys.stdin.read())
    chip=d.get('$chip',{})
    for lbl,v in chip.items():
        if lbl=='Adapter': continue
        if not isinstance(v,dict): continue
        for k,val in v.items():
            if 'input' in k and val is not None:
                print(f'{lbl}|{val}')
                break
except: pass
" 2>/dev/null)
        if [[ -n "$temp" ]]; then
            while IFS='|' read -r label val; do
                SENSOR_LIST+=("HDD|${chip}|${label}|${val}°C")
            done <<< "$temp"
        fi
    done

    # Fan sensors (any chip)
    local fan_data
    fan_data=$(echo "$sensor_output" | python3 -c "
import sys,json
try:
    d=json.loads(sys.stdin.read())
    def find_fans(obj, chip_key, parent=''):
        if not isinstance(obj, dict): return
        for k,v in obj.items():
            if k == 'Adapter': continue
            if isinstance(v, dict):
                for fk,fv in v.items():
                    if 'fan' in fk and 'input' in fk and fv is not None:
                        print(f'{chip_key}|{k}|{int(fv)} RPM')
                if not any('fan' in fk and 'input' in fk for fk in v):
                    find_fans(v, chip_key, k)
    for chip_key in d:
        find_fans(d[chip_key], chip_key)
except: pass
" 2>/dev/null)
    if [[ -n "$fan_data" ]]; then
        while IFS='|' read -r chip label val; do
            SENSOR_LIST+=("Fan|${chip}|${label}|${val}")
        done <<< "$fan_data"
    fi

    # UPS
    if command -v upsc &> /dev/null; then
        local ups_list
        ups_list=$(upsc -l 2>/dev/null | head -5)
        if [[ -n "$ups_list" ]]; then
            while read -r ups_name; do
                [[ -z "$ups_name" ]] && continue
                SENSOR_LIST+=("UPS|ups|${ups_name}|NUT")
            done <<< "$ups_list"
        fi
    fi

    return 0
}

# Interactive sensor selection — lets user pick which sensors to display
configure_sensor_filter() {
    if ! enumerate_sensors; then
        print_warning "Could not enumerate sensors"
        return 1
    fi

    if [[ ${#SENSOR_LIST[@]} -eq 0 ]]; then
        print_warning "No individual sensors found to configure"
        return 1
    fi

    echo ""
    echo "=== Sensor Selection ==="
    echo ""
    print_info "Available sensors:"
    echo ""

    local i=1
    for entry in "${SENSOR_LIST[@]}"; do
        IFS='|' read -r type chip label value <<< "$entry"
        printf "  ${CYAN}%2d)${NC} [%-4s] %s: %s (%s)\n" "$i" "$type" "$chip" "$label" "$value"
        i=$((i + 1))
    done

    echo ""
    echo -e "  ${CYAN} a)${NC} All sensors (default)"
    echo ""
    read -p "Select sensors to display [1-$((i-1)), comma-separated, or 'a' for all]: " selection

    # Handle 'all' or empty
    if [[ -z "$selection" || "$selection" == "a" || "$selection" == "all" ]]; then
        rm -f "$SENSORS_FILTER"
        print_status "All sensors will be displayed"
        return 0
    fi

    # Parse comma-separated numbers
    local filter_entries=()
    IFS=',' read -ra nums <<< "$selection"
    for num in "${nums[@]}"; do
        num=$(echo "$num" | tr -d ' ')
        if [[ "$num" =~ ^[0-9]+$ ]] && [[ "$num" -ge 1 ]] && [[ "$num" -le ${#SENSOR_LIST[@]} ]]; then
            local entry="${SENSOR_LIST[$((num - 1))]}"
            IFS='|' read -r type chip label value <<< "$entry"
            # Store as chip:label for fans/temps, or chip:upsname for UPS
            filter_entries+=("${chip}:${label}")
        else
            print_warning "Ignoring invalid selection: $num"
        fi
    done

    if [[ ${#filter_entries[@]} -eq 0 ]]; then
        print_warning "No valid selections — showing all sensors"
        rm -f "$SENSORS_FILTER"
        return 0
    fi

    # Write filter file
    mkdir -p "$INSTALL_DIR"
    printf '%s\n' "${filter_entries[@]}" > "$SENSORS_FILTER"
    print_status "Sensor filter saved (${#filter_entries[@]} sensor(s) selected)"
    return 0
}

# Patch Nodes.pm to expose sensor data via the API
patch_nodes_pm() {
    if [[ ! -f "$NODES_PM" ]]; then
        print_error "Nodes.pm not found at $NODES_PM"
        return 1
    fi

    # Pre-flight: verify Nodes.pm is syntactically valid before we touch it.
    # If it is already broken (e.g. from the v2.7.0 APT-hook heredoc bug, #45)
    # the post-patch perl -c check would produce a misleading error.
    if ! perl -c "$NODES_PM" 2>/dev/null; then
        print_error "Nodes.pm already has a syntax error before patching."
        print_error "Run 'apt install --reinstall pve-manager' to restore it, then re-run ProxMorph install."
        return 1
    fi

    local sensor_anchor_count
    sensor_anchor_count=$(grep -cE '^[[:space:]]*my \$dinfo = df' "$NODES_PM" 2>/dev/null || true)
    if [[ "$sensor_anchor_count" -ne 1 ]]; then
        print_error "Cannot safely patch Nodes.pm: expected one status-filesystem anchor, found ${sensor_anchor_count}"
        return 1
    fi

    # Refresh legacy sensor patches so old installs get the taint-safe logic.
    if grep -q "$SENSORS_PATCH_MARKER" "$NODES_PM" 2>/dev/null; then
          if grep -q "local \$ENV{PATH} = '/usr/bin:/bin';" "$NODES_PM" 2>/dev/null && \
              grep -q "safe_ups_name" "$NODES_PM" 2>/dev/null && \
              grep -q "/usr/bin/timeout -k 1 3 /usr/bin/upsc" "$NODES_PM" 2>/dev/null; then
            print_info "Nodes.pm already patched for sensors"
            return 0
        fi

        print_warning "Legacy sensor patch detected in Nodes.pm, refreshing to current version"
        sed -i "/${SENSORS_PATCH_MARKER}/,/${SENSORS_PATCH_MARKER} END/d" "$NODES_PM"
    fi

    # Insert sensor data collection before 'my $dinfo = df('/', 1);'
    sed -i "/^\s*my \$dinfo = df/i\\
    ${SENSORS_PATCH_MARKER}\\
    local \$ENV{PATH} = '/usr/bin:/bin';\\
    \$res->{sensorsOutput} = \`sensors -j 2>/dev/null\`;\\
    if (-e '${SENSORS_FILTER}') {\\
        if (open(my \$fh, '<', '${SENSORS_FILTER}')) {\\
            local \$/;\\
            \$res->{sensorsFilter} = <\$fh>;\\
            close(\$fh);\\
        }\\
    }\\
    if (-x '/usr/bin/upsc') {\\
        my \@ups_list = \`if [ -x /usr/bin/timeout ]; then /usr/bin/timeout -k 1 3 /usr/bin/upsc -l; else /usr/bin/upsc -l; fi 2>/dev/null\`;\\
        if (\@ups_list) {\\
            chomp(my \$ups_name = \$ups_list[0]);\\
            if (\$ups_name && \$ups_name =~ /^([A-Za-z0-9_.:-]+)$/) {\\
                my \$safe_ups_name = \$1;\\
                \$res->{upsData} = \`if [ -x /usr/bin/timeout ]; then /usr/bin/timeout -k 1 3 /usr/bin/upsc \$safe_ups_name; else /usr/bin/upsc \$safe_ups_name; fi 2>/dev/null\`;\\
            }\\
        }\\
    }\\
    ${SENSORS_PATCH_MARKER} END" "$NODES_PM"

    if ! perl -c "$NODES_PM" 2>/dev/null; then
        print_error "Nodes.pm syntax broken after sensor patch, rolling back"
        if [[ "$TRANSACTION_ACTIVE" == "true" ]]; then
            print_info "The active full backup will restore Nodes.pm and all other changed files"
        elif [[ -f "${BACKUP_DIR}/Nodes.pm.original" ]]; then
            cp "${BACKUP_DIR}/Nodes.pm.original" "$NODES_PM"
            print_info "Restored Nodes.pm from backup"
        else
            sed -i "/${SENSORS_PATCH_MARKER}/,/${SENSORS_PATCH_MARKER} END/d" "$NODES_PM"
        fi
        return 1
    fi

    print_status "Patched Nodes.pm to expose hardware sensor data"
    return 0
}

# Remove sensor patches from Nodes.pm
unpatch_nodes_pm() {
    if [[ ! -f "$NODES_PM" ]]; then
        return 0
    fi

    if ! grep -q "$SENSORS_PATCH_MARKER" "$NODES_PM" 2>/dev/null; then
        return 0
    fi

    # Remove lines between our markers (inclusive)
    sed -i "/${SENSORS_PATCH_MARKER}/,/${SENSORS_PATCH_MARKER} END/d" "$NODES_PM"
    print_status "Removed sensor patches from Nodes.pm"
}

# Get list of remote cluster node hostnames (excludes local node)
get_remote_nodes() {
    if ! command -v pvecm &>/dev/null; then
        return 0
    fi

    # pvecm nodes can include a Qdevice status column (e.g. NR, NA,NV,NMW).
    # Use the last field as node name, skip local and qdevice rows.
    pvecm nodes 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && $3 != "Qdevice" && $NF != "(local)" {print $NF}'
}

# Deploy sensor API patch to remote cluster nodes via scp
patch_cluster_sensors() {
    local remote_nodes
    remote_nodes=$(get_remote_nodes)

    if [[ -z "$remote_nodes" ]]; then
        return 0
    fi

    # Get local PVE version for comparison
    local local_version
    local_version=$(dpkg -l pve-manager 2>/dev/null | awk '/^ii/{print $3}')

    echo ""
    print_info "Cluster detected. Remote nodes need the API patch for sensors to work."
    echo ""
    for node in $remote_nodes; do
        echo -e "  ${CYAN}●${NC} ${node}"
    done
    echo ""

    read -p "Deploy sensor patch to remote nodes? [Y/n]: " deploy_choice
    case "$deploy_choice" in
        [Nn]|[Nn][Oo])
            print_info "Skipping remote nodes. Run 'install.sh manage-sensors enable' on each node individually."
            return 0
            ;;
    esac

    for node in $remote_nodes; do
        print_info "Deploying to ${node}..."

        # Verify same PVE version before copying Nodes.pm
        local remote_version
        remote_version=$(ssh -n -o ConnectTimeout=5 "root@${node}" "dpkg -l pve-manager 2>/dev/null | awk '/^ii/{print \$3}'" 2>/dev/null)

        if [[ -n "$local_version" && -n "$remote_version" && "$local_version" != "$remote_version" ]]; then
            print_warning "Version mismatch on ${node} (local: ${local_version}, remote: ${remote_version}) — skipping"
            print_info "Run install.sh on ${node} directly to enable sensors"
            continue
        fi

        if ! backup_remote_sensor_state "$node"; then
            print_error "Could not back up remote sensor state on ${node}; refusing to modify it"
            return 1
        fi

        if scp -o ConnectTimeout=5 -q "$NODES_PM" "root@${node}:${NODES_PM}" 2>/dev/null; then
            # Sync sensor filter file if it exists
            if [[ -f "$SENSORS_FILTER" ]]; then
                ssh -n -o ConnectTimeout=5 "root@${node}" "mkdir -p '$(dirname "$SENSORS_FILTER")'" 2>/dev/null || return 1
                scp -o ConnectTimeout=5 -q "$SENSORS_FILTER" "root@${node}:${SENSORS_FILTER}" 2>/dev/null || return 1
            fi
            if ssh -n -o ConnectTimeout=5 "root@${node}" "systemctl restart pvedaemon pveproxy" 2>/dev/null; then
                print_status "Sensors deployed to ${node}"
            else
                print_error "Patched ${node} but failed to restart pveproxy; rolling back"
                return 1
            fi
        else
            print_error "Failed to deploy to ${node}; rolling back"
            return 1
        fi
    done
}

# Remove sensor API patch from remote cluster nodes
unpatch_cluster_sensors() {
    local remote_nodes
    remote_nodes=$(get_remote_nodes)

    if [[ -z "$remote_nodes" ]]; then
        return 0
    fi

    for node in $remote_nodes; do
        print_info "Removing sensor patch from ${node}..."
        if [[ "$TRANSACTION_ACTIVE" == "true" ]]; then
            if ! backup_remote_sensor_state "$node"; then
                print_error "Could not back up remote sensor state on ${node}; refusing to modify it"
                return 1
            fi
        fi
        if ssh -n -o ConnectTimeout=5 "root@${node}" \
            "sed -i '/# ProxMorph Sensors/,/# ProxMorph Sensors END/d' /usr/share/perl5/PVE/API2/Nodes.pm 2>/dev/null && systemctl restart pvedaemon pveproxy" 2>/dev/null; then
            print_status "Sensors removed from ${node}"
        else
            print_error "Failed to unpatch ${node}; rolling back"
            return 1
        fi
    done
}

# Install sensor support interactively
install_sensors() {
    if [[ "$PRODUCT" != "PVE" ]]; then
        return 0
    fi

    if check_sensors; then
        print_info "Hardware sensor monitoring is already enabled"
        return 0
    fi

    print_warning "If readings are unavailable, setup runs sensors-detect --auto, which performs hardware probes that cannot be guaranteed safe on every system."
    read -r -p "Enable sensors and automatically install/configure lm-sensors if needed? [y/N]: " sensor_choice
    case "$sensor_choice" in
        [Yy]|[Yy][Ee][Ss])
            if ! setup_sensor_runtime; then
                print_warning "Sensor setup did not complete; ProxMorph installation will continue without enabling the dashboard sensor panel."
                return 0
            fi
            patch_nodes_pm
            mkdir -p "$INSTALL_DIR"
            echo "enabled" > "$SENSORS_CONFIG"
            print_status "Hardware sensor monitoring enabled!"
            print_info "Showing all sensors. Use '$0 sensors configure' later to choose individual readings."
            patch_cluster_sensors
            ;;
        *)
            print_info "Skipping sensor integration (can be enabled later with: install.sh sensors enable)"
            ;;
    esac
}

# Remove sensor support
remove_sensors() {
    unpatch_nodes_pm
    unpatch_cluster_sensors
    if [[ -f "$SENSORS_CONFIG" ]]; then
        rm -f "$SENSORS_CONFIG"
        print_info "Sensor configuration removed"
    fi
    if [[ -f "$SENSORS_FILTER" ]]; then
        rm -f "$SENSORS_FILTER"
        print_info "Sensor filter removed"
    fi
}

remove_managed_sensor_package() {
    [[ "$PRODUCT" == "PVE" && -f "$SENSORS_PACKAGE_MARKER" ]] || return 0
    if package_is_installed lm-sensors; then
        print_info "Removing lm-sensors because ProxMorph installed it"
        remove_debian_package lm-sensors || return 1
        print_status "Removed ProxMorph-installed lm-sensors package"
    fi
    rm -f "$SENSORS_PACKAGE_MARKER"
}

# Check if sensors are enabled
check_sensors() {
    if [[ -f "$SENSORS_CONFIG" ]] && grep -q "$SENSORS_PATCH_MARKER" "$NODES_PM" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Manage sensors subcommand
manage_sensors() {
    local action="${1:-status}"
    local owns_transaction=false

    case "$action" in
        enable)
            if [[ "$PRODUCT" != "PVE" ]]; then
                print_error "Sensor support is only available for Proxmox VE"
                return 1
            fi
            if [[ "$TRANSACTION_ACTIVE" != "true" ]]; then
                begin_transaction "sensors-enable"
                owns_transaction=true
            fi
            setup_sensor_runtime || return 1
            patch_nodes_pm
            mkdir -p "$INSTALL_DIR"
            echo "enabled" > "$SENSORS_CONFIG"
            print_status "Hardware sensor monitoring enabled!"
            print_info "Restarting PVE API services..."
            restart_proxmorph_services true
            patch_cluster_sensors
            if [[ "$owns_transaction" == "true" ]]; then
                commit_transaction
            fi
            ;;
        disable)
            if [[ "$PRODUCT" != "PVE" ]]; then
                print_error "Sensor support is only available for Proxmox VE"
                return 1
            fi
            if [[ "$TRANSACTION_ACTIVE" != "true" ]]; then
                begin_transaction "sensors-disable"
                owns_transaction=true
            fi
            remove_sensors
            print_status "Hardware sensor monitoring disabled"
            print_info "Restarting PVE API services..."
            restart_proxmorph_services true
            if [[ "$owns_transaction" == "true" ]]; then
                commit_transaction
            fi
            ;;
        detect)
            detect_sensors
            ;;
        configure)
            if [[ "$PRODUCT" != "PVE" ]]; then
                print_error "Sensor support is only available for Proxmox VE"
                return 1
            fi
            if ! check_sensors; then
                print_error "Sensors are not enabled. Enable them first with: install.sh manage-sensors enable"
                return 1
            fi
            if [[ "$TRANSACTION_ACTIVE" != "true" ]]; then
                begin_transaction "sensors-configure"
                owns_transaction=true
            fi
            configure_sensor_filter
            # Re-patch Nodes.pm so the filter file path is current
            unpatch_nodes_pm
            patch_nodes_pm
            print_info "Restarting PVE API services..."
            restart_proxmorph_services false
            print_status "Sensor filter applied!"
            if [[ "$owns_transaction" == "true" ]]; then
                commit_transaction
            fi
            ;;
        status|*)
            if check_sensors; then
                echo -e "  Sensors:    ${GREEN}Enabled${NC}"
                if [[ -f "$SENSORS_FILTER" ]]; then
                    local count
                    count=$(wc -l < "$SENSORS_FILTER" 2>/dev/null)
                    echo -e "  Filter:     ${CYAN}${count} sensor(s) selected${NC}"
                else
                    echo -e "  Filter:     ${CYAN}All sensors (no filter)${NC}"
                fi
            else
                echo -e "  Sensors:    ${YELLOW}Disabled${NC}"
            fi
            ;;
    esac
}

# Interactive sensors management menu (called from show_menu option 7)
manage_sensors_menu() {
    if [[ "$PRODUCT" != "PVE" ]]; then
        print_error "Sensor support is only available for Proxmox VE"
        return
    fi
    
    echo ""
    echo "=== Hardware Sensor Management ==="
    echo ""
    manage_sensors status
    echo ""
    echo "  1) Enable sensors"
    echo "  2) Disable sensors"
    echo "  3) Detect available sensors"
    echo "  4) Configure sensor selection"
    echo "  0) Back to main menu"
    echo ""
    read -r -p "Enter choice [0-4]: " sensor_choice
    
    case $sensor_choice in
        1) manage_sensors enable ;;
        2) manage_sensors disable ;;
        3) manage_sensors detect ;;
        4) manage_sensors configure ;;
        0) return 0 ;;
        *) print_error "Invalid option" ;;
    esac
}

# Get themes source directory - prioritizes local script directory, then /opt/proxmorph
# For PDM, looks for themes/pdm/ subdirectory first
get_themes_source() {
    # 1. Check local script directory (prioritize local execution/development)
    local script_dir=""
    if [[ -n "${BASH_SOURCE[0]}" ]]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)"
    fi

    # Handle piped execution where BASH_SOURCE might be /dev/fd/*
    if [[ -n "$script_dir" && "$script_dir" != /dev/fd* && "$script_dir" != /proc/* && -d "${script_dir}/themes" ]]; then
        # PDM uses a separate theme subdirectory
        if [[ "$PRODUCT" == "PDM" && -d "${script_dir}/themes/pdm" ]]; then
            echo "${script_dir}/themes/pdm"
            return 0
        fi
        echo "${script_dir}/themes"
        return 0
    fi

    # 2. Check /opt/proxmorph (fallback to installed cache)
    if [[ -d "${INSTALL_DIR}/themes" ]]; then
        if [[ "$PRODUCT" == "PDM" && -d "${INSTALL_DIR}/themes/pdm" ]]; then
            echo "${INSTALL_DIR}/themes/pdm"
            return 0
        fi
        echo "${INSTALL_DIR}/themes"
        return 0
    fi
    
    return 1
}

sync_installer_to_cache() {
    local installer_source="${BASH_SOURCE[0]:-}"
    mkdir -p "$INSTALL_DIR"
    if [[ -n "$installer_source" && -f "$installer_source" && "$RELEASE_DOWNLOADED" != "true" && \
          "$(cd "$(dirname "$installer_source")" 2>/dev/null && pwd)/$(basename "$installer_source")" != "${INSTALL_DIR}/install.sh" ]]; then
        cp "$installer_source" "${INSTALL_DIR}/install.sh"
    fi
    [[ -f "${INSTALL_DIR}/install.sh" ]] && chmod 755 "${INSTALL_DIR}/install.sh"
}

# Install all themes from themes directory
install_themes() {
    print_info "Installing ProxMorph themes..."

    # Validate package-owned patch points before the first write.
    validate_runtime_contracts

    local themes_source=$(get_themes_source)
    
    if [[ -z "$themes_source" ]]; then
        # Downloading replaces /opt/proxmorph, so it is part of the transaction.
        if [[ "$TRANSACTION_ACTIVE" != "true" ]]; then
            begin_transaction "install-download"
        fi
        print_info "Local themes not found, attempting to download latest release..."
        download_release
        themes_source=$(get_themes_source)
        
        if [[ -z "$themes_source" ]]; then
            print_error "Failed to locate themes even after download"
            return 1
        fi
    fi
    
    # Count themes
    local theme_count=$(find "$themes_source" -name "theme-*.css" 2>/dev/null | wc -l)
    if [[ $theme_count -eq 0 ]]; then
        print_error "No theme files found in $themes_source (looking for theme-*.css)"
        return 1
    fi
    
    print_info "Found $theme_count theme(s)"

    if [[ "$TRANSACTION_ACTIVE" != "true" ]]; then
        begin_transaction "install" "$themes_source"
    fi
    # If the transaction began before a release download, add every destination
    # introduced by that release while those destinations are still untouched.
    extend_backup_inventory "$TRANSACTION_BACKUP_ID" "$themes_source"
    extend_uninstall_baseline "$themes_source"
    
    # PDM uses a completely different installation approach (CSS injection via index.hbs)
    if [[ "$PRODUCT" == "PDM" ]]; then
        # Sync to local cache
        if [[ "$themes_source" != "${INSTALL_DIR}/themes/pdm" ]]; then
            mkdir -p "${INSTALL_DIR}/themes/pdm"
            cp "$themes_source"/theme-*.css "${INSTALL_DIR}/themes/pdm/" 2>/dev/null || true
            [[ -f "${themes_source}/proxmorph-pdm-base.css" ]] && cp "${themes_source}/proxmorph-pdm-base.css" "${INSTALL_DIR}/themes/pdm/"
            mkdir -p "${INSTALL_DIR}/themes/patches"
            [[ -f "$(dirname "$themes_source")/patches/pdm-theme-selector.js" ]] && \
                cp "$(dirname "$themes_source")/patches/pdm-theme-selector.js" "${INSTALL_DIR}/themes/patches/"
        fi
        sync_installer_to_cache
        : > "$INSTALLED_PATHS_FILE"
        
        install_pdm_themes "$themes_source"
        install_apt_hook
        echo "$TARGET_VERSION" > "${INSTALL_DIR}/.version"
        
        echo ""
        print_status "ProxMorph PDM themes installed successfully!"
        echo ""
        print_info "To activate a theme:"
        print_info "  1. Open browser console (F12) on your PDM web UI"
        print_info "  2. Run: localStorage.setItem('proxmorph-theme', 'theme-dracula.css')"
        print_info "  3. Reload the page (Ctrl+Shift+R)"
        print_info ""
        print_info "Available themes:"
        for css_file in "$themes_source"/theme-*.css; do
            if [[ -f "$css_file" ]]; then
                local pname=$(basename "$css_file")
                local ptitle=$(get_theme_title "$css_file")
                print_theme "  ${ptitle}: localStorage.setItem('proxmorph-theme', '${pname}')"
            fi
        done
        print_info ""
        print_info "To disable: localStorage.removeItem('proxmorph-theme') + reload"
        
        # Restart service
        print_info "Restarting ${PROXY_SERVICE} service in background..."
        restart_proxmorph_services true
        commit_transaction
        return 0
    fi
    
    # PVE/PBS standard installation path
    # Create themes directory if not exists
    mkdir -p "$THEMES_DIR"
    mkdir -p "${INSTALL_DIR}/themes"
    sync_installer_to_cache
    : > "$INSTALLED_PATHS_FILE"
    
    # Process each theme
    for css_file in "$themes_source"/theme-*.css; do
        if [[ -f "$css_file" ]]; then
            theme_key=$(get_theme_key "$css_file")
            theme_title=$(get_theme_title "$css_file")
            
            # Copy CSS file to live Proxmox web directory
            cp "$css_file" "${THEMES_DIR}/"
            chmod 644 "${THEMES_DIR}/$(basename "$css_file")"
            record_installed_path "${THEMES_DIR}/$(basename "$css_file")"
            
            # Sync to local cache so apt hook uses the newest files on update
            if [[ "$themes_source" != "${INSTALL_DIR}/themes" && "$themes_source" != "${INSTALL_DIR}/themes/pdm" ]]; then
                if [[ "$PRODUCT" == "PDM" ]]; then
                    mkdir -p "${INSTALL_DIR}/themes/pdm"
                    cp "$css_file" "${INSTALL_DIR}/themes/pdm/"
                else
                    cp "$css_file" "${INSTALL_DIR}/themes/"
                fi
            fi
            
            # Register in theme_map (PDM may not use proxmoxlib.js theme_map)
            if [[ -f "$PROXMOXLIB_JS" ]]; then
                patch_theme_map "$theme_key" "$theme_title"
            elif [[ "$PRODUCT" == "PDM" ]]; then
                print_info "PDM detected — skipping proxmoxlib.js theme_map (not applicable)"
            fi
        fi
    done
    
    # Sync JavaScript patches to cache if installing locally
    if [[ -d "${themes_source}/patches" && "$themes_source" != "${INSTALL_DIR}/themes" ]]; then
        mkdir -p "${INSTALL_DIR}/themes/patches"
        cp "${themes_source}/patches"/*.js "${INSTALL_DIR}/themes/patches/" 2>/dev/null || true
    fi
    if [[ "$PRODUCT" == "PVE" && -d "${themes_source}/novnc" && "$themes_source" != "${INSTALL_DIR}/themes" ]]; then
        mkdir -p "${INSTALL_DIR}/themes/novnc"
        cp "${themes_source}/novnc/proxmorph-novnc.js" "${INSTALL_DIR}/themes/novnc/"
        cp "${themes_source}/novnc/proxmorph-novnc.css" "${INSTALL_DIR}/themes/novnc/"
    fi

    # PVE stores Inventory, Appearance, and Console settings per authenticated account in pmxcfs.
    # This is installed before the hook so package updates can reapply the same
    # validated server-side extension from the cached release.
    install_pve_preferences_api

    # Enhance Proxmox's supported noVNC clipboard transport without replacing it.
    install_novnc_clipboard "$themes_source"
    
    # Install apt hook for persistence across updates
    install_apt_hook
    
    # Install JavaScript patches (chart colors, etc.)
    install_js_patches

    # Re-apply server-side default theme (if configured)
    inject_default_theme

    # Write version file
    echo "$TARGET_VERSION" > "${INSTALL_DIR}/.version"
    
    # Offer hardware sensor integration (PVE only)
    if [[ "$PRODUCT" == "PVE" ]]; then
        echo ""
        install_sensors
    fi
    
    echo ""
    print_status "ProxMorph themes installed successfully!"
    echo ""
    print_info "To apply a theme:"
    print_info "  1. Clear your browser cache (Ctrl+Shift+R)"
    print_info "  2. Click your username → Color Theme"
    print_info "  3. Select a ProxMorph theme from the dropdown"
    
    # PVE's protected preference API runs in pvedaemon; reload it with pveproxy.
    print_info "Restarting ${PRODUCT} API services in background..."
    restart_proxmorph_services true
    commit_transaction
}

# Install a specific theme
install_single_theme() {
    local theme_file="$1"
    
    if [[ ! -f "$theme_file" ]]; then
        print_error "Theme file not found: $theme_file"
        return 1
    fi
    
    validate_runtime_contracts
    begin_transaction "single-theme" "$(dirname "$theme_file")"
    extend_uninstall_baseline "$(dirname "$theme_file")"
    mkdir -p "$THEMES_DIR"
    
    theme_key=$(get_theme_key "$theme_file")
    theme_title=$(get_theme_title "$theme_file")
    
    cp "$theme_file" "${THEMES_DIR}/"
    chmod 644 "${THEMES_DIR}/$(basename "$theme_file")"
    record_installed_path "${THEMES_DIR}/$(basename "$theme_file")"
    patch_theme_map "$theme_key" "$theme_title"
    
    print_status "Theme '${theme_title}' installed!"
    print_info "Restarting ${PROXY_SERVICE} service in background..."
    nohup systemctl restart "${PROXY_SERVICE}" &>/dev/null &
    commit_transaction
}

update_themes() {
    local version="${1:-}"
    local update_source=""
    validate_runtime_contracts
    update_source=$(get_themes_source || true)
    begin_transaction "update" "$update_source"
    download_release "$version"
    install_themes
}

# Reinstall themes (after PVE update)
reinstall_themes() {
    print_info "Reinstalling ProxMorph themes..."
    validate_runtime_contracts
    local themes_source=$(get_themes_source)
    begin_transaction "reinstall" "$themes_source"
    restore_packages
    install_themes
}

remove_installed_assets() {
    local themes_source="${1:-}"
    local path=""
    local css_file=""

    if [[ -f "$INSTALLED_PATHS_FILE" ]]; then
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            if backup_path_is_allowed "$path" && path_exists "$path"; then
                remove_exact_path "$path"
                print_status "Removed: $path"
            fi
        done < "$INSTALLED_PATHS_FILE"
    elif [[ "$PRODUCT" == "PDM" ]]; then
        if path_exists "$PDM_THEMES_DIR"; then remove_exact_path "$PDM_THEMES_DIR"; fi
        if path_exists "$PDM_JS_PATCHES_DIR"; then remove_exact_path "$PDM_JS_PATCHES_DIR"; fi
    else
        for css_file in "$themes_source"/theme-*.css; do
            [[ -f "$css_file" ]] || continue
            path="${THEMES_DIR}/$(basename "$css_file")"
            if path_exists "$path"; then remove_exact_path "$path"; fi
        done
        if path_exists "$JS_PATCHES_DIR"; then remove_exact_path "$JS_PATCHES_DIR"; fi
    fi
}

# Uninstall all themes
uninstall_themes() {
    local assume_yes=false
    local arg=""
    local themes_source=""
    local baseline_id=""
    local baseline_dir=""
    local baseline_verified=false
    local clean_package_backup_id=""
    local clean_package_backup_dir=""
    local used_baseline=false

    for arg in "$@"; do
        case "$arg" in
            --yes) assume_yes=true ;;
            *) print_error "Unknown uninstall option: $arg"; return 1 ;;
        esac
    done

    confirm_destructive_action "Fully uninstall ProxMorph and restore the pre-install state?" "$assume_yes" || return 1
    print_info "Uninstalling ProxMorph themes..."
    themes_source=$(get_themes_source || true)
    begin_transaction "uninstall" "$themes_source"

    # Remove assets introduced by releases newer than the baseline before an
    # exact restore; an older baseline cannot enumerate future filenames.
    remove_installed_assets "$themes_source"

    if baseline_id=$(resolve_backup_id baseline 2>/dev/null); then
        baseline_dir="$(product_backup_dir)/${baseline_id}"
        if verify_backup "$baseline_dir"; then
            baseline_verified=true
        fi
        if [[ "$baseline_verified" != "true" ]]; then
            print_warning "The clean baseline failed verification; using current packages for uninstall"
        elif verify_backup_package_versions "$baseline_dir"; then
            restore_backup_internal "$baseline_id" true false
            used_baseline=true
        else
            print_warning "The clean baseline belongs to a different package version; using current packages for uninstall"
        fi
    fi

    if [[ "$used_baseline" != "true" ]]; then
        # No trustworthy same-version baseline (for example, an upgrade from a
        # pre-v2.10 install). Remove only ProxMorph-owned state, then reinstall
        # the currently selected package versions rather than restoring stale
        # package files.
        if [[ "$PRODUCT" == "PDM" ]]; then
            remove_pdm_themes
        else
            remove_js_patches
            remove_default_theme_injection
            if [[ "$PRODUCT" == "PVE" ]]; then
                remove_sensors
                remove_managed_sensor_package
                remove_novnc_clipboard
                remove_pve_preferences_api
            fi
        fi
        remove_apt_hook
        if path_exists "$CONFIG_DIR"; then remove_exact_path "$CONFIG_DIR"; fi
        if path_exists "$PROXMORPH_LOG_FILE"; then remove_exact_path "$PROXMORPH_LOG_FILE"; fi
        if path_exists "$INSTALL_DIR"; then remove_exact_path "$INSTALL_DIR"; fi
        clean_package_backup_id=$(find_current_clean_package_backup || true)
        if [[ -n "$clean_package_backup_id" ]]; then
            clean_package_backup_dir="$(product_backup_dir)/${clean_package_backup_id}"
            restore_local_inventory "$clean_package_backup_dir" package
            print_status "Restored current clean package files from backup ${clean_package_backup_id}"
        else
            restore_all_product_packages
        fi
        if [[ "$baseline_verified" == "true" ]]; then
            restore_local_inventory "$baseline_dir" nonpackage
            print_status "Restored pre-existing non-package files from the uninstall baseline"
        fi
    fi

    commit_transaction
    echo ""
    print_status "ProxMorph fully uninstalled; rollback backups were retained in $(product_backup_dir)"
    if [[ "$PRODUCT" == "PDM" ]]; then
        print_info "Clear your browser cache and the ProxMorph PDM browser theme selection to see the changes."
    else
        print_info "Clear your browser cache to see the changes."
    fi
    print_info "Restarting ${PRODUCT} API services..."
    restart_proxmorph_services true
}

# List available themes
list_themes() {
    print_info "Available ProxMorph Themes:"
    echo ""
    
    # Find themes source
    local themes_source=$(get_themes_source)
    
    if [[ -z "$themes_source" ]]; then
        print_error "Themes directory not found. Run 'update' first to download themes."
        return 1
    fi
    
    for css_file in "$themes_source"/theme-*.css; do
        if [[ -f "$css_file" ]]; then
            theme_key=$(get_theme_key "$css_file")
            theme_title=$(get_theme_title "$css_file")
            
            # Check if installed
            if [[ -f "${THEMES_DIR}/$(basename "$css_file")" ]]; then
                echo -e "  ${GREEN}●${NC} ${theme_title} (${theme_key}) - Installed"
            else
                echo -e "  ${YELLOW}○${NC} ${theme_title} (${theme_key})"
            fi
        fi
    done
    echo ""
}

# Show status
show_status() {
    print_info "ProxMorph Status:"
    echo ""
    
    # Show installed version
    if [[ -f "${INSTALL_DIR}/.version" ]]; then
        local current_ver=$(cat "${INSTALL_DIR}/.version")
        echo -e "  Version:    ${GREEN}v${current_ver}${NC}"
    else
        echo -e "  Version:    ${YELLOW}Unknown (local install)${NC}"
    fi
    
    # Dynamically check if our themes are registered in proxmoxlib.js
    local themes_source=$(get_themes_source)
    local is_patched=false
    if [[ -n "$themes_source" ]]; then
        for css_file in "${themes_source}"/theme-*.css; do
            if [[ -f "$css_file" ]]; then
                local theme_key=$(get_theme_key "$css_file")
                if grep -q "\"${theme_key}\":" "$PROXMOXLIB_JS" 2>/dev/null; then
                    is_patched=true
                    break
                fi
            fi
        done
    fi

    if [[ "$is_patched" == "true" ]]; then
        echo -e "  Theme Map:  ${GREEN}Patched${NC}"
    else
        echo -e "  Theme Map:  ${YELLOW}Not patched${NC}"
    fi
    
    # Count installed themes
    local installed=0
    if [[ -n "$themes_source" ]]; then
        for css_file in "${themes_source}"/theme-*.css; do
            if [[ -f "${THEMES_DIR}/$(basename "$css_file")" ]]; then
                installed=$((installed + 1))
            fi
        done
    fi
    echo -e "  Installed:  ${GREEN}${installed}${NC} theme(s)"
    
    # Backup status
    local backup_product_dir=$(product_backup_dir)
    if [[ -f "${backup_product_dir}/latest" ]]; then
        echo -e "  Backup:     ${GREEN}Available${NC} ($(tr -d ' \t\r\n' < "${backup_product_dir}/latest"))"
    else
        echo -e "  Backup:     ${YELLOW}Not created${NC}"
    fi
    
    # Apt hook status (persistence)
    if check_apt_hook; then
        echo -e "  Auto-patch: ${GREEN}Enabled${NC} (persists across ${PRODUCT} updates)"
    else
        echo -e "  Auto-patch: ${YELLOW}Not installed${NC}"
    fi

    # Server-side default theme
    local default_theme=$(get_default_theme)
    if [[ -n "$default_theme" ]]; then
        echo -e "  Default:    ${GREEN}${default_theme}${NC} (server-side)"
    else
        echo -e "  Default:    ${YELLOW}Not set${NC}"
    fi
    
    # Sensor status (PVE only)
    if [[ "$PRODUCT" == "PVE" ]]; then
        manage_sensors status
    fi
    
    echo ""
    list_themes
}

# Run a menu action in its own shell so its normal error handling and
# transactional ERR trap remain active. The parent menu can then recover from a
# cancellation or failed action without weakening rollback behavior.
run_menu_action() {
    local action_status=0
    set +e
    (
        set -Ee
        "$@"
    )
    action_status=$?
    set -e
    if [[ "$action_status" -ne 0 ]]; then
        print_warning "Action did not complete; returning to the main menu."
    fi
    return 0
}

# Main menu
show_menu() {
    echo ""
    echo "Select an option:"
    echo "  1) Install themes"
    echo "  2) Update from GitHub (latest release)"
    echo "  3) Reinstall themes (after update)"
    echo "  4) Uninstall themes"
    echo "  5) List themes"
    echo "  6) Show status"
    [[ "$PRODUCT" == "PVE" ]] && echo "  7) Manage sensors"
    echo "  8) Set default theme (server-side)"
    echo "  9) Verify Proxmox compatibility"
    echo " 10) Create full backup"
    echo " 11) List backups"
    echo " 12) Restore a backup"
    echo "  0) Exit"
    echo ""
    read -r -p "Enter choice [0-12]: " choice

    case $choice in
        1) run_menu_action install_themes ;;
        2) run_menu_action update_themes ;;
        3) run_menu_action reinstall_themes ;;
        4) run_menu_action uninstall_themes ;;
        5) run_menu_action list_themes ;;
        6) run_menu_action show_status ;;
        7) run_menu_action manage_sensors_menu ;;
        8)
            run_menu_action manage_default_theme
            echo ""
            read -r -p "Enter theme key (or 'none' to clear, empty to cancel): " dt_key
            if [[ -n "$dt_key" ]]; then
                run_menu_action manage_default_theme "$dt_key"
            fi
            ;;
        9) run_menu_action validate_runtime_contracts ;;
        10) run_menu_action create_backup "manual" "$(get_themes_source || true)" ;;
        11) run_menu_action list_backups ;;
        12)
            run_menu_action list_backups
            echo ""
            read -r -p "Enter backup ID (latest or baseline are also accepted): " restore_id
            if [[ -n "$restore_id" ]]; then
                run_menu_action restore_backup "$restore_id"
            fi
            ;;
        0) exit 0 ;;
        *) print_error "Invalid option" ;;
    esac
}

# Parse command line arguments
main() {
    local arg=""
    local -a filtered_args=()

    # Accept --dry-run before or after the command and remove it before normal
    # positional parsing. A dry run exits before lock acquisition so even the
    # operation lock file remains untouched.
    for arg in "$@"; do
        if [[ "$arg" == "--dry-run" ]]; then
            DRY_RUN=true
        else
            filtered_args+=("$arg")
        fi
    done
    if [[ ${#filtered_args[@]} -gt 0 ]]; then
        set -- "${filtered_args[@]}"
    else
        set --
    fi

    # Compatibility is read-only and should be usable by an unprivileged
    # administrator before deciding whether to install anything as root.
    if [[ "${1:-}" == "compatibility" ]]; then
        check_product
        validate_runtime_contracts
        return
    fi

    check_root
    check_product

    if [[ "$DRY_RUN" == "true" ]]; then
        dry_run_dispatch "${1:-install}" "${@:2}"
        return
    fi

    case "${1:-}" in
        list|status|check|backups|list-backups) ;;
        sensors)
            [[ "${2:-status}" == "status" || "${2:-status}" == "detect" ]] || acquire_operation_lock
            ;;
        default-theme)
            [[ -z "${2:-}" ]] || acquire_operation_lock
            ;;
        *) acquire_operation_lock ;;
    esac
    
    case "${1:-}" in
        install)
            install_themes
            ;;
        update)
            update_themes "${2:-}"
            ;;
        reinstall)
            reinstall_themes
            ;;
        uninstall)
            uninstall_themes "${@:2}"
            ;;
        backup)
            create_backup "${2:-manual}" "$(get_themes_source || true)"
            ;;
        backups|list-backups)
            list_backups
            ;;
        restore)
            restore_backup "${2:-latest}" "${@:3}"
            ;;
        list)
            list_themes
            ;;
        status)
            show_status
            ;;
        check)
            check_updates
            ;;
        sensors)
            manage_sensors "${2:-status}"
            ;;
        default-theme)
            manage_default_theme "${2:-}"
            ;;
        reapply-preferences-api)
            if [[ "${PROXMORPH_APT_REPATCH:-false}" != "true" ]]; then
                print_error "reapply-preferences-api is reserved for the ProxMorph APT hook"
                return 1
            fi
            install_pve_preferences_api
            ;;
        reapply-novnc-clipboard)
            if [[ "${PROXMORPH_APT_REPATCH:-false}" != "true" ]]; then
                print_error "reapply-novnc-clipboard is reserved for the ProxMorph APT hook"
                return 1
            fi
            install_novnc_clipboard "${INSTALL_DIR}/themes"
            ;;
        *)
            while true; do
                show_menu
            done
            ;;
    esac
}

# Run only when executed directly, not when sourced (e.g. by tests).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
