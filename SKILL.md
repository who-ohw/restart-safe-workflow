---
name: restart-safe-workflow
description: Safe OpenClaw gateway restart workflow with doctor precheck, checkpoint persistence, health verification, resume trigger, task continuation, reconciliation retries, and user-visible notifications.
---

# Restart Safe Workflow (Sprint 4)

用于 OpenClaw 的“可恢复重启 + 任务续跑 + 补偿可观测”流程，避免重启导致任务丢失、无回执、不可诊断。

## 适用场景
- 需要执行 `openclaw gateway restart` 的任务
- 配置变更后需要安全重启并可追踪恢复
- 需要向用户发送重启前后可见回执
- 需要重启后自动继续执行任务（pendingActions）
- 需要失败重试、升级告警与诊断

## 快速开始

### 1) 安全执行一次重启（带任务续跑）
```bash
skills/restart-safe-workflow/scripts/restart-safe.sh run \
  --task-id task-$(date +%Y%m%d-%H%M%S) \
  --next "notify:重启后继续执行步骤3" \
  --criteria "重启成功且续跑完成"
```

### 2) 带用户可见回执（Feishu）
```bash
skills/restart-safe-workflow/scripts/restart-safe.sh run \
  --task-id task-$(date +%Y%m%d-%H%M%S) \
  --next "cmd:echo post-restart-step" \
  --criteria "回执可见+续跑成功" \
  --notify-channel feishu \
  --notify-target user:<open_id> \
  --notify-account master
```

### 3) 仅执行续跑动作（不重启）
```bash
skills/restart-safe-workflow/scripts/restart-safe.sh resume-run --task-id <task-id>
```

### 4) 对未闭环任务做补偿
```bash
skills/restart-safe-workflow/scripts/restart-safe.sh reconcile --task-id <task-id>
# 或批量
skills/restart-safe-workflow/scripts/restart-safe.sh reconcile
```

### 5) 任务摘要与诊断
```bash
skills/restart-safe-workflow/scripts/restart-safe.sh report --task-id <task-id>
skills/restart-safe-workflow/scripts/restart-safe.sh diagnose --task-id <task-id>
```

### 6) 一键验收
```bash
# 默认不真实重启
skills/restart-safe-workflow/scripts/restart-acceptance.sh

# 启用真实重启链路
skills/restart-safe-workflow/scripts/restart-acceptance.sh --with-restart \
  --notify-channel feishu --notify-target user:<open_id> --notify-account master
```

## `--next` 动作格式
- `notify:<text>`：发送可见消息
- `cmd:<command>`：执行白名单命令
- `script:<path>`：执行白名单脚本
- `json:[{...}]`：传入动作数组

动作对象示例：
```json
[{"actionId":"a1","type":"command","command":"openclaw health"}]
```

## 状态文件
- 路径：`state/restart/<task-id>.json`
- 验收报告：`state/restart/acceptance-<task-prefix>.log`

关键字段：
- `phase`：流程阶段
- `resumeStatus`：`idle|running|success|failed`
- `pendingActions`：待执行动作
- `resumeCompletedActions`：已完成动作
- `resumeCursor`：执行游标
- `notifyPreSent / notifyPostSent`
- `escalationRequired / escalationReason`

关键阶段：
- `init -> prechecked -> checkpointed -> resume-queued -> restarting -> health-ok -> resumed -> post-notified -> resume-running -> resume-done -> done`
- 失败态：`doctor-failed / restart-failed / health-failed / notify-failed / resume-failed`

## 完成判定（done gate）
仅当以下条件全部满足才写 `phase=done`：
1. `healthOk=true`
2. `resumeEventSent=true`
3. `notifyPreSent=true`（若配置了通知）
4. `notifyPostSent=true`（若配置了通知）
5. `resumeStatus=success`

## 补偿与重试
- 支持 reconcile 自动补偿
- 受环境变量控制：
  - `RECONCILE_MAX_RETRIES`（默认 3）
  - `RECONCILE_BACKOFF_SEC`（默认 5，按重试次数线性退避）
- 超过重试上限会标记：
  - `escalationRequired=true`
  - `escalationReason=retry_exceeded`

## 命令白名单
- 默认内置安全白名单（如 `openclaw gateway status` / `openclaw health` / `echo`）
- 可通过 `ACTION_ALLOWLIST_FILE` 指定外部白名单文件（每行一个前缀）
- 示例文件：`skills/restart-safe-workflow/config-action-allowlist.txt`

## 风险与边界
- `--with-restart` 会真实重启，建议低峰期执行。
- 未配置 `--notify-channel/--notify-target` 时不会发送可见通知。
- 白名单外命令会被拒绝执行（进入 `resume-failed`）。

## 依赖
- openclaw CLI
- bash
- python3

## 脚本
- `scripts/restart-safe.sh`
- `scripts/restart-acceptance.sh`
- `config-action-allowlist.txt`
