#!/usr/bin/env bash
#
# agendactl 黑盒回归测试 —— reminders + calendar 的 CRUD round-trip。
# 用 __probe__ 标记临时数据，建→改→删→验归零，全程自清理、可幂等重跑。
# 自动挑第一个可写容器，故不依赖某台机器的具体清单/日历名。
# 退出码 0 = 全通过。
#
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENDACTL="$ROOT/skills/agendactl/scripts/agendactl"
TAG="__probe__ agendactl-test"

pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }
# 把 stdin 的 JSON 喂给一段 python 表达式（结果 print 出来）
jget() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

[ -x "$AGENDACTL" ] || { echo "agendactl 不可执行: $AGENDACTL"; exit 2; }
echo "agendactl 回归测试 @ $AGENDACTL"

# 清掉上次失败可能残留的 __probe__ 数据，保证幂等
preclean_rem() {
  "$AGENDACTL" reminders list --list "$1" --status all \
    | python3 -c "import sys,json;[print(r['id']) for r in json.load(sys.stdin)['items'] if '__probe__' in (r['name'] or '')]" \
    | while read -r id; do "$AGENDACTL" reminders delete "$id" >/dev/null 2>&1; done
}
preclean_cal() {
  "$AGENDACTL" calendar list-events --calendar "$1" --from "2026-12-30T00:00:00" --to "2027-01-02T00:00:00" \
    | python3 -c "import sys,json;[print(e['id']) for e in json.load(sys.stdin)['items'] if '__probe__' in (e['summary'] or '')]" \
    | while read -r id; do "$AGENDACTL" calendar delete-event "$id" >/dev/null 2>&1; done
}

# 中断也能清理:trap 删掉本次建的临时项(正常流程末尾会显式删并清空变量,这里兜中断)
RID=""; EID=""
cleanup() {
  [ -n "$RID" ] && "$AGENDACTL" reminders delete "$RID" >/dev/null 2>&1
  [ -n "$EID" ] && "$AGENDACTL" calendar delete-event "$EID" >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

# ──────────── Reminders ────────────
echo "── reminders ──"
LIST=$("$AGENDACTL" reminders lists | jget "next((x['name'] for x in d['items'] if x['writable']), '')")
if [ -z "$LIST" ]; then
  echo "  (无可写提醒清单 — 跳过 reminders)"
else
  echo "  可写清单: $LIST"
  preclean_rem "$LIST"

  RID=$("$AGENDACTL" reminders create --list "$LIST" --name "$TAG" --due "2026-12-31T09:00:00" --priority 5 | jget "d['id']")
  [ -n "$RID" ] && ok "create 返回 id" || bad "create 无 id"

  NAME=$("$AGENDACTL" reminders update "$RID" --name "$TAG edited" --priority 1 | jget "d['name']")
  [ "$NAME" = "$TAG edited" ] && ok "update name 生效" || bad "update name=$NAME"

  COMP=$("$AGENDACTL" reminders complete "$RID" | jget "d['completed']")
  [ "$COMP" = "True" ] && ok "complete 生效" || bad "complete=$COMP"

  "$AGENDACTL" reminders delete "$RID" >/dev/null
  GONE=$("$AGENDACTL" reminders list --list "$LIST" --status all | jget "'FOUND' if any(r['id']=='$RID' for r in d['items']) else 'GONE'")
  [ "$GONE" = "GONE" ] && ok "delete 后归零" || bad "delete 后仍在"
  RID=""
fi

# ──────────── Calendar ────────────
echo "── calendar ──"
CAL=$("$AGENDACTL" calendar calendars | jget "next((x['name'] for x in d['items'] if x['writable']), '')")
if [ -z "$CAL" ]; then
  echo "  (无可写日历 — 跳过 calendar)"
else
  echo "  可写日历: $CAL"
  preclean_cal "$CAL"

  EID=$("$AGENDACTL" calendar create-event --calendar "$CAL" --summary "$TAG" --start "2026-12-31T10:00:00" --end "2026-12-31T11:00:00" | jget "d['id']")
  [ -n "$EID" ] && ok "create-event 返回 id" || bad "create-event 无 id"

  SUMM=$("$AGENDACTL" calendar update-event "$EID" --summary "$TAG edited" --start "2026-12-31T14:00:00" --end "2026-12-31T15:00:00" | jget "d['summary']")
  [ "$SUMM" = "$TAG edited" ] && ok "update-event 生效" || bad "update-event summary=$SUMM"

  if "$AGENDACTL" calendar update-event "$EID" --start "2026-12-31T16:00:00" --end "2026-12-31T15:00:00" >/dev/null 2>&1; then
    bad "end<=start 未被拒"
  else
    ok "end<=start 被拒（exit 非0）"
  fi

  "$AGENDACTL" calendar delete-event "$EID" >/dev/null
  GONE=$("$AGENDACTL" calendar list-events --calendar "$CAL" --from "2026-12-30T00:00:00" --to "2027-01-02T00:00:00" | jget "'FOUND' if any(e['id']=='$EID' for e in d['items']) else 'GONE'")
  [ "$GONE" = "GONE" ] && ok "delete-event 后归零" || bad "delete-event 后仍在"
  EID=""
fi

echo ""
echo "结果: $pass 通过, $fail 失败"
[ "$fail" -eq 0 ]
