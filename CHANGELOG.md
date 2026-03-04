# Changelog

## v1.0.2 - 2026-03-04
### Added
- Action-level observability: `report --verbose` with `actionDetails` + `actionStats`
- Enhanced `diagnose` with action-level blockage hints
- Acceptance coverage for Phase 1~3 assertions (plan/validate/report-verbose)
- Detached self-guard mode for `restart-acceptance.sh --with-restart`
- Rollout checklist: `references/phase4-rollout-checklist.md`

### Fixed
- TC10 reconcile escalation path for no-restart resume failures (`retry_exceeded`)
- Acceptance real-restart reporting continuity improvement

## v1.0.1 - 2026-03-04
### Added
- TaskPlan v1 support: `plan`, `validate`, `schemas/taskspec-v1.schema.json`
- Semantic action `notify-time[:TZ]`
- Action state machine: deps, retry, idempotency, `onFailure`
- `run --tasks-file` support
