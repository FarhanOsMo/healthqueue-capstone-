"""Run a small LOCAL load test against the API and compute the three SLIs.

This produces *observed* numbers from the real running code, but it is a short
synthetic load on a laptop - NOT production traffic and NOT a 30-day window.
The SLO workbook labels it accordingly.

SLIs are computed twice, independently:
  * client side - from the HTTP status codes and timings this script observed
  * server side - from the API's own Prometheus counters (the same series the
                  production alert rules use), scraped from every pod

Usage:
  python scripts/measure_slis.py          # kind NodePort; scrape every pod via kubectl
  python scripts/measure_slis.py --base-url http://127.0.0.1:8080 --metrics-url http://127.0.0.1:8080/metrics
"""

from __future__ import annotations

import argparse
import json
import os
import random
import subprocess
import threading
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from pathlib import Path

import httpx
from prometheus_client.parser import text_string_to_metric_families

LATENCY_THRESHOLD_S = 0.3
ROOT = Path(__file__).resolve().parents[1]


def scrape_pods(namespace: str) -> list[str]:
    env = {**os.environ, "KUBECONFIG": str(ROOT / ".kube" / "healthqueue.kubeconfig")}
    pods = subprocess.run(
        [
            "kubectl",
            "-n",
            namespace,
            "get",
            "pods",
            "-l",
            "app.kubernetes.io/name=healthqueue-api",
            "-o",
            "jsonpath={.items[*].metadata.name}",
        ],
        check=True,
        capture_output=True,
        text=True,
        env=env,
    ).stdout.split()
    code = "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8080/metrics').read().decode())"
    return [
        subprocess.run(
            ["kubectl", "-n", namespace, "exec", pod, "--", "python", "-c", code],
            check=True,
            capture_output=True,
            text=True,
            env=env,
        ).stdout
        for pod in pods
    ]


def server_side_counts(texts: list[str]) -> dict[str, float]:
    totals: Counter[str] = Counter()
    for text in texts:
        for fam in text_string_to_metric_families(text):
            for s in fam.samples:
                route = s.labels.get("route", "")
                if s.name == "healthqueue_http_requests_total" and route.startswith("/v1/"):
                    totals["eligible"] += s.value
                    if s.labels["status"].startswith("5"):
                        totals["5xx"] += s.value
                elif (
                    s.name == "healthqueue_http_request_duration_seconds_bucket"
                    and route.startswith("/v1/")
                ):
                    if s.labels["le"] == str(LATENCY_THRESHOLD_S):
                        totals["fast"] += s.value
                elif (
                    s.name == "healthqueue_http_request_duration_seconds_count"
                    and route.startswith("/v1/")
                ):
                    totals["timed"] += s.value
                elif s.name == "healthqueue_appointment_submissions_total":
                    totals["sub_" + s.labels["outcome"]] += s.value
    return dict(totals)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default="http://127.0.0.1:30080")
    ap.add_argument(
        "--metrics-url", action="append", help="scrape these URLs instead of kubectl exec"
    )
    ap.add_argument("--namespace", default="healthqueue")
    ap.add_argument("--requests", type=int, default=3000)
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--out", type=Path, default=ROOT / "reports" / "slo" / "local-load-test.json")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    run_tag = datetime.now(UTC).strftime("%H%M%S")
    lock = threading.Lock()
    created_ids: list[str] = []
    booked_slots: list[dict] = []
    results: list[tuple[str, int, float]] = []  # (kind, status, seconds)

    def slot_payload(i: int) -> dict:
        start = (datetime.now(UTC) + timedelta(days=1 + i % 150)).replace(
            hour=8 + (i // 150) % 10, minute=0, second=0, microsecond=0
        )
        return {
            "patient_ref": f"PT-{rng.randint(0, 999999):06d}",
            "clinic_id": f"CLN-{1 + i % 5:03d}",
            "provider_id": f"PRV-{(int(run_tag) + i) % 9000 + 1000:04d}",
            "appointment_type": rng.choice(["checkup", "follow_up", "vaccination", "consultation"]),
            "start_time": start.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "duration_minutes": rng.choice([15, 30, 45, 60]),
        }

    plan = rng.choices(
        ["get", "create", "conflict", "invalid", "missing"],
        weights=[55, 25, 5, 10, 5],
        k=args.requests,
    )

    with httpx.Client(base_url=args.base_url, timeout=10) as client:

        def one(i: int, kind: str) -> None:
            if kind == "get" and not created_ids:
                kind = "create"
            t0 = time.perf_counter()
            if kind == "create":
                payload = slot_payload(i)
                r = client.post("/v1/appointments", json=payload)
                if r.status_code == 201:
                    with lock:
                        created_ids.append(r.json()["id"])
                        booked_slots.append(payload)
            elif kind == "conflict" and booked_slots:
                r = client.post("/v1/appointments", json=rng.choice(booked_slots))
            elif kind == "invalid":
                r = client.post(
                    "/v1/appointments", json={"patient_ref": "not-valid", "clinic_id": "x"}
                )
            elif kind == "missing":
                r = client.get("/v1/appointments/00000000-0000-4000-8000-000000000000")
            else:
                r = client.get(f"/v1/appointments/{rng.choice(created_ids)}")
            elapsed = time.perf_counter() - t0
            with lock:
                results.append((kind, r.status_code, elapsed))

        # Warm up with a few creates so GETs have something to read.
        for i in range(10):
            one(i, "create")
        before = (
            scrape_pods(args.namespace)
            if not args.metrics_url
            else [httpx.get(u, timeout=10).text for u in args.metrics_url]
        )
        started = time.time()
        with ThreadPoolExecutor(args.workers) as pool:
            for i, kind in enumerate(plan, start=10):
                pool.submit(one, i, kind)
        duration = time.time() - started
        after = (
            scrape_pods(args.namespace)
            if not args.metrics_url
            else [httpx.get(u, timeout=10).text for u in args.metrics_url]
        )

    measured = results[10:]
    statuses = Counter(s for _, s, _ in measured)
    client_side = {
        "requests": len(measured),
        "status_counts": dict(sorted((str(k), v) for k, v in statuses.items())),
        "availability_good": sum(1 for _, s, _ in measured if s < 500),
        "latency_fast": sum(1 for _, _, t in measured if t < LATENCY_THRESHOLD_S),
        "submissions_good": sum(
            1 for k, s, _ in measured if k in {"create", "conflict"} and s in (201, 409)
        ),
        "submissions_eligible": sum(
            1 for k, s, _ in measured if k in {"create", "conflict"} and s != 422
        ),
        "p50_ms": round(sorted(t for *_, t in measured)[len(measured) // 2] * 1000, 1),
        "p95_ms": round(sorted(t for *_, t in measured)[int(len(measured) * 0.95)] * 1000, 1),
        "p99_ms": round(sorted(t for *_, t in measured)[int(len(measured) * 0.99)] * 1000, 1),
    }
    b, a = server_side_counts(before), server_side_counts(after)
    d = {k: a.get(k, 0) - b.get(k, 0) for k in set(a) | set(b)}
    server_side = {
        "eligible_requests": d.get("eligible", 0),
        "errors_5xx": d.get("5xx", 0),
        "fast_requests_le_0_3s": d.get("fast", 0),
        "timed_requests": d.get("timed", 0),
        "submissions_created": d.get("sub_created", 0),
        "submissions_conflict": d.get("sub_conflict", 0),
        "submissions_error": d.get("sub_error", 0),
        "submissions_rejected_validation": d.get("sub_rejected_validation", 0),
    }

    def ratio(n: float, m: float) -> float | None:
        return round(n / m, 6) if m else None

    report = {
        "label": (
            "OBSERVED - local load test on a laptop kind cluster "
            "(not production, not a 30-day window)"
        ),
        "generated_utc": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "target": args.base_url,
        "duration_seconds": round(duration, 1),
        "workers": args.workers,
        "seed": args.seed,
        "client_side": client_side,
        "server_side_prometheus_delta": server_side,
        "sli": {
            "availability_client": ratio(client_side["availability_good"], client_side["requests"]),
            "availability_server": ratio(
                server_side["eligible_requests"] - server_side["errors_5xx"],
                server_side["eligible_requests"],
            ),
            "latency_client_lt_300ms": ratio(client_side["latency_fast"], client_side["requests"]),
            "latency_server_le_300ms": ratio(
                server_side["fast_requests_le_0_3s"], server_side["timed_requests"]
            ),
            "submissions_client": ratio(
                client_side["submissions_good"], client_side["submissions_eligible"]
            ),
            "submissions_server": ratio(
                server_side["submissions_created"] + server_side["submissions_conflict"],
                server_side["submissions_created"]
                + server_side["submissions_conflict"]
                + server_side["submissions_error"],
            ),
        },
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
