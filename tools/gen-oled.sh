#!/usr/bin/env bash
# Regenerates the UniFi OLED themes from their UniFi bases.
#
#   bash tools/gen-oled.sh            rewrite the OLED stylesheets in place
#   bash tools/gen-oled.sh --check    exit 1 if the committed files are stale
#
# PVE/PBS and PDM carry separate substitution tables because PDM stores its
# operative palette in rgb() while PVE/PBS uses hex. One shared hex-only table
# reaches nothing in PDM, which is how the PDM OLED theme once shipped identical
# to plain UniFi dark.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWK_PROG="${ROOT}/tools/oled.awk"

# base|oled|palette
TARGETS=(
    "themes/theme-unifi.css|themes/theme-unifi-oled.css|tools/oled-palette-pve.tsv"
    "themes/pdm/theme-unifi.css|themes/pdm/theme-unifi-oled.css|tools/oled-palette-pdm.tsv"
)

# Byte-count comparison rather than grep: some grep builds (git-bash) strip CR
# before matching and report a CRLF file as LF.
has_crlf() {
    [[ "$(wc -c < "$1")" -ne "$(tr -d '\r' < "$1" | wc -c)" ]]
}

ends_with_newline() {
    [[ -s "$1" && "$(tail -c 1 "$1" | wc -l)" -ne 0 ]]
}

# generate BASE PALETTE OUT
# The base's line endings and final-newline convention are reproduced, so a
# checkout with either convention regenerates to a no-op diff.
generate() {
    local base="$1" palette="$2" out="$3" provenance crlf=0 trailing=1
    provenance=" * Generated from $(basename "$base") by tools/gen-oled.sh. Do not edit by hand; re-run the generator to re-sync."
    if has_crlf "$base"; then crlf=1; fi
    if ! ends_with_newline "$base"; then trailing=0; fi

    # awk emits LF and always terminates the last line; both are fixed up below.
    tr -d '\r' < "$base" \
        | awk -v NAME="UniFi" -v PROVENANCE="$provenance" -f "$AWK_PROG" "$palette" - \
        > "${out}.lf"

    if (( crlf )); then
        sed 's/$/\r/' "${out}.lf" > "$out"
        rm -f "${out}.lf"
    else
        mv "${out}.lf" "$out"
    fi

    # Drop the terminator awk added, sized to the convention just applied.
    if (( ! trailing )); then
        truncate -s "-$(( crlf ? 2 : 1 ))" "$out"
    fi
}

check=0
if [[ "${1:-}" == "--check" ]]; then check=1; fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

stale=0
for target in "${TARGETS[@]}"; do
    IFS='|' read -r base oled palette <<< "$target"
    generate "${ROOT}/${base}" "${ROOT}/${palette}" "${tmp}/out.css"
    if (( check )); then
        if cmp -s "${tmp}/out.css" "${ROOT}/${oled}"; then
            echo "up to date: ${oled}"
        else
            echo "STALE: ${oled} does not match ${base} through ${palette}"
            diff -u "${ROOT}/${oled}" "${tmp}/out.css" > "${tmp}/drift.diff" || true
            sed -n '1,40p' "${tmp}/drift.diff"
            stale=1
        fi
    else
        cp "${tmp}/out.css" "${ROOT}/${oled}"
        echo "generated: ${oled}"
    fi
done

if (( check && stale )); then
    echo
    echo "Run 'bash tools/gen-oled.sh' and commit the result."
    exit 1
fi
