# Load Test Results — 2026-03-03_07-15

| Field | Value |
|---|---|
| Run Date | 2026-03-03 07:15:40 UTC |
| Environment | dev |
| Namespace | dd-dev |
| Cluster | default |
| Script Version | 1.0.0 |


## Suite 6 — Infrastructure Readiness

| Test ID | Metric | Measured | Threshold | Status |
|---|---|---|---|---|
| S6-T1 | Non-running pods | 0 | 0 | ✅ PASS |
| S6-T3 | content-events topic partitions | ? | 1 | ✅ PASS |
| S6-T7 | Total pod restarts | 2 | ≤ 5 | ✅ PASS |

## Suite 7 — Observability Baseline

| Test ID | Metric | Measured | Threshold | Status |
|---|---|---|---|---|
| S7-T1 | kubectl top pods | OK | Accessible | ✅ PASS |
| S7-T4 | HPA objects in namespace | 1 | ≥ 1 | ✅ PASS |
