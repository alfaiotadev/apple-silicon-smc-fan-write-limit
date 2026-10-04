#!/bin/bash
# Build build/smcfan and, if SIGN_IDENTITY is set, sign it with hardened runtime.
#
#   SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" scripts/build.sh
#
# List the identities in your keychain with:
#   security find-identity -v -p codesigning
#
# An unsigned or ad-hoc signed binary builds fine but the SMC refuses it at
# runtime (kIOReturnNotPrivileged), so `smcfan install` warns about it.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
/usr/bin/swiftc -O src/smcfan.swift -o build/smcfan
echo "built build/smcfan"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" build/smcfan
    /usr/bin/codesign --verify --strict build/smcfan
    echo "signed build/smcfan (hardened runtime)"
else
    echo "SIGN_IDENTITY not set: binary is unsigned and will not be able to talk to the SMC." >&2
fi
