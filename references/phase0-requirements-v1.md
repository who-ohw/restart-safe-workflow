# Restart Safe Workflow — Phase 0 需求冻结说明（v1）

## 1. 目标
将 restart-safe-workflow 从“字符串 nextAction 续跑”升级为“语义化任务计划（TaskSpec）+ 可恢复执行”。

## 2. 本阶段冻结内容（In Scope）
1. TaskSpec v1 数据标准（JSON）
2. `plan` 子命令：将 `--next` 编译为任务计划
3. `validate` 子命令：校验任务计划格式与动作类型
4. `notify-time` 语义快捷动作
5. 与现有 `run --next` 完整兼容

## 3. 暂不纳入（Out of Scope）
1. 开放式自然语言理解与任意动作自动执行
2. 跨节点分布式调度
3. 未白名单命令执行

## 4. 验收标准
1. 输入 `--next "notify-time"` 可生成两个动作：`query_time` + `notify`
2. `plan` 输出包含 `taskPlanVersion=v1`、`taskId`、`actions[]`
3. `validate --tasks-file` 对合法计划返回通过，对非法类型返回失败
4. 旧 `notify:/cmd:/script:/json:` 表达式保持可运行

## 5. 风险与控制
- 风险：用户输入表达式复杂，解析歧义
- 控制：Phase 1 仅支持受控语法（前缀 + `;` 串联）

## 6. 交付物
- `schemas/taskspec-v1.schema.json`
- `scripts/restart-safe.sh` 增强（plan/validate + notify-time）
- README/SKILL 文档更新
