# Load Testing — DisplayData k3s + Kafka

## Files

| File | Purpose |
|---|---|
| `LOAD_TESTING_PLAN.md` | Acceptance criteria for all 9 test dimensions + results tables |
| `load-test.sh` | Main test runner (Bash, WSL Ubuntu) |
| `results/<YYYY-MM-DD_HH-MM>/` | Auto-created per run; contains `summary.md` + raw output |

---

## Quick Start (WSL Ubuntu)

Open **WSL Ubuntu** and run:

```bash
# 1. Install prerequisites (one-time)
sudo apt-get install -y apache2-utils jq bc curl

# 2. Navigate to project root (adjust path if needed)
cd "/mnt/c/Users/karan_dhingra/OneDrive - Accordion Partners/Desktop/DisplayData/k3s-baseline-artifacts"

# 3. Make script executable
chmod +x load-testing/load-test.sh

# 4. Run against the dev cluster
bash load-testing/load-test.sh --env dev

# 5. View results
cat load-testing/results/$(ls load-testing/results/ | tail -1)/summary.md
```

> **Important**: kubectl must already be configured in your WSL environment and pointing to the k3s cluster.  
> Run `kubectl get nodes` to verify before starting.

---

## What the Script Tests

| Suite | What It Answers |
|---|---|
| 1 — HTTP Baseline | Is basic request-response latency healthy at zero load? |
| 2 — Kafka Produce Throughput | How many events/sec before errors appear? |
| 3 — Kafka Pipeline Lag | How fast do events flow producer → consumer? |
| 4 — Concurrency & Saturation | At what VU count does the system degrade? |
| 5 — HPA & Auto-Scaling | Does the cluster scale, and how fast? |
| 6 — Infrastructure Readiness | Is the plumbing solid (DNS, probes, topic, NetworkPolicy)? |
| 7 — Observability Baseline | Can we see inside the cluster (metrics-server, logs)? |
| 8 — Resilience & Fault Tolerance | Does everything recover when pods/Kafka restart? |
| 9 — Resource Efficiency | Are CPU/memory limits sized correctly? |

---

## Reading Results

After the run, open `load-testing/results/<timestamp>/summary.md`.  
Look for:
- ✅ **PASS** — threshold met  
- ❌ **FAIL** — threshold not met, investigate  
- ℹ️ **INFO** — recorded for reference, no explicit threshold

Raw `ab` output is saved as `raw_ab_<TestID>.txt` in the same folder.
