# restart-safe-workflow

> Safe OpenClaw gateway restart workflow with doctor precheck, checkpoint persistence, health verification, resume trigger, and optional user-visible notifications.

## 快速结论

- **推荐安装方式**：ClawHub（最干净、最稳）
- **GitHub 也可安装**，但如果直接 `git clone`，会带上 `.git`、`README.md` 等额外文件。
- 这些额外文件通常**不会阻止 Skill 运行**，但从“技能目录纯净度”角度，建议使用「只拷贝技能必需文件」的方式安装。

---

## 安装方式 A（推荐）：ClawHub 一键安装

> 适合“给 OpenClaw 一个技能名就能装”的场景。

```bash
clawhub install restart-safe-workflow
```

可选：指定版本

```bash
clawhub install restart-safe-workflow --version <version>
```

安装后通常会落到：`./skills/restart-safe-workflow/`

---

## 安装方式 B：GitHub 安装（无 ClawHub 时）

仓库地址：

- https://github.com/who-ohw/restart-safe-workflow

### B1. 直接 clone（最快，但会有额外文件）

```bash
cd /path/to/your-openclaw-workspace/skills
git clone https://github.com/who-ohw/restart-safe-workflow.git
```

这会保留：`.git/`、`README.md` 等。

### B2. 推荐的“纯净安装”（仅保留技能必需文件）

```bash
cd /path/to/your-openclaw-workspace/skills
mkdir -p restart-safe-workflow
cd restart-safe-workflow

# 只下载归档，不保留 .git 元数据
curl -L https://github.com/who-ohw/restart-safe-workflow/archive/refs/heads/main.tar.gz -o /tmp/restart-safe-workflow.tar.gz

# 解压并仅复制技能核心文件
mkdir -p /tmp/restart-safe-workflow-src
tar -xzf /tmp/restart-safe-workflow.tar.gz -C /tmp/restart-safe-workflow-src
cp -r /tmp/restart-safe-workflow-src/restart-safe-workflow-main/SKILL.md ./
cp -r /tmp/restart-safe-workflow-src/restart-safe-workflow-main/scripts ./
cp -r /tmp/restart-safe-workflow-src/restart-safe-workflow-main/references ./
```

---

## GitHub 安装是否会遗留 README.md / .git？会不会干扰？

### 会不会遗留？
会。若使用 `git clone`，一定会有：

- `.git/`
- `README.md`（以及仓库内其它文件）

### 会不会干扰 Skill？
- **通常不会阻塞运行**：Skill 的核心是 `SKILL.md` + 其引用资源。
- 但从规范与维护角度，建议技能目录尽量保持简洁，避免无关文件增加检索噪声。

### 最佳实践
- 对外分发优先用 **ClawHub install**。
- GitHub 分发时优先使用上面的 **B2 纯净安装**。

---

## 目录结构（技能核心）

```text
restart-safe-workflow/
├── SKILL.md
├── scripts/
│   ├── restart-safe.sh
│   └── restart-acceptance.sh
└── references/
    └── restart-safe-sop.md
```

---

## 使用示例

### 安全执行一次重启（推荐）

```bash
skills/restart-safe-workflow/scripts/restart-safe.sh run \
  --task-id task-$(date +%Y%m%d-%H%M%S) \
  --next "continue task after restart" \
  --criteria "resume event triggered and health checks pass"
```

### 一键验收（默认不真实重启）

```bash
skills/restart-safe-workflow/scripts/restart-acceptance.sh
```

### 真实重启链路验收（高影响）

```bash
skills/restart-safe-workflow/scripts/restart-acceptance.sh --with-restart
```

---

## 输出产物

- State file: `state/restart/<task-id>.json`
- Acceptance report: `state/restart/acceptance-<task-prefix>.log`

---

## 风险提示

- `--with-restart` 会执行真实 gateway 重启，请在低峰期执行。
- 生产环境建议搭配用户可见回执参数（notify channel/target）使用。
