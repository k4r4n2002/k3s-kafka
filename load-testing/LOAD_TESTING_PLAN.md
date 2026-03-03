# DisplayData — Load Testing Plan & Acceptance Criteria

> **Purpose**: Pre-project infrastructure evaluation.  
> **Context**: This is a hands-on baseline assessment of the k3s + Kafka stack *before* real product development begins.  
> **Goal**: Answer the fundamental infrastructure questions so the team can build with confidence.

---

## Stack Under Test

| Component | Port | Role | Resource Limits |
|---|---|---|---|
| `api-gateway` | 3001 | Public HTTP gateway (proxies to content + auth) | CPU 100m–500m, Mem 128Mi–512Mi |
| `content-service` | 3002 | CRUD API + Kafka producer (`content-events`) | CPU 100m–500m, Mem 128Mi–512Mi |
| `analytics-service` | 3003 | Kafka consumer + query API | CPU 100m–500m, Mem 128Mi–512Mi |
| `auth-service` | 3004 | Token & API-key validation | CPU 100m–500m, Mem 128Mi–512Mi |
| `kafka` | 9092 | KRaft single-node broker, 1 partition, no persistence | CPU 100m–500m, Mem 256Mi–512Mi |

**HPA**: min 2 – max 5 replicas, scale trigger: 70% CPU  
**Test runner**: WSL Ubuntu, all commands executed via `bash load-testing/load-test.sh --env <env>`

---

## Test Suite Definitions

### Suite 1 — HTTP Baseline
**Question**: Is the basic request-response cycle healthy with zero load?

| Test ID | Endpoint | Method | Concurrency | Requests | Expected |
|---|---|---|---|---|---|
| S1-T1 | api-gateway `/health` | GET | 1 | 100 | HTTP 200, p99 < 50ms |
| S1-T2 | content-service `/health` | GET | 1 | 100 | HTTP 200, p99 < 50ms |
| S1-T3 | analytics-service `/health` | GET | 1 | 100 | HTTP 200, p99 < 50ms |
| S1-T4 | auth-service `/health` | GET | 1 | 100 | HTTP 200, p99 < 50ms |
| S1-T5 | content-service `/items` | GET | 1 | 100 | HTTP 200, p99 < 200ms |
| S1-T6 | analytics-service `/stats` | GET | 1 | 100 | HTTP 200, p99 < 200ms |

---

### Suite 2 — Kafka Produce Throughput
**Question**: How many events per second can content-service push to Kafka before errors appear?

Ramp: 10 → 50 → 100 → 200 → 500 events/sec (concurrent POST /items)

| Test ID | Rate (req/s) | Concurrency | Expected Produce Rate | Max Error Rate | Max p99 Latency |
|---|---|---|---|---|---|
| S2-T1 | 10 eps | 10 | ≥ 10 events/sec | < 1% | < 300ms |
| S2-T2 | 50 eps | 25 | ≥ 50 events/sec | < 1% | < 400ms |
| S2-T3 | 100 eps | 50 | ≥ 100 events/sec | < 1% | < 500ms |
| S2-T4 | 200 eps | 100 | ≥ 200 events/sec | < 1% | < 500ms |
| S2-T5 | 500 eps | 200 | Saturation point recorded | — | — |

---

### Suite 3 — Kafka Consume & End-to-End Pipeline Lag
**Question**: How quickly do events flow from producer → Kafka → consumer at scale?

| Test ID | Produce Rate | Wait Time | Acceptance Criterion |
|---|---|---|---|
| S3-T1 | 50 events (burst) | 10 sec | 100% consumed within 10 sec, lag < 2 sec |
| S3-T2 | 200 events (burst) | 15 sec | 100% consumed within 15 sec, lag < 5 sec |
| S3-T3 | Service restart | — | Consumer resumes from last offset (no message loss) |
| S3-T4 | Event count integrity | — | events produced == events consumed (0 message loss) |

---

### Suite 4 — Concurrency & Saturation Point
**Question**: At what concurrent user count does the system start degrading?

| Test ID | Virtual Users | Duration | Max Error Rate | Max p99 Latency |
|---|---|---|---|---|
| S4-T1 | 10 VUs | 30 sec | < 1% | < 300ms |
| S4-T2 | 25 VUs | 30 sec | < 1% | < 400ms |
| S4-T3 | 50 VUs | 30 sec | < 1% | < 500ms |
| S4-T4 | 100 VUs | 30 sec | < 5% | < 1000ms |
| S4-T5 | 250 VUs | 30 sec | Saturation recorded | — |
| S4-T6 | 500 VUs | 30 sec | Saturation recorded | — |

---

### Suite 5 — HPA & Auto-Scaling Behaviour
**Question**: Does the cluster actually scale under load, and how quickly?

| Test ID | Scenario | Acceptance Criterion |
|---|---|---|
| S5-T1 | Sustained 200 VU load for 90 sec | HPA triggers within 90 sec |
| S5-T2 | New pod ready time | New replica ready < 60 sec after trigger |
| S5-T3 | Error rate during scale-up | < 2% errors during pod addition |
| S5-T4 | Scale-down after load ends | Pods reduce to minReplicas (2) within ~5 min |
| S5-T5 | Max replicas reached | ≤ 5 pods at any time (HPA ceiling) |

---

### Suite 6 — Infrastructure Readiness
**Question**: Is the cluster plumbing solid enough to build a product on?

| Test ID | Check | Acceptance Criterion |
|---|---|---|
| S6-T1 | All pods in Running state | Yes, 0 CrashLoopBackOff or Error pods |
| S6-T2 | Kafka ready after rollout | Yes, within 180 sec of deploy |
| S6-T3 | `content-events` topic exists | Yes, 1 partition, replication-factor 1 |
| S6-T4 | Service DNS resolution | content-service reachable from api-gateway pod |
| S6-T5 | api-gateway `/health` via Ingress | HTTP 200 (Traefik routing works) |
| S6-T6 | NetworkPolicy compliance | No unexpected 503s on required service paths |
| S6-T7 | Pod restart count at baseline | 0 restarts for all pods |

---

### Suite 7 — Observability Baseline
**Question**: Can we actually see what is happening inside the cluster?

| Test ID | Check | Acceptance Criterion |
|---|---|---|
| S7-T1 | `kubectl top pods` works | Yes — metrics-server is running |
| S7-T2 | Logs are structured JSON | Yes — has `ts`, `level`, `service`, `msg` fields |
| S7-T3 | Kafka consumer lag via analytics `/kafka-status` | Endpoint responds with `messagesConsumed` counter |
| S7-T4 | HPA status visible | `kubectl describe hpa` shows current/desired metrics |
| S7-T5 | Pod restarts tracked | Restarts field confirmed in `kubectl get pods` |

---

### Suite 8 — Resilience & Fault Tolerance
**Question**: What happens when things break — does the system recover gracefully?

| Test ID | Fault Injected | Expected Recovery |
|---|---|---|
| S8-T1 | Delete 1 content-service pod | Remaining replica serves; deleted pod restarts < 30 sec |
| S8-T2 | Kill and restart content-service deployment | Kafka producer reconnects < 15 sec (retry logic) |
| S8-T3 | Kill and restart analytics-service | Consumer resumes from last Kafka offset, no messages lost |
| S8-T4 | Delete 1 api-gateway pod (2 replicas) | Zero downtime, traffic served by remaining pod |
| S8-T5 | Kafka pod restarted | All services reconnect within 30 sec |
| S8-T6 | Kafka unreachable simulation | content-service stays up, emits `warn` log, does not crash |

---

### Suite 9 — Resource Efficiency
**Question**: Are the CPU/memory limit configurations sized correctly for the observed workload?

| Test ID | Measurement | Acceptance Criterion |
|---|---|---|
| S9-T1 | CPU utilisation at idle | < 20% of requested (100m) |
| S9-T2 | CPU utilisation at 50 RPS | < 60% of limit (500m) |
| S9-T3 | Memory utilisation at peak load | < 80% of limit (512Mi), no OOMKilled |
| S9-T4 | Kafka CPU at peak produce | < 80% of limit (500m) |
| S9-T5 | Kafka memory at peak produce | < 80% of limit (512Mi) |
| S9-T6 | Any OOMKilled events during test | 0 OOMKilled events |

---

## Results

> Results are written automatically by `load-test.sh`. Run:
> ```bash
> bash load-testing/load-test.sh --env dev
> ```
> and then open `load-testing/results/<timestamp>/summary.md`.

### Last Run Metadata

| Field | Value |
|---|---|
| Run Date | _(auto-filled by script)_ |
| Environment | _(auto-filled by script)_ |
| Cluster | _(auto-filled by script)_ |
| Tool | _(auto-filled by script)_ |
| Script Version | 1.0.0 |

---

### Suite 1 — HTTP Baseline Results

| Test ID | Endpoint | p50 (ms) | p99 (ms) | Error Rate | Status |
|---|---|---|---|---|---|
| S1-T1 | api-gateway /health | — | — | — | ⬜ PENDING |
| S1-T2 | content-service /health | — | — | — | ⬜ PENDING |
| S1-T3 | analytics-service /health | — | — | — | ⬜ PENDING |
| S1-T4 | auth-service /health | — | — | — | ⬜ PENDING |
| S1-T5 | content-service /items | — | — | — | ⬜ PENDING |
| S1-T6 | analytics-service /stats | — | — | — | ⬜ PENDING |

---

### Suite 2 — Kafka Produce Throughput Results

| Test ID | Rate (eps) | Actual Produce Rate | Error Rate | p99 Latency | Status |
|---|---|---|---|---|---|
| S2-T1 | 10 | — | — | — | ⬜ PENDING |
| S2-T2 | 50 | — | — | — | ⬜ PENDING |
| S2-T3 | 100 | — | — | — | ⬜ PENDING |
| S2-T4 | 200 | — | — | — | ⬜ PENDING |
| S2-T5 | 500 (saturation) | — | — | — | ⬜ PENDING |

---

### Suite 3 — Kafka Pipeline Lag Results

| Test ID | Events Produced | Events Consumed | Lag (sec) | Message Loss | Status |
|---|---|---|---|---|---|
| S3-T1 | 50 | — | — | — | ⬜ PENDING |
| S3-T2 | 200 | — | — | — | ⬜ PENDING |
| S3-T3 | restart test | — | — | — | ⬜ PENDING |
| S3-T4 | integrity check | — | — | — | ⬜ PENDING |

---

### Suite 4 — Concurrency Results

| Test ID | VUs | Error Rate | p50 (ms) | p99 (ms) | Status |
|---|---|---|---|---|---|
| S4-T1 | 10 | — | — | — | ⬜ PENDING |
| S4-T2 | 25 | — | — | — | ⬜ PENDING |
| S4-T3 | 50 | — | — | — | ⬜ PENDING |
| S4-T4 | 100 | — | — | — | ⬜ PENDING |
| S4-T5 | 250 | — | — | — | ⬜ PENDING |
| S4-T6 | 500 | — | — | — | ⬜ PENDING |

---

### Suite 5 — HPA Results

| Test ID | Scenario | Result | Status |
|---|---|---|---|
| S5-T1 | HPA trigger time | — sec | ⬜ PENDING |
| S5-T2 | New pod ready time | — sec | ⬜ PENDING |
| S5-T3 | Error rate during scale-up | —% | ⬜ PENDING |
| S5-T4 | Scale-down delay | — min | ⬜ PENDING |
| S5-T5 | Max pods reached | — | ⬜ PENDING |

---

### Suite 6 — Infrastructure Readiness Results

| Test ID | Check | Result | Status |
|---|---|---|---|
| S6-T1 | All pods Running | — | ⬜ PENDING |
| S6-T2 | Kafka ready time | — sec | ⬜ PENDING |
| S6-T3 | content-events topic | — | ⬜ PENDING |
| S6-T4 | Service DNS resolution | — | ⬜ PENDING |
| S6-T5 | Ingress routing | — | ⬜ PENDING |
| S6-T6 | NetworkPolicy compliance | — | ⬜ PENDING |
| S6-T7 | Pod restarts at baseline | — | ⬜ PENDING |

---

### Suite 7 — Observability Results

| Test ID | Check | Result | Status |
|---|---|---|---|
| S7-T1 | kubectl top works | — | ⬜ PENDING |
| S7-T2 | Structured JSON logs | — | ⬜ PENDING |
| S7-T3 | Kafka consumer lag endpoint | — | ⬜ PENDING |
| S7-T4 | HPA status visible | — | ⬜ PENDING |
| S7-T5 | Pod restarts tracked | — | ⬜ PENDING |

---

### Suite 8 — Resilience Results

| Test ID | Fault | Recovery Time | Status |
|---|---|---|---|
| S8-T1 | Delete content-service pod | — sec | ⬜ PENDING |
| S8-T2 | Restart content-service deployment | — sec (Kafka reconnect) | ⬜ PENDING |
| S8-T3 | Restart analytics-service | Resume from offset? — | ⬜ PENDING |
| S8-T4 | Delete 1 api-gateway pod | Zero downtime? — | ⬜ PENDING |
| S8-T5 | Restart Kafka pod | — sec | ⬜ PENDING |
| S8-T6 | Kafka unreachable | Graceful degradation? — | ⬜ PENDING |

---

### Suite 9 — Resource Efficiency Results

| Test ID | Measurement | Value | Status |
|---|---|---|---|
| S9-T1 | CPU at idle | — | ⬜ PENDING |
| S9-T2 | CPU at 50 RPS | — | ⬜ PENDING |
| S9-T3 | Memory at peak | — | ⬜ PENDING |
| S9-T4 | Kafka CPU at peak | — | ⬜ PENDING |
| S9-T5 | Kafka memory at peak | — | ⬜ PENDING |
| S9-T6 | OOMKilled events | — | ⬜ PENDING |

---

### Overall Infrastructure Readiness Summary

| Dimension | Pass / Fail / Partial | Notes |
|---|---|---|
| 1. HTTP Performance | ⬜ PENDING | — |
| 2. Kafka Produce Throughput | ⬜ PENDING | — |
| 3. Kafka Pipeline Lag | ⬜ PENDING | — |
| 4. Concurrency & Saturation | ⬜ PENDING | — |
| 5. HPA & Auto-Scaling | ⬜ PENDING | — |
| 6. Infrastructure Readiness | ⬜ PENDING | — |
| 7. Observability Baseline | ⬜ PENDING | — |
| 8. Resilience & Fault Tolerance | ⬜ PENDING | — |
| 9. Resource Efficiency | ⬜ PENDING | — |

> ✅ **PASS** = All tests in the suite met their acceptance thresholds.  
> ⚠️ **PARTIAL** = Some tests passed; review individual results above.  
> ❌ **FAIL** = One or more critical thresholds were not met.
