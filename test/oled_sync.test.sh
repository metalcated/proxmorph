#!/usr/bin/env bash
# Guards the generated UniFi OLED themes: `bash test/oled_sync.test.sh`.
#
# Two failures this catches:
#   1. A base UniFi theme changed and the OLED variant was not regenerated.
#   2. An OLED variant is a byte-for-byte clone of its base, meaning the
#      substitution table reached none of the operative declarations. That is
#      exactly how the PDM OLED theme shipped looking like plain UniFi dark.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

fail=0
check() { # desc, expected_rc, actual_rc
    if [[ "$2" == "$3" ]]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1 (expected rc=$2, got rc=$3)"
        fail=1
    fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Operative declarations only: strip comments and blank lines.
declarations() {
    sed 's/\r$//' "$1" | sed 's|/\*[^*]*\*/||g' | grep -vE '^[[:space:]]*\*|^[[:space:]]*/\*|^[[:space:]]*$'
}

# 1. The committed OLED themes match what the generator produces.
( cd "$ROOT" && bash tools/gen-oled.sh --check >/dev/null 2>&1 ); rc=$?
check "committed OLED themes are in sync with their bases" 0 "$rc"

# 2. Every OLED theme actually differs from its base in real declarations.
for pair in "themes/theme-unifi.css themes/theme-unifi-oled.css" \
            "themes/pdm/theme-unifi.css themes/pdm/theme-unifi-oled.css"; do
    set -- $pair
    declarations "${ROOT}/$1" > "${work}/base.txt"
    declarations "${ROOT}/$2" > "${work}/oled.txt"
    cmp -s "${work}/base.txt" "${work}/oled.txt"; same=$?
    # cmp returns 0 when identical, which is the bug; we want non-zero.
    if [[ "$same" == "0" ]]; then
        echo "FAIL: $2 has the same declarations as $1 (OLED palette never applied)"
        fail=1
    else
        echo "PASS: $2 recolors $1"
    fi
done

# 3. A drifted base is reported as stale rather than silently accepted.
cp -r "${ROOT}/tools" "${ROOT}/themes" "$work"/
sed -i 's/#131416/#123456/' "${work}/themes/theme-unifi.css"
( cd "$work" && bash tools/gen-oled.sh --check >/dev/null 2>&1 ); rc=$?
check "a changed base makes --check report stale" 1 "$rc"


echo ""
if [[ "$fail" -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES PRESENT"; fi
exit "$fail"
