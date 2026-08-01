#!/usr/bin/env bash
# Unit test for verify_checksum() in install.sh (supply-chain hardening).
# Runnable anywhere with coreutils: `bash test/verify_checksum.test.sh`.
# Sources install.sh (the source-guard prevents main() from running) and exercises
# the checksum gate that download_release() relies on.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../install.sh
source "${HERE}/../install.sh" >/dev/null 2>&1   # guard skips main() when sourced
set +e                                            # install.sh sets -e; tests manage rc themselves

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
ver="9.9.9"
arch="proxmorph-${ver}.tar.gz"
zero="0000000000000000000000000000000000000000000000000000000000000000"

echo "payload $(date +%s%N)" > "${work}/file.txt"
tar -czf "${work}/${arch}" -C "$work" file.txt

# 1. Good tarball with a correct manifest -> passes.
( cd "$work" && sha256sum "$arch" > SHA256SUMS )
verify_checksum "$work" SHA256SUMS >/dev/null 2>&1; rc=$?
check "good tarball verifies" 0 "$rc"

# 2. Manifest also lists an absent .zip -> still passes (--ignore-missing).
( cd "$work" && { sha256sum "$arch"; echo "${zero}  proxmorph-${ver}.zip"; } > SHA256SUMS )
verify_checksum "$work" SHA256SUMS >/dev/null 2>&1; rc=$?
check "absent .zip entry ignored" 0 "$rc"

# 3. Tampered tarball, unchanged manifest -> rejected (fail closed).
printf 'x' >> "${work}/${arch}"
verify_checksum "$work" SHA256SUMS >/dev/null 2>&1; rc=$?
check "tampered tarball rejected" 1 "$rc"

# 4. Artifact present but NOT listed in the manifest -> nothing verified -> fail closed.
tar -czf "${work}/${arch}" -C "$work" file.txt          # restore a valid tarball
( cd "$work" && echo "${zero}  proxmorph-${ver}.zip" > SHA256SUMS )  # lists only absent zip
verify_checksum "$work" SHA256SUMS >/dev/null 2>&1; rc=$?
check "unlisted artifact fails closed" 1 "$rc"

# 5. Missing manifest file -> non-zero (caller treats absence as fatal).
rm -f "${work}/SHA256SUMS"
verify_checksum "$work" SHA256SUMS >/dev/null 2>&1; rc=$?
check "missing manifest fails" 1 "$rc"

# 6. Manifest paths may not escape or traverse the release directory.
mkdir -p "${work}/nested"
hash=$(sha256sum "${work}/${arch}" | awk '{print $1}')
echo "${hash}  nested/../${arch}" > "${work}/SHA256SUMS"
verify_checksum "$work" SHA256SUMS >/dev/null 2>&1; rc=$?
check "traversing manifest path rejected" 1 "$rc"

echo ""
if [[ "$fail" -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES PRESENT"; fi
exit "$fail"
