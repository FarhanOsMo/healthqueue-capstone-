# ADR-0005: Prometheus metrics + OpenTelemetry traces + JSON logs; SLOs with multi-window burn-rate alerts

* Status: Accepted (2026-10-17)

## Context

The CTO needs one honest answer to "can patients book?" and a rule for when to slow releases. Alert fatigue must
be avoided with a one-person on-call rotation.

## Decision

* **Three SLIs** measured in the service itself: request availability (non-5xx), latency (< 300 ms), successful
  valid submissions (201/409). Proposed SLOs 99.9% / 99% / 99.5% over a 30-day rolling window. Plus a time-based
  availability view (43.2 allowed minutes) from synthetic probes.
* **prometheus_client** counters/histograms labelled by **route template**; a histogram bucket exactly at 0.3 s so the
  latency SLI is exact.
* **OpenTelemetry SDK** with FastAPI instrumentation; export via OTLP only when configured (vendor-neutral, $0 by
  default). `trace_id` injected into every JSON log line.
* **Alerting on SLO burn rate** (SRE Workbook multi-window, multi-burn-rate) instead of raw thresholds; rules are unit
  tested with `promtool`.
* **Error budget policy** with four states (HEALTHY / CAUTION / FREEZE / EXHAUSTED) agreed with product.

## Alternatives considered

* *Threshold alerts* ("error rate > 1% for 5 min") - page on harmless blips and miss slow leaks.
* *Latency SLO on p99* - percentiles cannot be aggregated across pods or time windows correctly; a ratio of
  "fast requests" can.
* *Hosted APM (Datadog, New Relic)* - excellent but paid; OpenTelemetry keeps that option open later.
* *99.99% target* - 4.3 min/month is not realistic for a single-region startup team.

## Consequences

* + Alerts map directly to user pain and to a budget; the policy turns reliability into a release decision.
* + The SLI pipeline already found a real latency problem in a local load test (fixed in v0.1.1).
* − SLO targets are guesses until 3 months of production data exist; review scheduled.
* − Monitoring stack (Prometheus/Alertmanager/Grafana) is demonstrated with Compose, not deployed in the cluster.
