#!/usr/bin/env bash
#
# Reproducible build for ekctl.
# Source of truth: ekctl.swift  →  Output: ekctl (universal2, ad-hoc signed).
#
# Why precompiled + signed (not `#!/usr/bin/swift`):
#   - no Xcode toolchain needed on the user's machine
#   - instant startup (~0ms vs ~0.3s per call for the script form)
#   - stable code identity → Gatekeeper happy, runs on Apple Silicon (which
#     requires at least an ad-hoc signature to execute any binary)
#
set -euo pipefail
cd "$(dirname "$0")"

SRC=ekctl.swift
OUT=ekctl
MIN=14   # macOS deployment target — EventKit requestFullAccessTo* needs macOS 14+

echo "→ arm64"   ; swiftc -O -target arm64-apple-macos$MIN  "$SRC" -o .ekctl-arm64
echo "→ x86_64"  ; swiftc -O -target x86_64-apple-macos$MIN "$SRC" -o .ekctl-x64
echo "→ lipo"    ; lipo -create .ekctl-arm64 .ekctl-x64 -output "$OUT"
rm -f .ekctl-arm64 .ekctl-x64
# lipo strips signatures — re-sign the fat binary (ad-hoc; no Developer ID needed)
echo "→ codesign"; codesign -s - --force "$OUT"

echo "✓ $(file "$OUT")"
codesign -dvv "$OUT" 2>&1 | grep -i 'Signature=' || true
