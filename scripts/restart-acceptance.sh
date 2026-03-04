#!/usr/bin/env bash
set -euo pipefail

# 一键验收：OpenClaw 重启安全流程
# 默认“无真实重启”模式，避免影响在线任务。
# 若要验证真实重启链路：--with-restart

WITH_RESTART="false"
TASK_PREFIX="accept-$(date +%Y%m%d-%H%M%S)"
STATE_DIR="${STATE_DIR:-./state/restart}"
REPORT_FILE="${REPORT_FILE:-./state/restart/acceptance-${TASK_PREFIX}.log}"
NOTIFY_CHANNEL="${NOTIFY_CHANNEL:-}"
NOTIFY_TARGET="${NOTIFY_TARGET:-}"
NOTIFY_ACCOUNT="${NOTIFY_ACCOUNT:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --with-restart)
      WITH_RESTART="true"; shift ;;
    --task-prefix)
      TASK_PREFIX="${2:-}"; shift 2 ;;
    --notify-channel)
      NOTIFY_CHANNEL="${2:-}"; shift 2 ;;
    --notify-target)
      NOTIFY_TARGET="${2:-}"; shift 2 ;;
    --notify-account)
      NOTIFY_ACCOUNT="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<'EOF'
用法：
  scripts/restart-acceptance.sh [--with-restart] [--task-prefix <prefix>]
                                [--notify-channel <c> --notify-target <t> [--notify-account <a>]]

说明：
  默认不执行真实重启，只验证：
  1) doctor可执行
  2) doctor失败时能阻断流程
  3) checkpoint落盘
  4) resume事件可补发

  加 --with-restart 后，额外验证真实重启链路与通知事件：
  - restart-notice（重启前提示）
  - restart-result（重启后回执）

  若提供 notify 参数，将额外验证“用户可见回执”标记（result-visible）。
EOF
      exit 0 ;;
    *)
      echo "未知参数: $1" >&2
      exit 2 ;;
  esac
done

mkdir -p "$(dirname "$REPORT_FILE")" "$STATE_DIR"
: > "$REPORT_FILE"

PASS_CNT=0
FAIL_CNT=0

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S%z')] $*" | tee -a "$REPORT_FILE"
}

pass() {
  PASS_CNT=$((PASS_CNT + 1))
  log "PASS | $*"
}

fail() {
  FAIL_CNT=$((FAIL_CNT + 1))
  log "FAIL | $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "缺少命令: $1"
    exit 2
  }
}

json_phase() {
  local file="$1"
  python3 - "$file" <<'PY'
import json,sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    obj=json.load(f)
print(obj.get('phase',''))
PY
}

json_note() {
  local file="$1"
  python3 - "$file" <<'PY'
import json,sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    obj=json.load(f)
print(obj.get('note',''))
PY
}

require_cmd openclaw
require_cmd python3
require_cmd bash

SAFE_SCRIPT="scripts/restart-safe.sh"
[ -x "$SAFE_SCRIPT" ] || {
  log "未找到可执行脚本: $SAFE_SCRIPT"
  exit 2
}

TASK_MAIN="${TASK_PREFIX}-main"
TASK_GATE="${TASK_PREFIX}-gate"
TASK_RESTART="${TASK_PREFIX}-restart"

STATE_MAIN="${STATE_DIR}/${TASK_MAIN}.json"
STATE_GATE="${STATE_DIR}/${TASK_GATE}.json"
STATE_RESTART="${STATE_DIR}/${TASK_RESTART}.json"

NOTIFY_ARGS=()
if [ -n "$NOTIFY_CHANNEL" ] && [ -n "$NOTIFY_TARGET" ]; then
  NOTIFY_ARGS+=(--notify-channel "$NOTIFY_CHANNEL" --notify-target "$NOTIFY_TARGET")
  if [ -n "$NOTIFY_ACCOUNT" ]; then
    NOTIFY_ARGS+=(--notify-account "$NOTIFY_ACCOUNT")
  fi
  log "notify configured: channel=$NOTIFY_CHANNEL target=$NOTIFY_TARGET account=${NOTIFY_ACCOUNT:-<default>}"
else
  log "notify not configured: skip visible-ack assertion"
fi

log "=== OpenClaw 重启流程一键验收开始 ==="
log "task_prefix=${TASK_PREFIX}"
log "with_restart=${WITH_RESTART}"
log "report=${REPORT_FILE}"

# TC1: 当前配置 doctor 可执行
if openclaw doctor --non-interactive >/tmp/restart-accept-doctor.out 2>&1; then
  pass "TC1 doctor --non-interactive 可执行"
else
  fail "TC1 doctor --non-interactive 失败（请先修复配置）"
  cat /tmp/restart-accept-doctor.out | tail -n 80 | tee -a "$REPORT_FILE" >/dev/null || true
fi

# TC2: doctor 失败时应阻断流程（不落 checkpoint）
TMPDIR_SHIM="$(mktemp -d)"
REAL_OPENCLAW="$(command -v openclaw)"
mkdir -p "$TMPDIR_SHIM/bin"
cat > "$TMPDIR_SHIM/bin/openclaw" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "doctor" ] && [ "\${2:-}" = "--non-interactive" ]; then
  echo "shim: force doctor failure" >&2
  exit 99
fi
exec "$REAL_OPENCLAW" "\$@"
EOF
chmod +x "$TMPDIR_SHIM/bin/openclaw"

rm -f "$STATE_GATE"
if PATH="$TMPDIR_SHIM/bin:$PATH" "$SAFE_SCRIPT" run --task-id "$TASK_GATE" --no-restart >/tmp/restart-accept-gate.out 2>&1; then
  fail "TC2 doctor失败阻断未生效（流程不应成功）"
else
  if [ -f "$STATE_GATE" ]; then
    fail "TC2 doctor失败后仍产生状态文件（不符合预期）"
  else
    pass "TC2 doctor失败可阻断流程，且不落盘"
  fi
fi
rm -rf "$TMPDIR_SHIM"

# TC3: 正常 no-restart 时能落盘 before-restart
rm -f "$STATE_MAIN"
if "$SAFE_SCRIPT" run --task-id "$TASK_MAIN" --next "重启后继续执行验证动作" --criteria "看到续跑证据" --no-restart >/tmp/restart-accept-main.out 2>&1; then
  if [ -f "$STATE_MAIN" ] && [ "$(json_phase "$STATE_MAIN")" = "before-restart" ]; then
    pass "TC3 no-restart 可落盘且 phase=before-restart"
  else
    fail "TC3 状态文件缺失或 phase 非 before-restart"
  fi
else
  fail "TC3 run --no-restart 执行失败"
fi

# TC4: resume 可补发并更新 phase=resume-triggered
if "$SAFE_SCRIPT" resume --task-id "$TASK_MAIN" >/tmp/restart-accept-resume.out 2>&1; then
  if [ -f "$STATE_MAIN" ] && [ "$(json_phase "$STATE_MAIN")" = "resume-triggered" ]; then
    pass "TC4 resume 补发成功且 phase=resume-triggered"
  else
    fail "TC4 resume后状态异常"
  fi
else
  fail "TC4 resume 执行失败"
fi

# TC5: 可选真实重启链路 + 事件回执验证
if [ "$WITH_RESTART" = "true" ]; then
  rm -f "$STATE_RESTART"
  if "$SAFE_SCRIPT" run --task-id "$TASK_RESTART" --next "真实重启后继续" --criteria "真实重启链路完成" "${NOTIFY_ARGS[@]}" >/tmp/restart-accept-real.out 2>&1; then
    if [ -f "$STATE_RESTART" ] && [ "$(json_phase "$STATE_RESTART")" = "resume-triggered" ]; then
      NOTE_VAL="$(json_note "$STATE_RESTART")"
      if echo "$NOTE_VAL" | grep -q "result-event"; then
        if [ -n "$NOTIFY_CHANNEL" ] && [ -n "$NOTIFY_TARGET" ]; then
          if echo "$NOTE_VAL" | grep -q "result-visible"; then
            pass "TC5 真实重启链路通过，且用户可见回执已发送(result-visible)"
          else
            fail "TC5 真实重启链路通过，但未发现用户可见回执标记(result-visible)"
          fi
        else
          pass "TC5 真实重启链路通过，系统事件回执存在(result-event)"
        fi
      else
        fail "TC5 真实重启链路通过，但未发现系统回执标记(result-event)"
      fi
    else
      fail "TC5 真实重启后状态异常"
    fi
  else
    fail "TC5 真实重启链路失败"
  fi
else
  log "SKIP | TC5 真实重启链路（使用 --with-restart 开启）"
fi

log "=== 验收结束：PASS=${PASS_CNT}, FAIL=${FAIL_CNT} ==="

if [ "$FAIL_CNT" -gt 0 ]; then
  log "结果：FAIL"
  exit 1
fi

log "结果：PASS"
exit 0
