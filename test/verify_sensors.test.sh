#!/usr/bin/env bash
# Sensor setup and optional-package rollback tests with command stubs only.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../install.sh
source "${HERE}/../install.sh" >/dev/null 2>&1
set +e

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

PRODUCT="PVE"
INSTALL_DIR="${work}/opt/proxmorph"
SENSORS_PACKAGE_MARKER="${INSTALL_DIR}/.lm-sensors-installed-by-proxmorph"

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

sensor_package_state=absent
package_is_installed() { [[ "$sensor_package_state" == "present" ]]; }
install_debian_package() {
    [[ "$1" == "lm-sensors" ]] || return 1
    sensor_package_state=present
}
remove_debian_package() {
    [[ "$1" == "lm-sensors" ]] || return 1
    sensor_package_state=absent
}
sensors() {
    printf '%s\n' '{"coretemp-isa-0000":{"Package id 0":{"temp1_input":42.0}}}'
}

setup_sensor_runtime >/dev/null 2>&1
check 'sensor setup installs a missing lm-sensors package' present "$sensor_package_state"
check 'sensor setup records package ownership' yes "$([[ -f "$SENSORS_PACKAGE_MARKER" ]] && echo yes || echo no)"

detected_marker="${work}/automatic-detection-ran"
sensor_package_state=present
sensors() {
    [[ -f "$detected_marker" ]] || return 1
    printf '%s\n' '{"k10temp-pci-00c3":{"Tctl":{"temp1_input":43.0}}}'
}
sensors-detect() {
    [[ "$1" == "--auto" ]] || return 1
    printf '%s\n' detected > "$detected_marker"
}

setup_sensor_runtime >/dev/null 2>&1
check 'sensor setup runs automatic detection only when readings are unavailable' yes "$([[ -f "$detected_marker" ]] && echo yes || echo no)"

package_backup="${work}/package-backup"
mkdir -p "$package_backup"
printf 'lm-sensors\tpresent\n' > "${package_backup}/optional-packages.tsv"
sensor_package_state=absent
restore_optional_package_state "$package_backup" false >/dev/null 2>&1
check 'restore reinstalls an optional package recorded as present' present "$sensor_package_state"

printf 'lm-sensors\tabsent\n' > "${package_backup}/optional-packages.tsv"
sensor_package_state=present
restore_optional_package_state "$package_backup" true >/dev/null 2>&1
check 'restore removes a ProxMorph-owned package recorded as absent' absent "$sensor_package_state"

if [[ "$fail" -eq 0 ]]; then
    echo 'ALL PASS'
else
    echo 'FAILURES PRESENT'
fi
exit "$fail"
