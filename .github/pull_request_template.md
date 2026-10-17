## What changed and why

## Risk and rollback
- [ ] Rollback plan: `git revert` this PR (Argo CD re-syncs the previous state)
- [ ] Error budget checked (no risky releases while the budget is exhausted - see docs/observability-plan.md)

## Checklist
- [ ] CI is green (tests, Trivy gate, IaC scan, manifest validation)
- [ ] No secrets, state files or patient data added
- [ ] Docs/ADRs updated if a design decision changed
