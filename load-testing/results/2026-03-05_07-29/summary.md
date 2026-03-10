# Load Test Results — 2026-03-05_07-29

| Field | Value |
|---|---|
| Run Date | 2026-03-05 07:29:52 UTC |
| Environment | dev |
| Namespace | dd-dev |
| Cluster | default |
| Script Version | 1.0.0 |


## Suite 6 — Infrastructure Readiness

| Test ID | Metric | Measured | Threshold | Status |
|---|---|---|---|---|
| S6-T1 | Non-running pods | 0 | 0 | ✅ PASS |
| S6-T3 | content-events topic partitions | ? | 1 | ✅ PASS |
| S6-T7 | Total pod restarts | 1 | ≤ 5 | ✅ PASS |

## Suite 7 — Observability Baseline

| Test ID | Metric | Measured | Threshold | Status |
|---|---|---|---|---|
| S7-T1 | kubectl top pods | OK | Accessible | ✅ PASS |
| S7-T4 | HPA objects in namespace | 2 | ≥ 1 | ✅ PASS |

## Suite 1 — HTTP Baseline

| Test ID | Metric | Measured | Threshold | Status |
|---|---|---|---|---|
| S1-T1 | api-gateway /health p99 latency | 78ms | <300ms | ✅ PASS |
| S1-T1e | api-gateway /health error rate | 0% | <1% | ✅ PASS |
| S1-T2 | content-service /health p99 latency | 70ms | <300ms | ✅ PASS |
| S1-T2e | content-service /health error rate | 0% | <1% | ✅ PASS |
| S1-T3 | analytics-service /health p99 latency | 56ms | <300ms | ✅ PASS |
| S1-T3e | analytics-service /health error rate | 0% | <1% | ✅ PASS |
| S1-T4 | auth-service /health p99 latency | 84ms | <300ms | ✅ PASS |
| S1-T4e | auth-service /health error rate | 0% | <1% | ✅ PASS |
| S1-T5 | content-service /items p99 latency | 87ms | <500ms | ✅ PASS |
| S1-T5e | content-service /items error rate | 0% | <1% | ✅ PASS |
| S1-T6 | analytics-service /stats p99 latency | 81ms | <500ms | ✅ PASS |
| S1-T6e | analytics-service /stats error rate | 0% | <1% | ✅ PASS |

## Suite 2 — Kafka Produce Throughput

| Test ID | Metric | Measured | Threshold | Status |
|---|---|---|---|---|
| S2-T1 | POST /items p99 latency | 248ms | <1000ms | ✅ PASS |
| S2-T1r | POST /items throughput | 35.7 req/s | — recorded | ℹ️ INFO |
| S2-T1e | POST /items error rate | 0% | <1% | ✅ PASS |
| S2-T1k | Kafka events consumed | 10 | ≈10 | ✅ PASS |
| S2-T2 | POST /items p99 latency | 3400ms | <2000ms | ❌ FAIL |
| S2-T2r | POST /items throughput | 58.3 req/s | — recorded | ℹ️ INFO |
| S2-T2e | POST /items error rate | 0% | <1% | ✅ PASS |
| S2-T2k | Kafka events consumed | 200 | ≈200 | ✅ PASS |
| S2-T3 | POST /items p99 latency | 9699ms | <5000ms | ❌ FAIL |
| S2-T3r | POST /items throughput | 51.0 req/s | — recorded | ℹ️ INFO |
| S2-T3e | POST /items error rate | 0% | <3% | ✅ PASS |
| S2-T3k | Kafka events consumed | 500 | ≈500 | ✅ PASS |
| S2-T4 | POST /items p99 latency | 13388ms | <10000ms | ❌ FAIL |
| S2-T4r | POST /items throughput | 73.3 req/s | — recorded | ℹ️ INFO |
| S2-T4e | POST /items error rate | 71.50% | <5% | ❌ FAIL |
| S2-T4k | Kafka events consumed | 1000 | ≈1000 | ✅ PASS |
| S2-T5 | POST /items p99 latency | 30127ms | <15000ms | ❌ FAIL |
| S2-T5r | POST /items throughput | 66.3 req/s | — recorded | ℹ️ INFO |
| S2-T5e | POST /items error rate | 5.00% | <10% | ✅ PASS |
| S2-T5k | Kafka events consumed | 1901 | ≈2000 | ✅ PASS |

## Suite 3 — Kafka Pipeline Lag

| Test ID | Metric | Measured | Threshold | Status |
|---|---|---|---|---|
| S3-T1 | E2E pipeline lag | 1.06s | <2s | ✅ PASS |
| S3-T1m | Messages consumed | 50 | 50 | ✅ PASS |
| S3-T2 | E2E pipeline lag | 2.97s | <5s | ✅ PASS |
| S3-T2m | Messages consumed | 200 | 200 | ✅ PASS |
| S3-T3 | content-service health after restart | HTTP 200 | HTTP 200 | ✅ PASS |
| S3-T4 | Event integrity (post-restart consume) | 20/20 | ≥ 18 | ✅ PASS |

## Suite 4 — Concurrency & Saturation

| Test ID | Metric | Measured | Threshold | Status |
|---|---|---|---|---|
| S4-T1 | 10 VU p50 latency | 4ms | — recorded | ℹ️ INFO |
| S4-T1p | 10 VU p99 latency | 111ms | <2000ms | ✅ PASS |
| S4-T1e | 10 VU error rate | 0% | <1% | ✅ PASS |
| S4-T2 | 25 VU p50 latency | 99ms | — recorded | ℹ️ INFO |
| S4-T2p | 25 VU p99 latency | 1336ms | <3000ms | ✅ PASS |
| S4-T2e | 25 VU error rate | 0% | <1% | ✅ PASS |
| S4-T3 | 50 VU p50 latency | 100ms | — recorded | ℹ️ INFO |
| S4-T3p | 50 VU p99 latency | 2415ms | <5000ms | ✅ PASS |
| S4-T3e | 50 VU error rate | 0% | <3% | ✅ PASS |
| S4-T4 | 100 VU p50 latency | 106ms | — recorded | ℹ️ INFO |
| S4-T4p | 100 VU p99 latency | 5030ms | <15000ms | ✅ PASS |
| S4-T4e | 100 VU error rate | 0% | <5% | ✅ PASS |
| S4-T5 | 250 VU p50 latency | 100ms | — recorded | ℹ️ INFO |
| S4-T5p | 250 VU p99 latency | 7815ms | <20000ms | ✅ PASS |
| S4-T5e | 250 VU error rate | 0% | <20% | ✅ PASS |
| S4-T6 | 500 VU p50 latency | 171ms | — recorded | ℹ️ INFO |
| S4-T6p | 500 VU p99 latency | 10552ms | <30000ms | ✅ PASS |
| S4-T6e | 500 VU error rate | 0% | <30% | ✅ PASS |

## Suite 5 — HPA & Auto-Scaling

| Test ID | Metric | Measured | Threshold | Status |
|---|---|---|---|---|
| S5-T1 | HPA trigger time | NOT_TRIGGERED | <90s | ❌ FAIL |
| S5-T2 | Scale-up occurred | NO | YES | ❌ FAIL |
| S5-T5 | Peak pod count | 3 | ≤ 5 | ✅ PASS |
| S5-T4 | Pods 30s after load ends | 3 | ≤ 3 | ℹ️ INFO |

## Suite 8 — Resilience & Fault Tolerance

| Test ID | Metric | Measured | Threshold | Status |
|---|---|---|---|---|
| S8-T1 | Pod replacement time | 6s | <30s | ✅ PASS |
| S8-T2 | content-service healthy after restart | HTTP 200 | HTTP 200 | ✅ PASS |
| S8-T2k | Kafka producer reconnect | true | true | ✅ PASS |
| S8-T4 | Errors during api-gw pod delete | 0 | ≤ 2 | ✅ PASS |
| S8-T6h | content-service /health when Kafka down | HTTP 000000 | HTTP 200 | ❌ FAIL |
| S8-T6p | POST /items accepted when Kafka down | HTTP 000000 | HTTP 201 | ❌ FAIL |

## Suite 9 — Resource Efficiency

| Test ID | Metric | Measured | Threshold | Status |
|---|---|---|---|---|
| S9-idle | analytics-service-84b795545d-6l599 idle CPU | 27m | <100m | ℹ️ INFO |
| S9-idle | analytics-service-84b795545d-6l599 idle Memory | 23Mi | <200Mi | ℹ️ INFO |
| S9-idle | api-gateway-645f99f4bc-k56jn idle CPU | 1m | <100m | ℹ️ INFO |
| S9-idle | api-gateway-645f99f4bc-k56jn idle Memory | 11Mi | <200Mi | ℹ️ INFO |
| S9-idle | api-gateway-645f99f4bc-msjms idle CPU | 4m | <100m | ℹ️ INFO |
| S9-idle | api-gateway-645f99f4bc-msjms idle Memory | 22Mi | <200Mi | ℹ️ INFO |
| S9-idle | auth-service-5f7c68d78b-c7q6n idle CPU | 1m | <100m | ℹ️ INFO |
| S9-idle | auth-service-5f7c68d78b-c7q6n idle Memory | 20Mi | <200Mi | ℹ️ INFO |
| S9-idle | content-service-68797f9555-6b2n4 idle CPU | 27m | <100m | ℹ️ INFO |
| S9-idle | content-service-68797f9555-6b2n4 idle Memory | 13Mi | <200Mi | ℹ️ INFO |
| S9-idle | content-service-68797f9555-ddqjk idle CPU | 27m | <100m | ℹ️ INFO |
| S9-idle | content-service-68797f9555-ddqjk idle Memory | 13Mi | <200Mi | ℹ️ INFO |
| S9-idle | content-service-68797f9555-nlrmr idle CPU | 33m | <100m | ℹ️ INFO |
| S9-idle | content-service-68797f9555-nlrmr idle Memory | 15Mi | <200Mi | ℹ️ INFO |
| S9-T2 | kubectl top captured at 50 RPS | YES | YES | ✅ PASS |
| S9-T6 | OOMKilled events | 0 | 0 | ✅ PASS |

---

## Run Summary

| Metric | Count |
|---|---|
| ✅ PASS | 52 |
| ❌ FAIL | 9 |
| ℹ️ INFO (recorded, no threshold) | 26 |
| **Total** | **87** |

> Raw output files: `load-testing/results/2026-03-05_07-29/`
> Re-run: `bash load-testing/load-test.sh --env dev`
