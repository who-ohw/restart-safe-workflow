# restart-safe-workflow

Safe OpenClaw gateway restart workflow with doctor precheck, checkpoint persistence, health verification, resume trigger, and optional user-visible notifications.

## What this project does

This skill packages a **recoverable restart SOP** for OpenClaw so restart tasks are reliable, auditable, and user-visible when needed.

Core flow:
1. `openclaw doctor --non-interactive`
2. persist checkpoint (`taskId / phase / nextAction / successCriteria`)
3. restart gateway
4. verify with `openclaw gateway status` + `openclaw health`
5. trigger resume event (`resume:<taskId>`)
6. optionally send user-visible notifications

## Structure

```text
restart-safe-workflow/
├── SKILL.md
├── scripts/
│   ├── restart-safe.sh
│   └── restart-acceptance.sh
└── references/
    └── restart-safe-sop.md
```

## Quick start

### Safe restart (recommended)

```bash
skills/restart-safe-workflow/scripts/restart-safe.sh run \
  --task-id task-$(date +%Y%m%d-%H%M%S) \
  --next "continue task after restart" \
  --criteria "resume event triggered and health checks pass"
```

### Acceptance test (no real restart by default)

```bash
skills/restart-safe-workflow/scripts/restart-acceptance.sh
```

### Acceptance test with real restart (high impact)

```bash
skills/restart-safe-workflow/scripts/restart-acceptance.sh --with-restart
```

## Outputs

- State file: `state/restart/<task-id>.json`
- Acceptance report: `state/restart/acceptance-<task-prefix>.log`

## Notes

- `--with-restart` performs a real gateway restart. Run in low-traffic windows.
- This repository focuses on operational safety, recoverability, and verification.
