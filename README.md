# restart-safe-workflow

Safe restart workflow for OpenClaw gateway: **doctor 预检 → checkpoint 落盘 → restart → health → resume → 可见回执 → 任务续跑**。

## 安装与集成（重要）

> 你提到的场景是“只提交当前仓库 README 给 OpenClaw 即可自动安装”。
> 因此这里保留两种标准安装方式：**ClawHub 安装** 与 **GitHub 安装**。

### 方式 A：ClawHub 安装（推荐）

```bash
clawhub install restart-safe-workflow
```

可选：指定版本

```bash
clawhub install restart-safe-workflow --version 1.0.2
```

### 方式 B：GitHub 安装（无 ClawHub 时）

仓库：`https://github.com/who-ohw/restart-safe-workflow`

#### B1. 直接 clone（最快）

```bash
cd /path/to/your-openclaw-workspace/skills
git clone https://github.com/who-ohw/restart-safe-workflow.git
```

#### B2. 纯净安装（推荐分发）

```bash
cd /path/to/your-openclaw-workspace/skills
mkdir -p restart-safe-workflow
cd restart-safe-workflow

curl -L https://github.com/who-ohw/restart-safe-workflow/archive/refs/heads/main.tar.gz -o /tmp/restart-safe-workflow.tar.gz
mkdir -p /tmp/restart-safe-workflow-src
tar -xzf /tmp/restart-safe-workflow.tar.gz -C /tmp/restart-safe-workflow-src
cp -r /tmp/restart-safe-workflow-src/restart-safe-workflow-main/SKILL.md ./
cp -r /tmp/restart-safe-workflow-src/restart-safe-workflow-main/scripts ./
cp -r /tmp/restart-safe-workflow-src/restart-safe-workflow-main/references ./
cp -r /tmp/restart-safe-workflow-src/restart-safe-workflow-main/schemas ./
cp -r /tmp/restart-safe-workflow-src/restart-safe-workflow-main/examples ./
cp -r /tmp/restart-safe-workflow-src/restart-safe-workflow-main/config-action-allowlist.txt ./
```

---

## 能力概览
- 安全重启主链：`doctor -> checkpoint -> restart -> health -> resume`
- 任务续跑：`pendingActions` + Action 状态机
- 语义动作：`notify-time[:TZ]`
- 计划能力：`plan / validate`（TaskPlan v1）
- 补偿与升级：`reconcile` + `retry_exceeded`
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

## 通知策略（v1.0.2+）

- 默认：`NOTIFY_MODE=compact`（仅 2 条）
  1) `【重启通知】`
  2) `【重启成功后通知】`（合并队列统计 + 任务清单 + 清理结果：已清理/保留/告警）
- 调试：`NOTIFY_MODE=verbose`（保留过程型多条通知）

示例：

```bash
NOTIFY_MODE=compact skills/restart-safe-workflow/scripts/restart-safe.sh run ...
NOTIFY_MODE=verbose skills/restart-safe-workflow/scripts/restart-safe.sh run ...
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
- 通知策略升级：默认 `NOTIFY_MODE=compact`（2条制）
- Phase C 完成：后置通知新增“任务清理：已清理/保留/告警”细化

### v1.0.1 (2026-03-04)
- Phase 1/2 完成：TaskPlan v1、`notify-time`、deps/retry/idempotency/onFailure
- `run --tasks-file` 支持任务文件入队

> 详细变更见 `CHANGELOG.md`。
