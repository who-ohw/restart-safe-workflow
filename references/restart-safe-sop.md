# OpenClaw 重启安全流程（SOP）

适用场景：任务中涉及 `openclaw gateway restart` / 配置变更后重启 / node 重启。

## 目标
- 重启前发现配置风险，避免“重启失败后人工排障”。
- 重启后自动恢复任务，避免“任务丢失、长时间无回应”。

## 一、推荐脚本
- 路径：`scripts/restart-safe.sh`
- 功能：预检 → 落盘 → 重启 → 健康检查 → 恢复触发

### 1) 执行完整流程
```bash
scripts/restart-safe.sh run \
  --task-id task-20260303-001 \
  --next "重启后继续执行步骤3：连接校验并输出结果" \
  --criteria "收到连接正常并提交报告"
```

### 2) 仅预检+落盘（不重启）
```bash
scripts/restart-safe.sh run --task-id task-20260303-001 --no-restart
```

### 3) 手工补发恢复事件
```bash
scripts/restart-safe.sh resume --task-id task-20260303-001
```

### 4) 查看任务恢复状态
```bash
scripts/restart-safe.sh status --task-id task-20260303-001
```

## 二、状态文件
- 默认目录：`state/restart/`
- 文件名：`<taskId>.json`
- 关键字段：
  - `phase`：`before-restart` / `restart-failed` / `resume-triggered`
  - `nextAction`：重启后下一步
  - `successCriteria`：验收标准

## 三、失败处理
1. `doctor` 失败：
   - 禁止重启，先修复配置问题。
2. 重启后健康检查失败：
   - 先执行 `openclaw logs` + `openclaw gateway status` 定位。
3. 重启后未自动续跑：
   - 手工执行 `scripts/restart-safe.sh resume --task-id <id>`。

## 四、可选参数（环境变量）
- `STATE_DIR`：状态目录（默认 `./state/restart`）
- `GATEWAY_RESTART_CMD`：重启命令（默认 `openclaw gateway restart`）
- `HEALTH_TIMEOUT_SEC`：健康检查超时秒数（默认 `30`）

## 五、团队执行纪律（建议）
- No doctor, no restart.
- No checkpoint, no restart.
