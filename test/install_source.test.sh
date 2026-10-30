#!/usr/bin/env bash
# Regression test for the theme source `install` picks (issue #54 follow-up).
#
# `bash <(curl …/install.sh) install` — the README one-liner — runs from process
# substitution, so get_themes_source() cannot see a local themes/ dir and falls
# back to the ${INSTALL_DIR}/themes cache left by whatever version was installed
# before. Without a download that silently reinstalls stale CSS while stamping
# .version with the running script's VERSION, so `status` reports a version that
# was never installed.
#
# Runnable anywhere with bash + coreutils: `bash test/install_source.test.sh`.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../install.sh"

fail=0
check() { # desc, expected, actual
    if [[ "$2" == "$3" ]]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1 (expected '$2', got '$3')"
        fail=1
    fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Build a probe copy of the real installer: sandboxed INSTALL_DIR, root/product
# checks and the actual file-copying stubbed out. Everything under test
# (get_themes_source, the install dispatch) is the untouched original.
make_probe() { # $1 = probe path, $2 = sandbox INSTALL_DIR
    sed -e "s|^INSTALL_DIR=.*|INSTALL_DIR=\"$2\"|" \
        -e '/^if \[\[ "${BASH_SOURCE\[0\]}" == "${0}" \]\]; then$/,$d' "$SRC"
    cat <<EOF
check_root() { :; }
check_product() { PRODUCT="PVE"; }
validate_runtime_contracts() { :; }
acquire_operation_lock() { :; }
begin_transaction() { TRANSACTION_ACTIVE=true; }
download_release() {
    touch "$2/.downloaded"
    mkdir -p "$2/themes"
    printf '/*!Fresh*/\n' > "$2/themes/theme-fresh.css"
}
install_themes() { echo "SOURCE=\$(get_themes_source)"; }
main "\$@"
EOF
}

# --- 1. Piped execution with a stale cache: must refresh before installing ----
sbx="${work}/opt"
mkdir -p "${sbx}/themes"
printf '/*!Stale*/\n' > "${sbx}/themes/theme-stale.css"
make_probe probe "$sbx" > "${work}/probe.sh"

out="$(bash <(cat "${work}/probe.sh") install 2>&1)"
[[ -f "${sbx}/.downloaded" ]] && dl=yes || dl=no
check "piped install downloads the release" "yes" "$dl"
check "piped install uses the refreshed cache" "yes" \
      "$([[ -f "${sbx}/themes/theme-fresh.css" ]] && echo yes || echo no)"
check "piped install does not keep stale-only source" "${sbx}/themes" \
      "$(sed -n 's/^SOURCE=//p' <<< "$out")"

# --- 2. Local checkout: themes/ next to the script wins, no download ----------
sbx2="${work}/opt2"
mkdir -p "${sbx2}/themes" "${work}/checkout/themes"
printf '/*!Stale*/\n' > "${sbx2}/themes/theme-stale.css"
printf '/*!Local*/\n' > "${work}/checkout/themes/theme-local.css"
make_probe probe "$sbx2" > "${work}/checkout/install.sh"

out2="$(bash "${work}/checkout/install.sh" install 2>&1)"
check "local checkout skips the download" "no" \
      "$([[ -f "${sbx2}/.downloaded" ]] && echo yes || echo no)"
check "local checkout installs its own themes" "${work}/checkout/themes" \
      "$(sed -n 's/^SOURCE=//p' <<< "$out2")"

# --- 3. record_version reports what was installed, not what was run ----------
# shellcheck source=../install.sh
source "$SRC" >/dev/null 2>&1   # guard skips main() when sourced
set +e                          # install.sh sets -e; tests manage rc themselves
INSTALL_DIR="${work}/rv"
mkdir -p "${INSTALL_DIR}/themes"
echo "1.0.0" > "${INSTALL_DIR}/.version"   # what download_release() recorded

record_version "${INSTALL_DIR}/themes"
check "cache install keeps the downloaded version" "1.0.0" "$(cat "${INSTALL_DIR}/.version")"
record_version "${work}/checkout/themes"
check "local checkout stamps the script version" "$VERSION" "$(cat "${INSTALL_DIR}/.version")"

echo ""
if [[ "$fail" -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES PRESENT"; fi
exit "$fail"
