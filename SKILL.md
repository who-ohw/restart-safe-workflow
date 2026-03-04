---
name: restart-safe-workflow
description: Safe OpenClaw gateway restart workflow with doctor precheck, checkpoint persistence, health verification, resume trigger, and optional user-visible notifications. Use when tasks involve gateway restart, recovery assurance, or restart acceptance testing.
---

# Restart Safe Workflow

用于 OpenClaw 的“可恢复重启”流程，避免重启导致任务丢失、无回复、不可验证。

## 适用场景
- 需要执行 `openclaw gateway restart` 的任务
- 配置变更后需要安全重启并可追踪恢复
- 需要向用户发送重启前后可见回执
- 需要一键验收重启流程可靠性

## SOP 参考（已融合）
- 核心SOP已纳入本Skill，文件：`references/restart-safe-sop.md`
- 当你需要完整的流程规范、失败处理、团队执行纪律时，优先阅读该文件。

## 快速开始

### 1) 安全执行一次重启（推荐）
```bash
skills/restart-safe-workflow/scripts/restart-safe.sh run \
  --task-id task-$(date +%Y%m%d-%H%M%S) \
  --next "重启后继续任务" \
  --criteria "用户收到回执且任务续跑"
```

### 2) 带用户可见回执（Feishu示例）
```bash
skills/restart-safe-workflow/scripts/restart-safe.sh run \
  --task-id task-$(date +%Y%m%d-%H%M%S) \
  --next "继续执行后续步骤" \
  --criteria "回执可见+resume触发" \
  --notify-channel feishu \
  --notify-target user:<open_id> \
  --notify-account master
```

### 3) 一键验收（默认不真实重启）
```bash
skills/restart-safe-workflow/scripts/restart-acceptance.sh
```

### 4) 真实重启链路验收（高影响）
```bash
skills/restart-safe-workflow/scripts/restart-acceptance.sh --with-restart
```

### 5) 验证“用户可见回执”
```bash
skills/restart-safe-workflow/scripts/restart-acceptance.sh \
  --with-restart \
  --notify-channel feishu \
  --notify-target user:<open_id> \
  --notify-account master
```

## 文件产物
- 状态文件：`state/restart/<task-id>.json`
- 验收报告：`state/restart/acceptance-<task-prefix>.log`

关键状态：
- `before-restart`
- `resume-triggered`
- `restart-failed`

关键标记（`note` 字段）：
- `notice-visible`：重启前可见通知已发送
- `result-visible`：重启后可见回执已发送
- `result-event`：系统事件回执已发送

## 执行流程（run）
1. `openclaw doctor --non-interactive`
2. 落盘 checkpoint（state json）
3. 执行 gateway 重启
4. `openclaw gateway status` + `openclaw health` 验活
5. 触发 `openclaw system event --mode now --text "resume:<taskId>"`
6. （可选）发送用户可见回执

## 风险与边界
- `--with-restart` 会真实重启，建议低峰期执行。
- 若不传 `--notify-channel/--notify-target`，不会发送用户可见通知。
- system event 用于系统恢复，不等于聊天窗口可见消息。

## 依赖
- openclaw CLI
- bash
- python3

## 脚本
- `scripts/restart-safe.sh`
- `scripts/restart-acceptance.sh`
