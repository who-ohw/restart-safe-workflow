#!/usr/bin/env bash
set -euo pipefail

# OpenClaw Restart Safe Flow
# Sprint 3.5: 任务级续跑（pendingActions + resume executor + reconcile）

STATE_DIR="${STATE_DIR:-./state/restart}"
GATEWAY_RESTART_CMD="${GATEWAY_RESTART_CMD:-openclaw gateway restart}"
HEALTH_TIMEOUT_SEC="${HEALTH_TIMEOUT_SEC:-30}"
RECONCILE_MAX_RETRIES="${RECONCILE_MAX_RETRIES:-3}"
RECONCILE_BACKOFF_SEC="${RECONCILE_BACKOFF_SEC:-5}"
ACTION_ALLOWLIST_FILE="${ACTION_ALLOWLIST_FILE:-}"
NOTIFY_CHANNEL="${NOTIFY_CHANNEL:-}"
NOTIFY_TARGET="${NOTIFY_TARGET:-}"
NOTIFY_ACCOUNT="${NOTIFY_ACCOUNT:-}"

mkdir -p "$STATE_DIR"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*"; }
die() { log "ERROR: $*"; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }

state_file() { echo "$STATE_DIR/$1.json"; }
runner_log_file() { echo "$STATE_DIR/$1.runner.log"; }

is_notify_required() {
  [ -n "$NOTIFY_CHANNEL" ] && [ -n "$NOTIFY_TARGET" ]
}

state_init() {
  local task_id="$1" title="$2" next_action="$3" criteria="$4"
  local file; file="$(state_file "$task_id")"
  python3 - "$file" "$task_id" "$title" "$next_action" "$criteria" <<'PY'
import json, os, sys
from datetime import datetime, timezone
file, task_id, title, next_action, criteria = sys.argv[1:]
now = datetime.now(timezone.utc).astimezone().isoformat(timespec='seconds')
if os.path.exists(file):
    with open(file, 'r', encoding='utf-8') as f: obj = json.load(f)
else:
    obj = {
      "taskId": task_id,
      "phase": "init",
      "attempt": 0,
      "startedAt": now,
      "updatedAt": now,
      "title": title,
      "nextAction": next_action,
      "successCriteria": criteria,
      "doctorOk": False,
      "checkpointed": False,
      "restartIssued": False,
      "restartCompleted": False,
      "healthOk": False,
      "resumeEventSent": False,
      "notifyPreSent": False,
      "notifyPreMessageId": "",
      "notifyPostSent": False,
      "notifyPostMessageId": "",
      "notifyAlertSent": False,
      "notifyAlertMessageId": "",
      "resumeStatus": "idle",
      "resumeCursor": 0,
      "resumeError": "",
      "resumeLastAt": "",
      "resumeRetryCount": 0,
      "pendingActions": [],
      "resumeCompletedActions": [],
      "lastError": "",
      "runnerPid": "",
      "runnerLog": "",
      "timeline": []
    }
obj.setdefault("taskId", task_id)
obj["title"] = title
obj["nextAction"] = next_action
obj["successCriteria"] = criteria
obj["updatedAt"] = now
obj.setdefault("timeline", [])
obj.setdefault("pendingActions", [])
obj.setdefault("resumeCompletedActions", [])
obj.setdefault("escalationRequired", False)
obj.setdefault("escalationReason", "")
with open(file, 'w', encoding='utf-8') as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
PY
}

state_update() {
  local task_id="$1" phase="$2" note="$3" extra_json="${4:-}"
  [ -n "$extra_json" ] || extra_json='{}'
  local file; file="$(state_file "$task_id")"

  python3 - "$file" "$phase" "$note" "$extra_json" <<'PY'
import json, os, sys
from datetime import datetime, timezone
file, phase, note, extra_raw = sys.argv[1:]
now = datetime.now(timezone.utc).astimezone().isoformat(timespec='seconds')
if os.path.exists(file):
    with open(file, 'r', encoding='utf-8') as f: obj = json.load(f)
else:
    obj = {"timeline": []}
try:
    extra = json.loads(extra_raw)
except Exception:
    extra = {}
obj["phase"] = phase
obj["updatedAt"] = now
obj.setdefault("timeline", []).append({"at": now, "phase": phase, "note": note})
for k, v in extra.items():
    obj[k] = v
with open(file, 'w', encoding='utf-8') as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
PY

  log "状态已写入: ${file} (phase=${phase})"
}

state_bump_attempt() {
  local task_id="$1"; local file; file="$(state_file "$task_id")"
  python3 - "$file" <<'PY'
import json, os, sys
from datetime import datetime, timezone
file = sys.argv[1]
now = datetime.now(timezone.utc).astimezone().isoformat(timespec='seconds')
if os.path.exists(file):
    with open(file, 'r', encoding='utf-8') as f: obj = json.load(f)
else:
    obj = {"timeline": []}
obj["attempt"] = int(obj.get("attempt", 0)) + 1
obj["updatedAt"] = now
with open(file, 'w', encoding='utf-8') as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
PY
}

state_get() {
  local task_id="$1" key="$2"; local file; file="$(state_file "$task_id")"
  python3 - "$file" "$key" <<'PY'
import json, sys
f, k = sys.argv[1:]
with open(f, 'r', encoding='utf-8') as fh: obj = json.load(fh)
cur = obj
for p in k.split('.'):
    if isinstance(cur, dict) and p in cur:
        cur = cur[p]
    else:
        print('')
        raise SystemExit(0)
if isinstance(cur, bool):
    print('true' if cur else 'false')
elif cur is None:
    print('')
else:
    print(cur)
PY
}

emit_event() {
  local text="$1"
  if openclaw system event --mode now --text "$text" >/dev/null 2>&1; then
    log "事件已发送: $text"; return 0
  fi
  log "WARN: 事件发送失败（忽略，不阻断流程）: $text"; return 1
}

extract_message_id() {
  printf '%s' "$1" | sed -n 's/.*"messageId"[[:space:]]*:[[:space:]]*"\([^"]\+\)".*/\1/p' | head -n 1
}

emit_visible() {
  local task_id="$1" kind="$2" msg="$3"
  if ! is_notify_required; then
    log "可见通知未配置（NOTIFY_CHANNEL/NOTIFY_TARGET），跳过"
    return 1
  fi

  local sent_key msgid_key
  case "$kind" in
    pre) sent_key="notifyPreSent"; msgid_key="notifyPreMessageId" ;;
    post) sent_key="notifyPostSent"; msgid_key="notifyPostMessageId" ;;
    alert) sent_key="notifyAlertSent"; msgid_key="notifyAlertMessageId" ;;
    *) die "未知通知类型: $kind" ;;
  esac

  if [ "$(state_get "$task_id" "$sent_key" || true)" = "true" ]; then
    log "可见通知已存在（kind=$kind），跳过重复发送"
    return 0
  fi

  local cmd=(openclaw message send --json --channel "$NOTIFY_CHANNEL" --target "$NOTIFY_TARGET" --message "$msg")
  [ -n "$NOTIFY_ACCOUNT" ] && cmd+=(--account "$NOTIFY_ACCOUNT")

  local out
  if out="$("${cmd[@]}" 2>&1)"; then
    local message_id
    message_id="$(extract_message_id "$out")"
    state_update "$task_id" "$(state_get "$task_id" phase)" "visible-notify:${kind}" "{\"${sent_key}\":true,\"${msgid_key}\":\"${message_id}\",\"lastError\":\"\"}"
    log "可见通知已发送: $NOTIFY_CHANNEL -> $NOTIFY_TARGET (kind=$kind, messageId=${message_id:-unknown})"
    return 0
  fi

  log "WARN: 可见通知发送失败（kind=$kind）: $out"
  return 1
}

wait_for_health() {
  local start_ts now_ts
  start_ts="$(date +%s)"
  while true; do
    now_ts="$(date +%s)"
    [ $((now_ts - start_ts)) -lt "$HEALTH_TIMEOUT_SEC" ] || return 1
    if openclaw gateway status >/dev/null 2>&1 && openclaw health >/dev/null 2>&1; then
      log "网关健康检查通过"; return 0
    fi
    sleep 2
  done
}

set_resume_status() {
  local task_id="$1" status="$2" err="${3:-}"
  local extra
  extra="{\"resumeStatus\":\"$status\",\"resumeError\":\"$err\",\"resumeLastAt\":\"$(date -Iseconds)\"}"
  state_update "$task_id" "$(state_get "$task_id" phase)" "resume-status:${status}" "$extra"
}

actions_to_readable() {
  local file="$1" key="$2"
  python3 - "$file" "$key" <<'PY'
import json,sys
f,key=sys.argv[1:]
obj=json.load(open(f,'r',encoding='utf-8'))
arr=obj.get(key,[])
lines=[]
for i,a in enumerate(arr,1):
    t=a.get('type','notify')
    aid=a.get('actionId',f'a{i}')
    if t=='notify':
        d=a.get('text','')
    elif t=='command':
        d=a.get('command','')
    elif t=='script':
        d=a.get('path','')
    else:
        d=str(a)
    lines.append(f"{i}. [{aid}] {t}: {d}")
print('\n'.join(lines))
PY
}

emit_resume_summary() {
  local task_id="$1" stage="$2"
  local file; file="$(state_file "$task_id")"
  [ -f "$file" ] || return 0
  if ! is_notify_required; then
    return 0
  fi

  local pending done cursor
  pending="$(actions_to_readable "$file" pendingActions)"
  done="$(actions_to_readable "$file" resumeCompletedActions)"
  cursor="$(state_get "$task_id" resumeCursor)"
  [ -n "$cursor" ] || cursor="0"

  local msg
  case "$stage" in
    pre)
      msg="【重启前任务清单】任务 ${task_id}\n正在处理：重启事务执行链路\n重启后预计处理：\n${pending:-（无）}" ;;
    post-plan)
      msg="【重启后待处理任务】任务 ${task_id}\n待处理清单：\n${pending:-（无）}\n当前游标：${cursor}" ;;
    post-result)
      msg="【重启后任务执行结果】任务 ${task_id}\n已完成：\n${done:-（无）}\n剩余待处理：\n${pending:-（无）}" ;;
    *) return 0 ;;
  esac

  local cmd=(openclaw message send --json --channel "$NOTIFY_CHANNEL" --target "$NOTIFY_TARGET" --message "$msg")
  [ -n "$NOTIFY_ACCOUNT" ] && cmd+=(--account "$NOTIFY_ACCOUNT")
  local out
  out="$("${cmd[@]}" 2>&1)" || { log "WARN: 任务清单通知失败(stage=$stage): $out"; return 1; }
  log "任务清单通知已发送(stage=$stage)"
  return 0
}

parse_next_actions_json() {
  local next_action="$1"
  python3 - "$next_action" <<'PY'
import json, re, sys
s = sys.argv[1].strip()
actions = []

if not s:
    print('[]')
    raise SystemExit(0)

if s.startswith('json:'):
    raw = s[5:].strip()
    obj = json.loads(raw)
    if isinstance(obj, dict):
      obj=[obj]
    if not isinstance(obj, list):
      raise ValueError('json: must be list/dict')
    actions = obj
elif s.startswith('notify:'):
    actions = [{"type":"notify","text":s[7:].strip() or "(empty notify)"}]
elif s.startswith('cmd:'):
    actions = [{"type":"command","command":s[4:].strip()}]
elif s.startswith('script:'):
    actions = [{"type":"script","path":s[7:].strip()}]
else:
    # 默认把 nextAction 当作用户可见续跑说明
    actions = [{"type":"notify","text":f"【任务续跑】{s}"}]

for i,a in enumerate(actions):
    if not isinstance(a, dict):
        raise ValueError('action must be object')
    a.setdefault('actionId', f'a{i+1}')
    a.setdefault('type', 'notify')

print(json.dumps(actions, ensure_ascii=False))
PY
}

queue_resume_actions() {
  local task_id="$1" next_action="$2"
  local actions_json
  if ! actions_json="$(parse_next_actions_json "$next_action" 2>/tmp/restart-parse.err)"; then
    local err; err="$(cat /tmp/restart-parse.err 2>/dev/null | tr '\n' ' ' | sed 's/"/\\"/g')"
    state_update "$task_id" "resume-failed" "parse-next-action-failed" "{\"resumeStatus\":\"failed\",\"resumeError\":\"$err\",\"lastError\":\"parse nextAction failed\"}"
    return 1
  fi

  state_update "$task_id" "resume-queued" "resume-actions-queued" "{\"pendingActions\":$actions_json,\"resumeCompletedActions\":[],\"resumeCursor\":0,\"resumeStatus\":\"idle\",\"resumeError\":\"\",\"resumeRetryCount\":0}"
  return 0
}

is_allowed_command() {
  local cmd="$1"

  # Optional external allowlist (plain text, one prefix per line, supports comments)
  if [ -n "$ACTION_ALLOWLIST_FILE" ] && [ -f "$ACTION_ALLOWLIST_FILE" ]; then
    while IFS= read -r line; do
      line="${line%%#*}"
      line="$(echo "$line" | xargs)"
      [ -n "$line" ] || continue
      if [[ "$cmd" == "$line"* ]]; then
        return 0
      fi
    done < "$ACTION_ALLOWLIST_FILE"
    return 1
  fi

  case "$cmd" in
    "openclaw gateway status"*|"openclaw health"*|"openclaw status"*|"date"*|"echo "*)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

is_allowed_script() {
  local p="$1"
  case "$p" in
    skills/restart-safe-workflow/scripts/*|/home/ubuntu/.openclaw/workspace/skills/restart-safe-workflow/scripts/*)
      if [[ "$p" == *".."* ]]; then
        return 1
      fi
      return 0 ;;
    *) return 1 ;;
  esac
}

execute_action() {
  local task_id="$1" action_json="$2"

  local action_type action_id action_text action_cmd action_path
  action_type="$(python3 - "$action_json" <<'PY'
import json,sys
obj=json.loads(sys.argv[1]); print(obj.get('type','notify'))
PY
)"
  action_id="$(python3 - "$action_json" <<'PY'
import json,sys
obj=json.loads(sys.argv[1]); print(obj.get('actionId',''))
PY
)"

  case "$action_type" in
    notify)
      action_text="$(python3 - "$action_json" <<'PY'
import json,sys
obj=json.loads(sys.argv[1]); print(obj.get('text',''))
PY
)"
      if ! is_notify_required; then
        log "续跑 notify 动作缺少通知配置"
        return 1
      fi
      # 续跑动作的通知使用 post 通道，不写入 notifyPostSent，避免污染主流程判据
      local out cmd
      cmd=(openclaw message send --json --channel "$NOTIFY_CHANNEL" --target "$NOTIFY_TARGET" --message "$action_text")
      [ -n "$NOTIFY_ACCOUNT" ] && cmd+=(--account "$NOTIFY_ACCOUNT")
      out="$("${cmd[@]}" 2>&1)" || { log "续跑 notify 失败(actionId=$action_id): $out"; return 1; }
      log "续跑 notify 成功(actionId=$action_id)"
      ;;
    command)
      action_cmd="$(python3 - "$action_json" <<'PY'
import json,sys
obj=json.loads(sys.argv[1]); print(obj.get('command',''))
PY
)"
      if ! is_allowed_command "$action_cmd"; then
        log "续跑 command 不在白名单(actionId=$action_id): $action_cmd"
        return 1
      fi
      bash -lc "$action_cmd" >/tmp/restart-action-${task_id}-${action_id}.out 2>&1 || {
        log "续跑 command 执行失败(actionId=$action_id): $action_cmd"
        return 1
      }
      log "续跑 command 成功(actionId=$action_id): $action_cmd"
      ;;
    script)
      action_path="$(python3 - "$action_json" <<'PY'
import json,sys
obj=json.loads(sys.argv[1]); print(obj.get('path',''))
PY
)"
      if ! is_allowed_script "$action_path"; then
        log "续跑 script 不在白名单(actionId=$action_id): $action_path"
        return 1
      fi
      bash -lc "$action_path" >/tmp/restart-script-${task_id}-${action_id}.out 2>&1 || {
        log "续跑 script 执行失败(actionId=$action_id): $action_path"
        return 1
      }
      log "续跑 script 成功(actionId=$action_id): $action_path"
      ;;
    *)
      log "未知续跑动作类型(actionId=$action_id): $action_type"
      return 1 ;;
  esac

  return 0
}

run_resume_actions() {
  local task_id="$1"
  local file; file="$(state_file "$task_id")"
  [ -f "$file" ] || die "状态文件不存在: $file"

  set_resume_status "$task_id" running ""
  state_update "$task_id" "resume-running" "resume-actions-running" '{}'

  local actions_count cursor
  actions_count="$(python3 - "$file" <<'PY'
import json,sys
obj=json.load(open(sys.argv[1],'r',encoding='utf-8'))
print(len(obj.get('pendingActions',[])))
PY
)"
  cursor="$(state_get "$task_id" resumeCursor)"
  [ -n "$cursor" ] || cursor="0"

  if [ "$actions_count" -eq 0 ]; then
    set_resume_status "$task_id" success ""
    state_update "$task_id" "resume-done" "resume-actions-empty" '{}'
    return 0
  fi

  local idx action_json action_id
  idx="$cursor"
  while [ "$idx" -lt "$actions_count" ]; do
    action_json="$(python3 - "$file" "$idx" <<'PY'
import json,sys
obj=json.load(open(sys.argv[1],'r',encoding='utf-8'))
idx=int(sys.argv[2])
print(json.dumps(obj.get('pendingActions',[])[idx], ensure_ascii=False))
PY
)"
    action_id="$(python3 - "$action_json" <<'PY'
import json,sys
print(json.loads(sys.argv[1]).get('actionId',''))
PY
)"

    state_update "$task_id" "resume-running" "resume-action-start:${action_id}" '{}'
    if execute_action "$task_id" "$action_json"; then
      idx=$((idx+1))
      local file_now
      file_now="$(state_file "$task_id")"
      local completed_json pending_json
      completed_json="$(python3 - "$file_now" "$action_id" <<'PY'
import json,sys
f,aid=sys.argv[1:]
obj=json.load(open(f,'r',encoding='utf-8'))
pending=obj.get('pendingActions',[])
done=obj.get('resumeCompletedActions',[])
for a in pending:
    if str(a.get('actionId',''))==aid:
        done.append(a)
        break
print(json.dumps(done, ensure_ascii=False))
PY
)"
      pending_json="$(python3 - "$file_now" "$action_id" <<'PY'
import json,sys
f,aid=sys.argv[1:]
obj=json.load(open(f,'r',encoding='utf-8'))
pending=obj.get('pendingActions',[])
pending=[a for a in pending if str(a.get('actionId',''))!=aid]
print(json.dumps(pending, ensure_ascii=False))
PY
)"
      state_update "$task_id" "resume-running" "resume-action-ok:${action_id}" "{\"resumeCursor\":$idx,\"resumeCompletedActions\":$completed_json,\"pendingActions\":$pending_json}"
    else
      local retry
      retry="$(state_get "$task_id" resumeRetryCount)"
      [ -n "$retry" ] || retry="0"
      retry=$((retry+1))
      state_update "$task_id" "resume-failed" "resume-action-fail:${action_id}" "{\"resumeStatus\":\"failed\",\"resumeError\":\"action failed: ${action_id}\",\"resumeRetryCount\":$retry,\"resumeCursor\":$idx,\"lastError\":\"resume action failed\"}"
      return 1
    fi
  done

  set_resume_status "$task_id" success ""
  state_update "$task_id" "resume-done" "resume-actions-complete" "{\"resumeCursor\":$actions_count}"
  return 0
}

mark_done_if_complete() {
  local task_id="$1"
  local ok_health ok_resume ok_pre ok_post ok_resume_actions
  ok_health="$(state_get "$task_id" healthOk)"
  ok_resume="$(state_get "$task_id" resumeEventSent)"
  ok_pre="$(state_get "$task_id" notifyPreSent)"
  ok_post="$(state_get "$task_id" notifyPostSent)"
  ok_resume_actions="$(state_get "$task_id" resumeStatus)"

  if ! is_notify_required; then
    ok_pre="true"; ok_post="true"
  fi

  if [ "$ok_health" = "true" ] && [ "$ok_resume" = "true" ] && [ "$ok_pre" = "true" ] && [ "$ok_post" = "true" ] && [ "$ok_resume_actions" = "success" ]; then
    state_update "$task_id" "done" "workflow-complete" '{"lastError":""}'
    return 0
  fi

  state_update "$task_id" "notify-failed" "completion-gate-blocked" "{\"lastError\":\"completion gate blocked: health/resume/notify/resumeActions not satisfied\"}"
  return 1
}

finalize_after_restart() {
  local task_id="$1"

  local restart_completed
  restart_completed="$(state_get "$task_id" restartCompleted)"
  if [ "$restart_completed" != "true" ]; then
    state_update "$task_id" "notify-failed" "finalize-without-restart-complete" '{"lastError":"finalize blocked: restartCompleted!=true"}'
    return 1
  fi

  log "[F1] 重启后健康检查"
  if ! wait_for_health; then
    state_update "$task_id" "health-failed" "health-timeout" '{"healthOk":false,"lastError":"gateway health check timeout"}'
    emit_event "restart-alert:${task_id}:重启后${HEALTH_TIMEOUT_SEC}s内未通过健康检查，请立即排障"
    emit_visible "$task_id" alert "【重启告警】任务 ${task_id} 在 ${HEALTH_TIMEOUT_SEC}s 内健康检查未通过，请执行 openclaw logs / openclaw gateway status 排障。" || true
    return 1
  fi
  state_update "$task_id" "health-ok" "health-check-passed" '{"healthOk":true,"lastError":""}'

  log "[F2] 触发恢复事件"
  if openclaw system event --mode now --text "resume:${task_id}"; then
    state_update "$task_id" "resumed" "resume-event-sent" '{"resumeEventSent":true,"lastError":""}'
  else
    state_update "$task_id" "resumed" "resume-event-failed" '{"resumeEventSent":false,"lastError":"resume event failed"}'
    return 1
  fi

  emit_event "restart-result:${task_id}:重启恢复成功，已触发resume事件"
  if is_notify_required; then
    if ! emit_visible "$task_id" post "【重启完成】任务 ${task_id} 已恢复成功，resume 事件已触发。"; then
      state_update "$task_id" "notify-failed" "post-notify-failed" '{"lastError":"post visible notify failed"}'
      return 1
    fi
  fi

  state_update "$task_id" "post-notified" "post-notify-finished" '{}'

  emit_resume_summary "$task_id" post-plan || true

  log "[F3] 执行任务续跑动作"
  if ! run_resume_actions "$task_id"; then
    return 1
  fi

  emit_resume_summary "$task_id" post-result || true

  mark_done_if_complete "$task_id"
}

continue_flow() {
  local task_id="$1"
  local file; file="$(state_file "$task_id")"
  [ -f "$file" ] || die "状态文件不存在: $file"

  local phase; phase="$(state_get "$task_id" phase)"
  if [ "$phase" = "done" ]; then
    log "任务已完成，跳过 continue: $task_id"; return 0
  fi

  state_update "$task_id" "restarting" "restart-command-issued" '{"restartIssued":true,"lastError":""}'

  log "[C1] 执行重启: $GATEWAY_RESTART_CMD"
  if ! bash -lc "$GATEWAY_RESTART_CMD"; then
    state_update "$task_id" "restart-failed" "restart-command-failed" '{"restartIssued":true,"restartCompleted":false,"lastError":"restart command failed"}'
    emit_event "restart-alert:${task_id}:重启命令执行失败"
    emit_visible "$task_id" alert "【重启告警】任务 ${task_id} 重启命令执行失败，请排障。" || true
    return 1
  fi

  state_update "$task_id" "restarting" "restart-command-complete" '{"restartCompleted":true,"lastError":""}'
  finalize_after_restart "$task_id"
}

reconcile_one() {
  local task_id="$1"
  local file; file="$(state_file "$task_id")"
  [ -f "$file" ] || return 0

  local phase restart_completed retry
  phase="$(state_get "$task_id" phase)"
  restart_completed="$(state_get "$task_id" restartCompleted)"
  retry="$(state_get "$task_id" resumeRetryCount)"
  [ -n "$retry" ] || retry="0"
  if [ "$retry" != "" ]; then
    retry="$(printf '%s' "$retry" | sed 's/[^0-9].*$//')"
  fi
  [ -n "$retry" ] || retry="0"

  case "$phase" in
    done)
      log "reconcile: $task_id 已完成，跳过"; return 0 ;;
    resumed|post-notified|notify-failed|health-ok|resume-failed|resume-running|resume-queued|resume-done)
      if [ "$restart_completed" = "true" ]; then
        if [ "$retry" -ge "$RECONCILE_MAX_RETRIES" ]; then
          state_update "$task_id" "$phase" "reconcile-escalated" "{"escalationRequired":true,"escalationReason":"retry_exceeded","lastError":"reconcile retry exceeded"}"
          log "reconcile: $task_id 超过重试上限，升级人工处理"
          if is_notify_required; then
            local msg="【重启补偿告警】任务 ${task_id} 已超过补偿重试上限(${RECONCILE_MAX_RETRIES})，请人工介入。"
            local cmd=(openclaw message send --json --channel "$NOTIFY_CHANNEL" --target "$NOTIFY_TARGET" --message "$msg")
            [ -n "$NOTIFY_ACCOUNT" ] && cmd+=(--account "$NOTIFY_ACCOUNT")
            "${cmd[@]}" >/dev/null 2>&1 || true
          fi
          return 1
        fi

        if [ "$retry" -gt 0 ]; then
          local backoff=$((RECONCILE_BACKOFF_SEC * retry))
          log "reconcile: $task_id 退避 ${backoff}s 后重试"
          sleep "$backoff"
        fi

        state_update "$task_id" "$phase" "reconcile-retry" "{"resumeRetryCount":$((retry+1))}"
        log "reconcile: 修复后置流程 $task_id (phase=$phase)"
        finalize_after_restart "$task_id" || true
      else
        log "reconcile: $task_id restartCompleted!=true，跳过"
      fi
      ;;
    *)
      log "reconcile: $task_id 当前 phase=$phase，不在补偿范围" ;;
  esac
}

reconcile_flow() {
  local only_task_id="${1:-}"
  if [ -n "$only_task_id" ]; then
    reconcile_one "$only_task_id"
    return 0
  fi

  shopt -s nullglob
  local f id
  for f in "$STATE_DIR"/*.json; do
    id="$(basename "$f" .json)"
    reconcile_one "$id"
  done
}

resume_run_only() {
  local task_id="$1"
  local file; file="$(state_file "$task_id")"
  [ -f "$file" ] || die "状态文件不存在: $file"
  run_resume_actions "$task_id"
}

spawn_detached_continue() {
  local task_id="$1"
  local log_file script_abs cwd pid
  log_file="$(runner_log_file "$task_id")"
  script_abs="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  cwd="$(pwd)"

  STATE_DIR="$STATE_DIR" \
  GATEWAY_RESTART_CMD="$GATEWAY_RESTART_CMD" \
  HEALTH_TIMEOUT_SEC="$HEALTH_TIMEOUT_SEC" \
  NOTIFY_CHANNEL="$NOTIFY_CHANNEL" \
  NOTIFY_TARGET="$NOTIFY_TARGET" \
  NOTIFY_ACCOUNT="$NOTIFY_ACCOUNT" \
  nohup bash -lc "cd '$cwd' && '$script_abs' continue --task-id '$task_id'" >"$log_file" 2>&1 < /dev/null &

  pid="$!"
  state_update "$task_id" "restarting" "detached-runner-started" "{\"runnerPid\":\"$pid\",\"runnerLog\":\"$log_file\",\"restartIssued\":true}"
  log "已启动 detached runner: pid=$pid log=$log_file"
}

usage() {
  cat <<'EOF'
OpenClaw restart-safe workflow

Subcommands:
  run         预检 + 落盘 + （默认 detached）重启后续流程
  continue    detached runner 执行重启 + finalize
  resume-run  仅执行 pendingActions（不重启）
  reconcile   对未闭环任务执行补偿（可指定 --task-id）
  report      输出任务摘要（简版）
  diagnose    输出任务诊断建议
  resume      仅触发恢复事件（手工补偿）
  status      查看任务状态文件

run options:
  --task-id <id>        任务ID（默认 task-YYYYmmdd-HHMMSS）
  --title <text>        任务标题
  --next <text>         重启后下一步（支持 notify:/cmd:/script:/json:）
  --criteria <text>     验收标准
  --no-restart          只做预检与落盘，不执行重启
  --inline              不使用 detached runner，内联执行（调试用）
  --notify-channel <c>  可见通知渠道（如 feishu）
  --notify-target <t>   可见通知目标（user:ou_xxx / chat:oc_xxx）
  --notify-account <a>  可见通知账号ID（可选）

Env:
  RECONCILE_MAX_RETRIES  补偿最大重试次数（默认3）
  RECONCILE_BACKOFF_SEC  补偿退避秒数（默认5）
  ACTION_ALLOWLIST_FILE  命令白名单文件（每行一个前缀）

State phases:
  init -> prechecked -> checkpointed -> resume-queued -> restarting -> health-ok -> resumed -> post-notified -> resume-running -> resume-done -> done
  failures: doctor-failed / restart-failed / health-failed / notify-failed / resume-failed
EOF
}

run_flow() {
  local task_id="$1" title="$2" next_action="$3" criteria="$4" do_restart="$5" inline_mode="$6"

  state_init "$task_id" "$title" "$next_action" "$criteria"
  state_bump_attempt "$task_id"
  state_update "$task_id" "init" "run-start" '{}'

  log "[1/4] 预检配置: openclaw doctor --non-interactive"
  if openclaw doctor --non-interactive; then
    state_update "$task_id" "prechecked" "doctor-ok" '{"doctorOk":true,"checkpointed":false,"restartIssued":false,"restartCompleted":false,"healthOk":false,"resumeEventSent":false,"lastError":""}'
  else
    state_update "$task_id" "doctor-failed" "doctor-failed" '{"doctorOk":false,"checkpointed":false,"restartIssued":false,"restartCompleted":false,"healthOk":false,"resumeEventSent":false,"lastError":"doctor check failed"}'
    die "doctor 失败，已阻断重启"
  fi

  log "[2/4] 写入恢复点"
  state_update "$task_id" "checkpointed" "checkpoint-written" '{"checkpointed":true,"lastError":""}'

  log "[3/4] 解析并入队续跑动作"
  if ! queue_resume_actions "$task_id" "$next_action"; then
    return 1
  fi

  if [ "$do_restart" = "false" ]; then
    log "已按要求跳过重启（--no-restart）"
    return 0
  fi

  log "[4/4] 发送重启前通知并启动重启链路"
  emit_event "restart-notice:${task_id}:即将执行gateway重启，短时可能无回包"
  if is_notify_required; then
    if ! emit_visible "$task_id" pre "【重启通知】任务 ${task_id} 即将重启 OpenClaw Gateway，约 10~30 秒内可能短时无回包。"; then
      state_update "$task_id" "notify-failed" "pre-notify-failed" '{"lastError":"pre visible notify failed"}'
      return 1
    fi
    emit_resume_summary "$task_id" pre || true
  fi

  if [ "$inline_mode" = "true" ]; then
    log "内联执行 continue（--inline）"
    continue_flow "$task_id"
  else
    log "启动 detached continue runner"
    spawn_detached_continue "$task_id"
  fi
}

resume_only() {
  local task_id="$1"
  local file; file="$(state_file "$task_id")"
  [ -f "$file" ] || die "状态文件不存在: $file"
  if openclaw system event --mode now --text "resume:${task_id}"; then
    state_update "$task_id" "resumed" "manual-resume-event-sent" '{"resumeEventSent":true,"lastError":""}'
    log "已发送恢复事件: resume:${task_id}"; return 0
  fi
  state_update "$task_id" "resumed" "manual-resume-event-failed" '{"resumeEventSent":false,"lastError":"manual resume event failed"}'
  die "恢复事件发送失败: resume:${task_id}"
}


report_only() {
  local task_id="$1"; local file; file="$(state_file "$task_id")"
  [ -f "$file" ] || die "状态文件不存在: $file"
  python3 - "$file" <<'PY'
import json,sys
obj=json.load(open(sys.argv[1],'r',encoding='utf-8'))
summary={
 "taskId":obj.get("taskId"),
 "phase":obj.get("phase"),
 "attempt":obj.get("attempt"),
 "healthOk":obj.get("healthOk"),
 "resumeEventSent":obj.get("resumeEventSent"),
 "resumeStatus":obj.get("resumeStatus"),
 "resumeCursor":obj.get("resumeCursor"),
 "pendingCount":len(obj.get("pendingActions",[])),
 "completedCount":len(obj.get("resumeCompletedActions",[])),
 "notifyPreSent":obj.get("notifyPreSent"),
 "notifyPostSent":obj.get("notifyPostSent"),
 "escalationRequired":obj.get("escalationRequired",False),
 "escalationReason":obj.get("escalationReason","")
}
print(json.dumps(summary,ensure_ascii=False,indent=2))
PY
}

diagnose_only() {
  local task_id="$1"; local file; file="$(state_file "$task_id")"
  [ -f "$file" ] || die "状态文件不存在: $file"
  python3 - "$file" <<'PY'
import json,sys
obj=json.load(open(sys.argv[1],'r',encoding='utf-8'))
phase=obj.get('phase','')
issues=[]
if not obj.get('doctorOk'): issues.append('doctor 未通过')
if obj.get('restartIssued') and not obj.get('restartCompleted'): issues.append('重启命令未完成')
if obj.get('restartCompleted') and not obj.get('healthOk'): issues.append('重启后健康检查未通过')
if obj.get('healthOk') and not obj.get('resumeEventSent'): issues.append('resume 事件未发送')
if obj.get('resumeStatus')!='success': issues.append('任务续跑未成功')
if obj.get('notifyPreSent') is False: issues.append('重启前可见通知未送达')
if obj.get('notifyPostSent') is False: issues.append('重启后可见通知未送达')
if phase!='done': issues.append(f'当前phase={phase} 未完成')
if not issues:
    print('DIAGNOSE: OK (无阻塞问题)')
else:
    print('DIAGNOSE: NEED_ACTION')
    for i,x in enumerate(issues,1):
        print(f'{i}. {x}')
PY
}

status_only() {
  local task_id="$1"; local file; file="$(state_file "$task_id")"
  [ -f "$file" ] || die "状态文件不存在: $file"
  cat "$file"
}

main() {
  require_cmd openclaw
  require_cmd python3

  local cmd="${1:-}"; shift || true
  case "$cmd" in
    run|continue|resume-run|reconcile|report|diagnose|resume|status) ;;
    -h|--help|help|"") usage; exit 0 ;;
    *) die "未知子命令: $cmd" ;;
  esac

  local task_id="task-$(date +%Y%m%d-%H%M%S)"
  local task_id_set="false"
  local title="OpenClaw重启事务"
  local next_action="resume-workflow"
  local criteria="workflow completed and reported"
  local do_restart="true"
  local inline_mode="false"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task-id) task_id="${2:-}"; task_id_set="true"; shift 2 ;;
      --title) title="${2:-}"; shift 2 ;;
      --next) next_action="${2:-}"; shift 2 ;;
      --criteria) criteria="${2:-}"; shift 2 ;;
      --no-restart) do_restart="false"; shift ;;
      --inline) inline_mode="true"; shift ;;
      --notify-channel) NOTIFY_CHANNEL="${2:-}"; shift 2 ;;
      --notify-target) NOTIFY_TARGET="${2:-}"; shift 2 ;;
      --notify-account) NOTIFY_ACCOUNT="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数: $1" ;;
    esac
  done

  [ -n "$task_id" ] || die "--task-id 不能为空"

  case "$cmd" in
    run) run_flow "$task_id" "$title" "$next_action" "$criteria" "$do_restart" "$inline_mode" ;;
    continue) continue_flow "$task_id" ;;
    resume-run) resume_run_only "$task_id" ;;
    reconcile)
      if [ "$task_id_set" = "true" ]; then
        reconcile_flow "$task_id"
      else
        reconcile_flow
      fi ;;
    report) report_only "$task_id" ;;
    diagnose) diagnose_only "$task_id" ;;
    resume) resume_only "$task_id" ;;
    status) status_only "$task_id" ;;
  esac
}

main "$@"
