"""Tests for the synthetic data generators, the SLO arithmetic and the workbooks."""

from __future__ import annotations

import csv
import sys
from datetime import date, datetime, timedelta
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import generate_dora_data as dora  # noqa: E402
import generate_slo_data as slo  # noqa: E402


def test_dora_generation_is_reproducible():
    assert dora.generate() == dora.generate()
    assert dora.generate(seed=1) != dora.generate()


def test_dora_dataset_covers_exactly_90_days():
    rows = dora.generate()
    days = {date.fromisoformat(r["deploy_date"]) for r in rows}
    assert min(days) >= dora.PERIOD_START
    assert max(days) <= dora.PERIOD_START + timedelta(days=89)
    assert dora.PERIOD_DAYS == 90


def test_dora_rows_are_internally_consistent():
    for r in dora.generate():
        deployed = datetime.strptime(r["deployed_at_utc"], "%Y-%m-%dT%H:%M:%SZ")
        first = datetime.strptime(r["first_commit_at_utc"], "%Y-%m-%dT%H:%M:%SZ")
        assert abs((deployed - first).total_seconds() / 3600 - r["lead_time_hours"]) < 0.01
        if r["change_failed"] == "TRUE":
            restored = datetime.strptime(r["restored_at_utc"], "%Y-%m-%dT%H:%M:%SZ")
            assert (restored - deployed).total_seconds() / 60 == r["recovery_minutes"]
            assert r["incident_id"].startswith("INC-")
        else:
            assert r["recovery_minutes"] == "" and r["incident_id"] == ""


def test_committed_dora_csv_matches_generator(tmp_path):
    out = tmp_path / "d.csv"
    dora.write_csv(dora.generate(), out)
    assert out.read_bytes() == (ROOT / "data" / "dora_deployments.csv").read_bytes()


def test_slo_generation_is_reproducible_and_30_days():
    rows = slo.generate()
    assert rows == slo.generate()
    assert len(rows) == 30
    assert all(r["probe_minutes"] == 1440 for r in rows)


def test_allowed_downtime_is_43_2_minutes():
    minutes = 30 * 24 * 60
    assert minutes == 43_200
    assert minutes * (1 - 0.999) == pytest.approx(43.2)


def test_request_budget_is_not_minutes():
    rows = slo.generate()
    eligible = sum(r["eligible_requests"] for r in rows)
    allowed_failures = eligible * (1 - 0.999)
    # ~1 million requests -> ~1,000 allowed failed requests, a different unit from 43.2 minutes.
    assert 900 < allowed_failures < 1200


@pytest.mark.parametrize("name", ["slo-error-budget.xlsx", "dora-analysis.xlsx"])
def test_workbooks_have_formulas_and_checks(name):
    openpyxl = pytest.importorskip("openpyxl")
    path = ROOT / "reports" / name
    if not path.exists():
        pytest.skip("workbook not built yet")
    wb = openpyxl.load_workbook(path)
    assert "Checks" in wb.sheetnames
    formulas = sum(
        1
        for ws in wb
        for row in ws.iter_rows()
        for c in row
        if isinstance(c.value, str) and c.value.startswith("=")
    )
    assert formulas > 100, "metrics must be live formulas, not pasted numbers"


def test_slo_csv_committed_matches_generator(tmp_path):
    rows = slo.generate()
    with (ROOT / "data" / "slo_daily_synthetic.csv").open(encoding="utf-8") as fh:
        committed = list(csv.DictReader(fh))
    assert [int(r["eligible_requests"]) for r in committed] == [
        r["eligible_requests"] for r in rows
    ]
