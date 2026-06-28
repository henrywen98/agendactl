#!/usr/bin/env bash
#
# Reproducible build for agendactl.
# Source of truth: agendactl.swift  →  Output: agendactl (universal2, ad-hoc signed).
#
# Why precompiled + signed (not `#!/usr/bin/swift`):
#   - no Xcode toolchain needed on the user's machine
#   - instant startup (~0ms vs ~0.3s per call for the script form)
#   - stable code identity → Gatekeeper happy, runs on Apple Silicon (which
#     requires at least an ad-hoc signature to execute any binary)
#
set -euo pipefail
cd "$(dirname "$0")"

SRC=agendactl.swift
OUT=agendactl
MIN=14   # macOS deployment target — EventKit requestFullAccessTo* needs macOS 14+

echo "→ arm64"   ; swiftc -O -target arm64-apple-macos$MIN  "$SRC" -o .agendactl-arm64
echo "→ x86_64"  ; swiftc -O -target x86_64-apple-macos$MIN "$SRC" -o .agendactl-x64
echo "→ lipo"    ; lipo -create .agendactl-arm64 .agendactl-x64 -output "$OUT"
rm -f .agendactl-arm64 .agendactl-x64
# lipo strips signatures — re-sign the fat binary (ad-hoc; no Developer ID needed)
echo "→ codesign"; codesign -s - --force "$OUT"

echo "✓ $(file "$OUT")"
codesign -dvv "$OUT" 2>&1 | grep -i 'Signature=' || true
