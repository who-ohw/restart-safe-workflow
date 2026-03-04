# restart-safe-workflow

Safe restart workflow for OpenClaw gateway: **doctor 预检 → checkpoint 落盘 → restart → health → resume → 可见回执 → 任务续跑**。

## 适用场景
- 需要执行 `openclaw gateway restart`
- 配置变更后安全重启并自动续跑
- 希望重启前后有用户可见通知
- 需要失败补偿、诊断与升级标记

## 核心能力
- `run / continue / resume-run / reconcile`
- TaskPlan：`plan / validate`（v1）
- 语义动作：`notify-time[:TZ]`
- Action 状态机：deps/retry/idempotency/onFailure
- 可观测：`report --verbose` / `diagnose`
- 验收：`restart-acceptance.sh`（支持 `--with-restart`）

## 快速开始

```bash
# 1) 常规安全重启
skills/restart-safe-workflow/scripts/restart-safe.sh run \
  --task-id task-$(date +%Y%m%d-%H%M%S) \
  --next "notify:重启完成;notify-time" \
  --notify-channel feishu \
  --notify-target user:<open_id> \
  --notify-account master

# 2) 计划预览 + 校验
skills/restart-safe-workflow/scripts/restart-safe.sh plan --task-id demo --next "notify:ok;notify-time"
skills/restart-safe-workflow/scripts/restart-safe.sh validate --tasks-file skills/restart-safe-workflow/examples/plan-valid.json

# 3) 一键验收（默认不真实重启）
skills/restart-safe-workflow/scripts/restart-acceptance.sh

# 4) 真实重启验收（默认自守护 detached）
skills/restart-safe-workflow/scripts/restart-acceptance.sh --with-restart \
  --notify-channel feishu --notify-target user:<open_id> --notify-account master
```

## 目录（建议发布保留）
```text
SKILL.md
README.md
config-action-allowlist.txt
schemas/taskspec-v1.schema.json
examples/{plan-valid.json,plan-invalid.json}
scripts/{restart-safe.sh,restart-acceptance.sh}
references/{restart-safe-sop.md,phase0-requirements-v1.md,phase4-rollout-checklist.md}
```

## Changelog（最近两次迭代）

### v1.0.2 (2026-03-04)
- Phase 3/4 完成：`report --verbose`、action 级 `diagnose`
- acceptance 覆盖升级：新增 plan/validate/report-verbose 断言
- 修复 TC10：`reconcile` 在 no-restart 失败链路可触发 `retry_exceeded`
- 真实重启验收默认自守护 detached，避免会话重启中断报告

### v1.0.1 (2026-03-04)
- Phase 1/2 完成：TaskPlan v1、`notify-time`、deps/retry/idempotency/onFailure
- `run --tasks-file` 支持任务文件入队

> 详细变更可见 `CHANGELOG.md`。
