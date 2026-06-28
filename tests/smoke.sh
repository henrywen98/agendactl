#!/usr/bin/env bash
#
# agendactl smoke test — verifies the CLI contract WITHOUT requiring Calendar/Reminders
# authorization: no EventKit access, no data written. Exercises help, dispatch, and the
# error contract (exit codes + `agendactl:` stderr prefix), plus that the bundled binary is a
# signed universal2 Mach-O. Deterministic and side-effect-free → safe in CI / anywhere.
#
# For the full EventKit CRUD round-trip (needs TCC auth + writes real data), see roundtrip.sh.
#
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENDACTL="$ROOT/skills/agendactl/scripts/agendactl"
ERRF="$(mktemp)"
trap 'rm -f "$ERRF"' EXIT

pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }
run() { OUT=$("$AGENDACTL" "$@" 2>"$ERRF"); CODE=$?; ERR=$(cat "$ERRF"); }

[ -x "$AGENDACTL" ] || { echo "agendactl not executable: $AGENDACTL"; exit 2; }
echo "agendactl smoke test @ $AGENDACTL"

# ── help: exit 0, no auth ──
run --help
{ [ "$CODE" -eq 0 ] && printf '%s' "$OUT" | grep -q "agendactl"; } \
  && ok "agendactl --help → exit 0" || bad "agendactl --help (code=$CODE)"

run calendar --help
{ [ "$CODE" -eq 0 ] && printf '%s' "$OUT" | grep -qi "calendar"; } \
  && ok "calendar --help → exit 0" || bad "calendar --help (code=$CODE)"

run reminders --help
{ [ "$CODE" -eq 0 ] && printf '%s' "$OUT" | grep -qi "reminders"; } \
  && ok "reminders --help → exit 0" || bad "reminders --help (code=$CODE)"

# ── error contract: exit 1 + `agendactl:` stderr, no auth ──
run bogusapp
{ [ "$CODE" -eq 1 ] && printf '%s' "$ERR" | grep -q "^agendactl:"; } \
  && ok "unknown app → exit 1 + agendactl: stderr" || bad "unknown app (code=$CODE err=$ERR)"

run calendar frobnicate
{ [ "$CODE" -eq 1 ] && printf '%s' "$ERR" | grep -q "^agendactl:"; } \
  && ok "unknown command → exit 1 + agendactl: stderr" || bad "unknown command (code=$CODE err=$ERR)"

# ── bundled binary is a signed universal2 Mach-O ──
# Capture first, then match (avoids `set -o pipefail` + `grep -q` SIGPIPE false-negatives).
FINFO=$(file "$AGENDACTL")
case "$FINFO" in *"universal binary with 2 architectures"*) ok "universal2 binary (arm64 + x86_64)";; *) bad "not a universal2 binary: $FINFO";; esac
SIG=$(codesign -dvv "$AGENDACTL" 2>&1)
case "$SIG" in *adhoc*) ok "ad-hoc code-signed";; *) bad "not code-signed";; esac

echo ""
echo "result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
