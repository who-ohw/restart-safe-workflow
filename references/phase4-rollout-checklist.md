# Phase 4 灰度上线清单（restart-safe-workflow）

## 1) 上线前准备
- [ ] 确认代码版本包含：Phase1~Phase3（plan/validate, deps/retry/idempotency, report/diagnose增强）
- [ ] 执行语法检查：`bash -n scripts/restart-safe.sh && bash -n scripts/restart-acceptance.sh`
- [ ] 执行无重启验收：`scripts/restart-acceptance.sh`
- [ ] 准备通知参数（可选）：`--notify-channel feishu --notify-target user:<open_id> --notify-account master`

## 2) 灰度分批策略
### Wave 1（低风险）
- 范围：`--no-restart` 场景 + `resume-run` 场景
- 验收：`resumeStatus=success`，`report --verbose` 正常

### Wave 2（中风险）
- 范围：单次真实重启（1~2次）
- 命令：`scripts/restart-acceptance.sh --with-restart [notify args]`
- 验收：`phase=done`，`healthOk=true`，`resumeEventSent=true`

### Wave 3（全量）
- 范围：正式任务启用
- 要求：每次任务保留 `taskId` 与 `state/restart/<taskId>.json`

## 3) 观测指标（上线后）
- 完成率：`phase=done` 占比
- 续跑成功率：`resumeStatus=success` 占比
- 重试健康度：action 失败重试次数分布
- 升级告警率：`escalationRequired=true` 占比

## 4) 回滚条件
任一触发即回滚：
- 连续 2 次真实重启未达 `done`
- 同类 action 大面积 `failed`
- 通知链路异常导致关键回执缺失

## 5) 回滚步骤
1. 停止批量执行，仅保留 `--no-restart` 验证
2. 使用 `scripts/restart-safe.sh report/diagnose` 定位失败点
3. 必要时退回上一稳定 commit
4. 重新跑 `scripts/restart-acceptance.sh` 后再恢复灰度
