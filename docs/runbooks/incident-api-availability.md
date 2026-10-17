# Runbook: HealthQueue API availability / latency / booking failures

Linked from every SLO alert in `observability/prometheus/slo-rules.yaml`.
Goal: **restore service first, investigate second.** Rolling back is always allowed and never needs approval.

## 0. Triage (first 5 minutes)

1. **Acknowledge** the page; post in `#inc-healthqueue`: "Investigating <alert name>, I am incident lead."
2. **How bad?** Check the burn rate and the user impact:
   ```promql
   healthqueue:api_error_ratio:rate5m            # share of /v1 requests failing right now
   healthqueue:submission_failure_ratio:rate5m   # share of valid bookings failing
   sum by (route, status) (rate(healthqueue_http_requests_total[5m]))
   ```
   Severity: **SEV1** bookings failing for everyone / API down; **SEV2** > 5% errors or latency SLO fast-burn;
   **SEV3** slow burn (ticket).
3. **What changed?** Most incidents follow a change.
   ```bash
   kubectl -n argocd get application healthqueue-local -o jsonpath='{.status.history[-3:]}'   # recent syncs
   git log --oneline -5 -- deploy/                                                              # recent deploy commits
   kubectl -n healthqueue rollout history deploy/healthqueue-api
   ```

## 1. Mitigate

### A. A deployment in the last 2 hours -> roll back (preferred, ~2 minutes)

```bash
git revert --no-edit <bad-commit-sha>      # the commit that changed deploy/ (image digest or config)
git push                                   # (via PR if branch protection requires; mark as emergency)
kubectl -n argocd annotate application healthqueue-local argocd.argoproj.io/refresh=normal --overwrite
kubectl -n healthqueue rollout status deploy/healthqueue-api --timeout=180s
```

Do **not** `kubectl set image` or `kubectl edit` - Argo CD self-heal will undo it within a minute and the fix is
not recorded in Git. (Break-glass only: pause auto-sync in the Argo CD UI, fix, then put the change into Git.)

### B. Pods not ready / crash-looping

```bash
kubectl -n healthqueue get pods -o wide
kubectl -n healthqueue describe pod <pod>              # events: probe failures, OOMKilled, image pull errors
kubectl -n healthqueue logs <pod> --previous | tail -50  # JSON logs; find request_id / exc_type
```

| Symptom | Likely cause | Action |
|---|---|---|
| `ImagePullBackOff` | digest not in registry / registry down | revert the digest commit; check registry |
| `OOMKilled` | memory limit too low / leak | revert; raise limit via Git if justified |
| Readiness failing, liveness OK | database unreachable | go to C |
| `CreateContainerConfigError` | `healthqueue-db` Secret missing | recreate secret (see kubernetes-gitops runbook) |

### C. Database problems (`/readyz` returns 503, `not_ready`)

```bash
kubectl -n healthqueue get pods -l app.kubernetes.io/name=healthqueue-postgres
kubectl -n healthqueue exec healthqueue-postgres-0 -- pg_isready -U healthqueue -d healthqueue
kubectl -n healthqueue logs healthqueue-postgres-0 | tail -30
```
Production (managed PostgreSQL): check the provider's status/failover events; the API recovers by itself because
the connection pool reconnects and readiness re-admits pods automatically.

### D. Latency (`HealthQueueLatencyFastBurn`) <a id="latency"></a>

```promql
histogram_quantile(0.95, sum by (le, route) (rate(healthqueue_http_request_duration_seconds_bucket[5m])))
```
Check CPU throttling against limits, DB connection saturation, and the last deploy. Lessons from v0.1.0: a missing
connection pool alone pushed ~15% of requests above 300 ms.

### E. Bookings failing but the API is up <a id="bookings-failing"></a>

```promql
sum by (outcome) (rate(healthqueue_appointment_submissions_total[5m]))
```
`error` rising -> server-side failures on insert (DB, locks). A rise in `rejected_validation` alone is **not** an
incident for us (client bug), but tell the client team.

## 2. Communicate

* Every 30 min (SEV1) / 60 min (SEV2) in `#inc-healthqueue` and to clinic support: impact, what we are doing, next
  update time. No patient identifiers in any message.

## 3. Close

* Confirm SLIs are back to normal for 30 minutes; alerts resolved.
* Record the error budget consumed (workbook / dashboard) and apply the
  [error budget policy](../observability-plan.md#3-error-budget-policy).
* Open a **blameless postmortem** within 5 working days:
  [example INC-201](../postmortems/2026-09-12-inc-201-postgres-failover.md).

## Useful references

* Logs for one request: filter JSON logs by `request_id` (returned to clients in `X-Request-ID`), then use its
  `trace_id` to open the trace.
* Architecture: [../architecture.md](../architecture.md) · GitOps operations: [kubernetes-gitops.md](kubernetes-gitops.md)
