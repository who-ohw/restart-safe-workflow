# restart-safe-workflow

Safe OpenClaw gateway restart workflow（Sprint 1-4 已落地版）：
- 重启安全事务（doctor → checkpoint → restart → health → resume）
- detached runner 断链解耦
- 前后可见回执（可选）
- 任务续跑（pendingActions）
- reconcile 补偿 + 重试/升级
- report / diagnose 可观测能力

## 当前实现范围（真实已实现）

### Sprint 1
- 状态机基础与状态落盘
- doctor 阻断、checkpoint 落盘、resume 补发

### Sprint 2
- detached runner 解耦会话与重启链路
- 解决“重启导致后半流程失联”

### Sprint 3
- 通知契约修复（CLI 参数契约）
- done gate 强约束：通知/健康/resume 不满足不允许 done

### Sprint 3.5
- 任务级续跑：`pendingActions` / `resumeCompletedActions` / `resumeCursor`
- 重启前任务清单、重启后待处理清单、重启后执行结果清单

### Sprint 4
- 回归验收脚本扩展（TC1~TC10）
- `report` / `diagnose` 子命令
- reconcile 重试与升级（`RECONCILE_MAX_RETRIES`、`RECONCILE_BACKOFF_SEC`）
- 白名单外置文件：`config-action-allowlist.txt`
- SKILL/SOP 文档同步更新

---

## 目录

```text
skills/restart-safe-workflow/
├── SKILL.md
├── README.md
├── config-action-allowlist.txt
├── scripts/
│   ├── restart-safe.sh
│   └── restart-acceptance.sh
└── references/
    └── restart-safe-sop.md
```

---

## 常用命令

### 1) 执行重启任务（默认 detached）

```bash
skills/restart-safe-workflow/scripts/restart-safe.sh run \
  --task-id task-$(date +%Y%m%d-%H%M%S) \
  --next "notify:重启后继续任务" \
  --criteria "重启成功且续跑完成"
```

### 2) 带可见回执

```bash
skills/restart-safe-workflow/scripts/restart-safe.sh run \
  --task-id task-$(date +%Y%m%d-%H%M%S) \
  --next "cmd:echo post-restart" \
  --criteria "前后回执+续跑成功" \
  --notify-channel feishu \
  --notify-target user:<open_id> \
  --notify-account master
```

### 3) 仅续跑动作（不重启）

```bash
skills/restart-safe-workflow/scripts/restart-safe.sh resume-run --task-id <task-id>
```

### 4) 补偿

```bash
# 单任务
skills/restart-safe-workflow/scripts/restart-safe.sh reconcile --task-id <task-id>

# 批量
skills/restart-safe-workflow/scripts/restart-safe.sh reconcile
```

### 5) 摘要与诊断

```bash
skills/restart-safe-workflow/scripts/restart-safe.sh report --task-id <task-id>
skills/restart-safe-workflow/scripts/restart-safe.sh diagnose --task-id <task-id>
```

### 6) 一键验收

```bash
# 默认不真实重启
skills/restart-safe-workflow/scripts/restart-acceptance.sh

# 真实重启链路
skills/restart-safe-workflow/scripts/restart-acceptance.sh --with-restart \
  --notify-channel feishu --notify-target user:<open_id> --notify-account master
```

---

## `--next` 支持

- `notify:<text>`
- `cmd:<command>`
- `script:<path>`
- `json:[{...}]`

---

## 关键状态字段

- `phase`
- `healthOk`
- `resumeEventSent`
- `notifyPreSent / notifyPostSent`
- `resumeStatus`（idle/running/success/failed）
- `pendingActions / resumeCompletedActions`
- `resumeCursor`
- `escalationRequired / escalationReason`

---

## 环境变量

- `STATE_DIR`（默认 `./state/restart`）
- `GATEWAY_RESTART_CMD`（默认 `openclaw gateway restart`）
- `HEALTH_TIMEOUT_SEC`（默认 `30`）
- `RECONCILE_MAX_RETRIES`（默认 `3`）
- `RECONCILE_BACKOFF_SEC`（默认 `5`）
- `ACTION_ALLOWLIST_FILE`（命令白名单文件）

---

## 判定标准（done gate）

仅当以下条件满足才写 `phase=done`：
1. `healthOk=true`
2. `resumeEventSent=true`
3. `notifyPreSent=true`（启用通知时）
4. `notifyPostSent=true`（启用通知时）
5. `resumeStatus=success`
