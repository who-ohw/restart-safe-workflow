#!/usr/bin/env bash
set -euo pipefail

# OpenClaw Restart Safe Flow
# Usage examples:
#   scripts/restart-safe.sh run --task-id task-20260303-001 --next "继续步骤3" --criteria "输出报告"
#   scripts/restart-safe.sh resume --task-id task-20260303-001
#   scripts/restart-safe.sh status --task-id task-20260303-001
#
# Environment variables:
#   STATE_DIR            default: ./state/restart
#   GATEWAY_RESTART_CMD  default: "openclaw gateway restart"
#   HEALTH_TIMEOUT_SEC   default: 30
#   NOTIFY_CHANNEL       optional, e.g. feishu
#   NOTIFY_TARGET        optional, e.g. user:ou_xxx / chat:oc_xxx
#   NOTIFY_ACCOUNT       optional account id

STATE_DIR="${STATE_DIR:-./state/restart}"
GATEWAY_RESTART_CMD="${GATEWAY_RESTART_CMD:-openclaw gateway restart}"
HEALTH_TIMEOUT_SEC="${HEALTH_TIMEOUT_SEC:-30}"
NOTIFY_CHANNEL="${NOTIFY_CHANNEL:-}"
NOTIFY_TARGET="${NOTIFY_TARGET:-}"
NOTIFY_ACCOUNT="${NOTIFY_ACCOUNT:-}"

mkdir -p "$STATE_DIR"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

now_iso() {
  date -Iseconds
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

json_escape() {
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

state_file() {
  local task_id="$1"
  echo "$STATE_DIR/${task_id}.json"
}

save_state() {
  local task_id="$1" phase="$2" next_action="$3" criteria="$4" note="$5"
  local file
  file="$(state_file "$task_id")"

  local next_json criteria_json note_json
  next_json="$(json_escape "$next_action")"
  criteria_json="$(json_escape "$criteria")"
  note_json="$(json_escape "$note")"

  cat >"$file" <<EOF
{
  "taskId": "${task_id}",
  "phase": "${phase}",
  "nextAction": ${next_json},
  "successCriteria": ${criteria_json},
  "note": ${note_json},
  "updatedAt": "$(now_iso)"
}
EOF

  log "状态已写入: $file"
}

emit_event() {
  local text="$1"
  if openclaw system event --mode now --text "$text" >/dev/null 2>&1; then
    log "事件已发送: $text"
    return 0
  fi
  log "WARN: 事件发送失败（忽略，不阻断流程）: $text"
  return 1
}

emit_visible() {
  local msg="$1"

  if [ -z "$NOTIFY_CHANNEL" ] || [ -z "$NOTIFY_TARGET" ]; then
    log "可见通知未配置（NOTIFY_CHANNEL/NOTIFY_TARGET），跳过"
    return 1
  fi

  local cmd=(openclaw message send --channel "$NOTIFY_CHANNEL" --target "$NOTIFY_TARGET" --message "$msg")
  if [ -n "$NOTIFY_ACCOUNT" ]; then
    cmd+=(--account "$NOTIFY_ACCOUNT")
  fi

  if "${cmd[@]}" >/dev/null 2>&1; then
    log "可见通知已发送: $NOTIFY_CHANNEL -> $NOTIFY_TARGET"
    return 0
  fi

  log "WARN: 可见通知发送失败（忽略，不阻断流程）: $NOTIFY_CHANNEL -> $NOTIFY_TARGET"
  return 1
}

wait_for_health() {
  local start_ts now_ts
  start_ts="$(date +%s)"

  while true; do
    now_ts="$(date +%s)"
    if [ $((now_ts - start_ts)) -ge "$HEALTH_TIMEOUT_SEC" ]; then
      return 1
    fi

    if openclaw gateway status >/dev/null 2>&1 && openclaw health >/dev/null 2>&1; then
      log "网关健康检查通过"
      return 0
    fi
    sleep 2
  done
}

usage() {
  cat <<'EOF'
OpenClaw restart-safe workflow

Subcommands:
  run      预检 + 落盘 + 重启 + 健康检查 + 触发恢复事件
  resume   仅触发恢复事件（用于手工补偿）
  status   查看任务状态文件

Common options:
  --task-id <id>        任务ID（默认: task-YYYYmmdd-HHMMSS）

run options:
  --title <text>        任务标题（默认: OpenClaw重启事务）
  --next <text>         重启后下一步（默认: resume-workflow）
  --criteria <text>     验收标准（默认: workflow completed and reported）
  --no-restart          只做预检与落盘，不执行重启
  --notify-channel <c>  可见通知渠道（如 feishu）
  --notify-target <t>   可见通知目标（如 user:ou_xxx / chat:oc_xxx）
  --notify-account <a>  可见通知账号ID（可选）

Examples:
  scripts/restart-safe.sh run --task-id task-001 --next "继续执行步骤3"
  scripts/restart-safe.sh run --task-id task-001 --notify-channel feishu --notify-target user:ou_xxx
  scripts/restart-safe.sh resume --task-id task-001
  scripts/restart-safe.sh status --task-id task-001
EOF
}

run_flow() {
  local task_id="$1" title="$2" next_action="$3" criteria="$4" do_restart="$5"

  log "[1/5] 预检配置: openclaw doctor --non-interactive"
  openclaw doctor --non-interactive

  log "[2/5] 写入恢复点"
  save_state "$task_id" "before-restart" "$next_action" "$criteria" "title=${title}"

  if [ "$do_restart" = "false" ]; then
    log "已按要求跳过重启（--no-restart）"
    return 0
  fi

  local notice_mark="notice-event"
  emit_event "restart-notice:${task_id}:即将执行gateway重启，短时可能无回包"
  if emit_visible "【重启通知】任务 ${task_id} 即将重启 OpenClaw Gateway，约 10~30 秒内可能短时无回包。"; then
    notice_mark="${notice_mark};notice-visible"
  fi

  log "[3/5] 执行重启: $GATEWAY_RESTART_CMD"
  bash -lc "$GATEWAY_RESTART_CMD"

  log "[4/5] 重启后健康检查"
  if ! wait_for_health; then
    local fail_mark="alert-event"
    emit_event "restart-alert:${task_id}:重启后${HEALTH_TIMEOUT_SEC}s内未通过健康检查，请立即排障"
    if emit_visible "【重启告警】任务 ${task_id} 在 ${HEALTH_TIMEOUT_SEC}s 内健康检查未通过，请执行 openclaw logs / openclaw gateway status 排障。"; then
      fail_mark="${fail_mark};alert-visible"
    fi
    save_state "$task_id" "restart-failed" "$next_action" "$criteria" "gateway health check timeout; ${notice_mark}; ${fail_mark}"
    die "重启后健康检查失败，请执行: openclaw logs && openclaw gateway status"
  fi

  log "[5/5] 触发恢复事件"
  openclaw system event --mode now --text "resume:${task_id}"

  local result_mark="result-event"
  emit_event "restart-result:${task_id}:重启恢复成功，已触发resume事件"
  if emit_visible "【重启完成】任务 ${task_id} 已恢复成功，resume 事件已触发。"; then
    result_mark="${result_mark};result-visible"
  fi

  save_state "$task_id" "resume-triggered" "$next_action" "$criteria" "system event emitted; ${notice_mark}; ${result_mark}"
  log "完成: task_id=${task_id}"
}

resume_only() {
  local task_id="$1"
  local file
  file="$(state_file "$task_id")"
  [ -f "$file" ] || die "状态文件不存在: $file"

  openclaw system event --mode now --text "resume:${task_id}"
  save_state "$task_id" "resume-triggered" "manual-resume" "n/a" "manual resume event"
  log "已发送恢复事件: resume:${task_id}"
}

status_only() {
  local task_id="$1"
  local file
  file="$(state_file "$task_id")"
  [ -f "$file" ] || die "状态文件不存在: $file"
  cat "$file"
}

main() {
  require_cmd openclaw
  require_cmd python3

  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    run|resume|status) ;;
    -h|--help|help|"") usage; exit 0 ;;
    *) die "未知子命令: $cmd" ;;
  esac

  local task_id="task-$(date +%Y%m%d-%H%M%S)"
  local title="OpenClaw重启事务"
  local next_action="resume-workflow"
  local criteria="workflow completed and reported"
  local do_restart="true"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task-id)
        task_id="${2:-}"; shift 2 ;;
      --title)
        title="${2:-}"; shift 2 ;;
      --next)
        next_action="${2:-}"; shift 2 ;;
      --criteria)
        criteria="${2:-}"; shift 2 ;;
      --no-restart)
        do_restart="false"; shift ;;
      --notify-channel)
        NOTIFY_CHANNEL="${2:-}"; shift 2 ;;
      --notify-target)
        NOTIFY_TARGET="${2:-}"; shift 2 ;;
      --notify-account)
        NOTIFY_ACCOUNT="${2:-}"; shift 2 ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        die "未知参数: $1" ;;
    esac
  done

  [ -n "$task_id" ] || die "--task-id 不能为空"

  case "$cmd" in
    run) run_flow "$task_id" "$title" "$next_action" "$criteria" "$do_restart" ;;
    resume) resume_only "$task_id" ;;
    status) status_only "$task_id" ;;
  esac
}

main "$@"
