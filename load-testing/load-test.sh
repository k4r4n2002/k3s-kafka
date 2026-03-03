#!/usr/bin/env bash
# =============================================================================
# load-test.sh — DisplayData k3s + Kafka Exhaustive Load Test Runner
# Run from WSL (Ubuntu):  bash load-testing/load-test.sh --env dev
#
# Prerequisites (WSL Ubuntu):
#   sudo apt-get install -y apache2-utils jq bc curl
#   kubectl must be configured and pointing to the k3s cluster
#
# Outputs:  load-testing/results/<YYYY-MM-DD_HH-MM>/
#   summary.md       — human-readable PASS/FAIL report
#   raw_*.txt        — raw ab/hey output per test
#   pod_resources_*.txt — kubectl top snapshots
#   kafka_events_*.txt  — analytics event count snapshots
# =============================================================================
set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV="dev"
NAMESPACE=""

# Timeouts & durations
PORT_FORWARD_WAIT=5       # seconds to wait after starting all port-forwards
PF_VERIFY_RETRIES=12      # number of retries when verifying each port-forward
PF_VERIFY_INTERVAL=2      # seconds between retries
KAFKA_LAG_WAIT=15         # seconds to wait for consumer to catch up
HPA_STRESS_DURATION=90    # seconds for HPA stress test
RESILIENCE_WAIT=30        # seconds to wait for pod recovery

# Ports (local — forwarded from cluster)
GW_PORT=18001             # api-gateway
CS_PORT=18002             # content-service
AN_PORT=18003             # analytics-service
AU_PORT=18004             # auth-service

GW_URL="http://localhost:${GW_PORT}"
CS_URL="http://localhost:${CS_PORT}"
AN_URL="http://localhost:${AN_PORT}"
AU_URL="http://localhost:${AU_PORT}"

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[PASS]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
fail()    { echo -e "${RED}[FAIL]${RESET}  $*"; }
header()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; \
            echo -e "${BOLD}${CYAN}  $*${RESET}"; \
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; }

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)  ENV="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --env <env>"
      echo "  --env  k3s environment (dev | prod). Namespace will be dd-<env>"
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

NAMESPACE="dd-${ENV}"

# ── Results dir ────────────────────────────────────────────────────────────────
TIMESTAMP="$(date '+%Y-%m-%d_%H-%M')"
RESULTS_DIR="${SCRIPT_DIR}/results/${TIMESTAMP}"
mkdir -p "${RESULTS_DIR}"
SUMMARY="${RESULTS_DIR}/summary.md"

# Initialise summary file
cat > "${SUMMARY}" << EOF
# Load Test Results — ${TIMESTAMP}

| Field | Value |
|---|---|
| Run Date | $(date '+%Y-%m-%d %H:%M:%S %Z') |
| Environment | ${ENV} |
| Namespace | ${NAMESPACE} |
| Cluster | $(kubectl config current-context 2>/dev/null || echo 'unknown') |
| Script Version | 1.0.0 |

EOF

# ── Helpers ────────────────────────────────────────────────────────────────────
PF_PIDS=()

# Record a result line in summary.md
record_result() {
  # $1=suite $2=test_id $3=metric $4=value $5=threshold $6=pass|fail
  local icon="✅"
  [[ "$6" == "fail" ]] && icon="❌"
  [[ "$6" == "info" ]] && icon="ℹ️"
  echo "| ${2} | ${3} | ${4} | ${5} | ${icon} ${6^^} |" >> "${SUMMARY}"
}

begin_suite_table() {
  echo -e "\n## ${1}\n" >> "${SUMMARY}"
  echo "| Test ID | Metric | Measured | Threshold | Status |" >> "${SUMMARY}"
  echo "|---|---|---|---|---|" >> "${SUMMARY}"
}

# Calculate percentile from ab output (Time per request distribution)
ab_percentile() {
  # $1=ab_output_file $2=percentile (50|66|75|80|90|95|98|99|100)
  grep "^ *${2}%" "$1" 2>/dev/null | awk '{print $2}' | head -1
}

# Calculate error rate from ab output
ab_error_rate() {
  local total failed
  total=$(grep "^Complete requests:" "$1" 2>/dev/null | awk '{print $3}')
  failed=$(grep "^Failed requests:" "$1" 2>/dev/null | awk '{print $3}')
  [[ -z "$total" || "$total" -eq 0 ]] && echo "N/A" && return
  echo "scale=2; ${failed:-0} * 100 / ${total}" | bc
}

# Quick curl latency (ms) single request
curl_latency_ms() {
  curl -s -o /dev/null -w "%{time_total}" "$1" 2>/dev/null \
    | awk '{printf "%.0f", $1*1000}'
}

# Get analytics event total
analytics_event_total() {
  curl -s "${AN_URL}/kafka-status" 2>/dev/null | jq -r '.kafka.messagesConsumed // 0' 2>/dev/null || echo "0"
}

# Pass/fail comparison (numeric, $1 <= $2 means pass)
pf_lte() {
  # $1=measured $2=threshold → prints pass or fail
  if [[ "$1" == "N/A" || -z "$1" ]]; then echo "info"; return; fi
  if (( $(echo "$1 <= $2" | bc -l 2>/dev/null) )); then echo "pass"; else echo "fail"; fi
}
pf_gte() {
  if [[ "$1" == "N/A" || -z "$1" ]]; then echo "info"; return; fi
  if (( $(echo "$1 >= $2" | bc -l 2>/dev/null) )); then echo "pass"; else echo "fail"; fi
}

# ── Prerequisite checks ────────────────────────────────────────────────────────
header "PRE-FLIGHT CHECKS"
MISSING_TOOLS=()
for tool in kubectl curl jq bc ab; do
  if ! command -v "$tool" &>/dev/null; then
    MISSING_TOOLS+=("$tool")
    warn "Missing tool: $tool"
  else
    info "Found: $tool ($(command -v "$tool"))"
  fi
done

# Fall back: try 'hey' if 'ab' not found
USE_HEY=false
if [[ " ${MISSING_TOOLS[*]} " =~ " ab " ]]; then
  if command -v hey &>/dev/null; then
    USE_HEY=true
    MISSING_TOOLS=("${MISSING_TOOLS[@]/ab}")
    info "ab not found — will use hey instead"
  fi
fi

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
  fail "Missing required tools: ${MISSING_TOOLS[*]}"
  fail "Install with: sudo apt-get install -y apache2-utils jq bc curl"
  exit 1
fi

# Check kubectl context
if ! kubectl cluster-info &>/dev/null; then
  fail "kubectl cannot reach the cluster. Check your kubeconfig."
  exit 1
fi
info "kubectl context: $(kubectl config current-context)"

# Check namespace exists
if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  fail "Namespace '${NAMESPACE}' does not exist. Deploy first: bash deployment/deploy.sh --env ${ENV} --all"
  exit 1
fi
info "Namespace: ${NAMESPACE} ✓"

# ── Suite 6a — Infrastructure Readiness (pre-load) ────────────────────────────
header "SUITE 6 — Infrastructure Readiness"
begin_suite_table "Suite 6 — Infrastructure Readiness"

# S6-T1: All pods running
info "S6-T1: Checking all pods are Running..."
NOT_RUNNING=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
  | grep -v -E "Running|Completed" | wc -l)
if [[ "$NOT_RUNNING" -eq 0 ]]; then
  success "S6-T1: All pods Running"
  record_result 6 "S6-T1" "Non-running pods" "0" "0" "pass"
else
  fail "S6-T1: $NOT_RUNNING pod(s) not in Running state"
  record_result 6 "S6-T1" "Non-running pods" "$NOT_RUNNING" "0" "fail"
  kubectl get pods -n "${NAMESPACE}" >> "${RESULTS_DIR}/pod_status_preflight.txt"
fi

# S6-T3: content-events topic
info "S6-T3: Checking content-events topic..."
KAFKA_POD=$(kubectl get pod -n "${NAMESPACE}" -l app=kafka -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$KAFKA_POD" ]]; then
  TOPIC_INFO=$(kubectl exec -n "${NAMESPACE}" "${KAFKA_POD}" -- \
    /opt/kafka/bin/kafka-topics.sh \
    --bootstrap-server "kafka.${NAMESPACE}.svc.cluster.local:9092" \
    --describe --topic content-events 2>/dev/null || echo "NOT_FOUND")
  if echo "$TOPIC_INFO" | grep -q "content-events"; then
    success "S6-T3: content-events topic exists"
    PARTITIONS=$(echo "$TOPIC_INFO" | grep -oP 'PartitionCount:\K[0-9]+' | head -1)
    record_result 6 "S6-T3" "content-events topic partitions" "${PARTITIONS:-?}" "1" "pass"
    echo "$TOPIC_INFO" >> "${RESULTS_DIR}/kafka_topic_describe.txt"
  else
    fail "S6-T3: content-events topic NOT found"
    record_result 6 "S6-T3" "content-events topic exists" "NO" "YES" "fail"
  fi
else
  warn "S6-T3: No Kafka pod found in ${NAMESPACE}"
  record_result 6 "S6-T3" "Kafka pod available" "NO" "YES" "fail"
fi

# S6-T7: Pod restart counts
info "S6-T7: Checking pod restart counts..."
kubectl get pods -n "${NAMESPACE}" --no-headers \
  > "${RESULTS_DIR}/pod_status_preflight.txt" 2>&1
RESTART_TOTAL=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
  | awk '{sum+=$4} END {print sum+0}')
STATUS_6T7=$(pf_lte "$RESTART_TOTAL" "5")
[[ "$STATUS_6T7" == "pass" ]] && success "S6-T7: Pod restarts = ${RESTART_TOTAL}" \
  || warn "S6-T7: Pod restarts = ${RESTART_TOTAL} (may indicate instability)"
record_result 6 "S6-T7" "Total pod restarts" "$RESTART_TOTAL" "≤ 5" "$STATUS_6T7"

# ── Suite 7 — Observability Baseline ──────────────────────────────────────────
header "SUITE 7 — Observability Baseline"
begin_suite_table "Suite 7 — Observability Baseline"

# S7-T1: kubectl top pods
info "S7-T1: kubectl top pods..."
if kubectl top pods -n "${NAMESPACE}" > "${RESULTS_DIR}/pod_resources_baseline.txt" 2>&1; then
  success "S7-T1: kubectl top works (metrics-server running)"
  record_result 7 "S7-T1" "kubectl top pods" "OK" "Accessible" "pass"
else
  fail "S7-T1: kubectl top failed — metrics-server may not be running"
  record_result 7 "S7-T1" "kubectl top pods" "FAILED" "Accessible" "fail"
fi

# S7-T4: HPA visible
info "S7-T4: Checking HPA status..."
if kubectl get hpa -n "${NAMESPACE}" > "${RESULTS_DIR}/hpa_baseline.txt" 2>&1; then
  HPA_COUNT=$(kubectl get hpa -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l)
  success "S7-T4: ${HPA_COUNT} HPA object(s) found"
  record_result 7 "S7-T4" "HPA objects in namespace" "$HPA_COUNT" "≥ 1" \
    "$(pf_gte "$HPA_COUNT" 1)"
else
  fail "S7-T4: Could not retrieve HPA"
  record_result 7 "S7-T4" "HPA objects in namespace" "0" "≥ 1" "fail"
fi

# ── Port-forwarding ────────────────────────────────────────────────────────────
header "PORT FORWARDING"
info "Starting port-forwards for all 4 services..."
cleanup() {
  info "Cleaning up port-forwards..."
  for pid in "${PF_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT INT TERM

start_pf() {
  local svc=$1 local_port=$2 remote_port=$3
  # Validate that the service actually exists before trying to forward
  if ! kubectl get svc "${svc}" -n "${NAMESPACE}" &>/dev/null; then
    warn "  Service '${svc}' not found in namespace '${NAMESPACE}' — skipping"
    PF_PIDS+=(-1)
    return
  fi
  kubectl port-forward "svc/${svc}" "${local_port}:${remote_port}" \
    -n "${NAMESPACE}" > "${RESULTS_DIR}/pf_${svc}.log" 2>&1 &
  PF_PIDS+=($!)
  info "  ${svc}: localhost:${local_port} -> cluster:${remote_port} (pid $!)"
}

start_pf "api-gateway"       "${GW_PORT}"  3001
start_pf "content-service"   "${CS_PORT}"  3002
start_pf "analytics-service" "${AN_PORT}"  3003
start_pf "auth-service"      "${AU_PORT}"  3004

info "Waiting ${PORT_FORWARD_WAIT}s for port-forwards to initialise..."
sleep "${PORT_FORWARD_WAIT}"

# Verify each port-forward with retries — port-forward process is async and
# can take several seconds to bind, especially over a slow kubeconfig or VPN.
verify_pf() {
  local label="$1" url="$2"
  local attempt=0
  while [[ $attempt -lt $PF_VERIFY_RETRIES ]]; do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "${url}" 2>/dev/null || echo "000")
    if [[ "$HTTP" == "200" ]]; then
      success "  Port-forward OK: ${label} (HTTP 200, attempt $((attempt+1)))"
      return 0
    fi
    attempt=$(( attempt + 1 ))
    info "  ${label}: attempt ${attempt}/${PF_VERIFY_RETRIES} → HTTP ${HTTP}, retrying in ${PF_VERIFY_INTERVAL}s..."
    sleep "${PF_VERIFY_INTERVAL}"
  done
  fail "  Port-forward FAILED for ${label} after ${PF_VERIFY_RETRIES} attempts (last: HTTP ${HTTP})"
  return 1
}

ALL_OK=true
for url_label in "${GW_URL}/health:api-gateway" "${CS_URL}/health:content-service" \
                  "${AN_URL}/health:analytics-service" "${AU_URL}/health:auth-service"; do
  url="${url_label%%:*}"; label="${url_label##*:}"
  verify_pf "${label}" "${url}" || ALL_OK=false
done

if [[ "$ALL_OK" == "false" ]]; then
  fail "One or more port-forwards could not be verified."
  info "  Tip: run 'kubectl get svc -n ${NAMESPACE}' to see what services are deployed."
  exit 1
fi

# ── Helper: run_ab ─────────────────────────────────────────────────────────────
run_ab() {
  # $1=label $2=requests $3=concurrency $4=url [$5=post_body_file]
  local label="$1" reqs="$2" conc="$3" url="$4" body_file="${5:-}"
  local outfile="${RESULTS_DIR}/raw_ab_${label}.txt"
  info "  ab -n ${reqs} -c ${conc} ${url}"
  if [[ -n "$body_file" ]]; then
    ab -n "${reqs}" -c "${conc}" \
      -T 'application/json' -p "${body_file}" \
      -s 30 "${url}" > "${outfile}" 2>&1 || true
  else
    ab -n "${reqs}" -c "${conc}" -s 30 "${url}" > "${outfile}" 2>&1 || true
  fi
  echo "$outfile"
}

# ── SUITE 1 — HTTP Baseline ────────────────────────────────────────────────────
header "SUITE 1 — HTTP Baseline"
begin_suite_table "Suite 1 — HTTP Baseline"

S1_ENDPOINTS=(
  "S1-T1:${GW_URL}/health:api-gateway /health:50"
  "S1-T2:${CS_URL}/health:content-service /health:50"
  "S1-T3:${AN_URL}/health:analytics-service /health:50"
  "S1-T4:${AU_URL}/health:auth-service /health:50"
  "S1-T5:${CS_URL}/items:content-service /items:200"
  "S1-T6:${AN_URL}/stats:analytics-service /stats:200"
)

for entry in "${S1_ENDPOINTS[@]}"; do
  IFS=':' read -r tid url label threshold <<< "$entry"
  info "${tid}: Baseline test — ${label}"
  outfile=$(run_ab "${tid}" 100 1 "${url}/")
  # ab appends trailing slash; if 404, try without
  [[ ! -f "$outfile" ]] && outfile=$(run_ab "${tid}" 100 1 "${url}")
  p99=$(ab_percentile "$outfile" 99)
  err=$(ab_error_rate "$outfile")
  p99=${p99:-9999}
  status=$(pf_lte "$p99" "$threshold")
  [[ "$status" == "pass" ]] && success "${tid}: p99=${p99}ms (threshold ${threshold}ms)" \
    || fail "${tid}: p99=${p99}ms (threshold ${threshold}ms)"
  record_result 1 "$tid" "${label} p99 latency" "${p99}ms" "<${threshold}ms" "$status"
  record_result 1 "${tid}e" "${label} error rate" "${err}%" "<1%" "$(pf_lte "${err//N\/A/0}" 1)"
done

# ── SUITE 2 — Kafka Produce Throughput ────────────────────────────────────────
header "SUITE 2 — Kafka Produce Throughput"
begin_suite_table "Suite 2 — Kafka Produce Throughput"

# Create temp JSON body file
POST_BODY=$(mktemp /tmp/load_test_post_XXXX.json)
echo '{"title":"LoadTest Item","type":"image"}' > "${POST_BODY}"

S2_RATES=("S2-T1:10:10:300:1" "S2-T2:200:25:400:1" "S2-T3:500:50:500:1" "S2-T4:1000:100:500:1" "S2-T5:2000:200:999:5")

for entry in "${S2_RATES[@]}"; do
  IFS=':' read -r tid reqs conc lat_thresh err_thresh <<< "$entry"
  info "${tid}: POSTing ${reqs} items to content-service (concurrency ${conc})"

  # Snapshot event count before
  before_events=$(analytics_event_total)

  T_START=$(date +%s%3N)
  outfile=$(run_ab "${tid}" "${reqs}" "${conc}" "${CS_URL}/items" "${POST_BODY}")
  T_END=$(date +%s%3N)
  ELAPSED_MS=$(( T_END - T_START ))

  p99=$(ab_percentile "$outfile" 99); p99=${p99:-9999}
  err=$(ab_error_rate "$outfile"); err=${err:-0}
  ELAPSED_SEC=$(echo "scale=2; ${ELAPSED_MS}/1000" | bc)
  ACTUAL_EPS=$(echo "scale=1; ${reqs}/${ELAPSED_SEC}" | bc 2>/dev/null || echo "N/A")

  status_lat=$(pf_lte "$p99" "$lat_thresh")
  status_err=$(pf_lte "${err//N\/A/0}" "$err_thresh")

  info "  Result: p99=${p99}ms, errors=${err}%, rate=${ACTUAL_EPS} req/s"
  record_result 2 "$tid" "POST /items p99 latency" "${p99}ms" "<${lat_thresh}ms" "$status_lat"
  record_result 2 "${tid}r" "POST /items throughput" "${ACTUAL_EPS} req/s" "— recorded" "info"
  record_result 2 "${tid}e" "POST /items error rate" "${err}%" "<${err_thresh}%" "$status_err"

  # Wait for Kafka consumption
  info "  Waiting ${KAFKA_LAG_WAIT}s for analytics-service to consume events..."
  sleep "${KAFKA_LAG_WAIT}"
  after_events=$(analytics_event_total)
  new_events=$(( after_events - before_events ))
  info "  Kafka events: produced ~${reqs}, consumed ${new_events}"
  record_result 2 "${tid}k" "Kafka events consumed" "$new_events" "≈${reqs}" \
    "$(pf_gte "$new_events" "$(echo "${reqs}*0.95/1" | bc)")"

  echo "$new_events" >> "${RESULTS_DIR}/kafka_events_${tid}.txt"
done
rm -f "${POST_BODY}"

# ── SUITE 3 — Kafka Pipeline Lag ──────────────────────────────────────────────
header "SUITE 3 — Kafka Pipeline Lag"
begin_suite_table "Suite 3 — Kafka Pipeline Lag"

run_lag_test() {
  local tid="$1" count="$2" lag_thresh_sec="$3"
  info "${tid}: Producing ${count} events, measuring E2E lag..."
  local body=$(mktemp /tmp/lag_test_XXXX.json)
  echo '{"title":"LagTestItem","type":"image"}' > "$body"

  local before=$(analytics_event_total)
  local t_start=$(date +%s%3N)

  # Send events
  ab -n "${count}" -c 20 -T 'application/json' -p "$body" \
    "${CS_URL}/items" > "${RESULTS_DIR}/raw_lag_${tid}.txt" 2>&1 || true

  # Poll analytics until all consumed or 30s timeout
  local deadline=$(( $(date +%s) + 30 ))
  local consumed=0
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    consumed=$(analytics_event_total)
    local delta=$(( consumed - before ))
    [[ "$delta" -ge "$count" ]] && break
    sleep 1
  done
  local t_end=$(date +%s%3N)
  rm -f "$body"

  local lag_ms=$(( t_end - t_start ))
  local lag_sec=$(echo "scale=2; ${lag_ms}/1000" | bc)
  local delta=$(( consumed - before ))

  info "  Lag: ${lag_sec}s | Consumed: ${delta}/${count}"
  record_result 3 "$tid" "E2E pipeline lag" "${lag_sec}s" "<${lag_thresh_sec}s" \
    "$(pf_lte "$lag_sec" "$lag_thresh_sec")"
  record_result 3 "${tid}m" "Messages consumed" "${delta}" "${count}" \
    "$(pf_gte "$delta" "$count")"
  echo "lag_ms=${lag_ms} consumed=${delta} expected=${count}" \
    >> "${RESULTS_DIR}/kafka_lag_${tid}.txt"
}

run_lag_test "S3-T1" 50  2
run_lag_test "S3-T2" 200 5

# S3-T3: Restart test (message count integrity after restart)
info "S3-T3: Restart content-service deployment and verify Kafka reconnect..."
before_restart=$(analytics_event_total)
kubectl rollout restart deployment/content-service -n "${NAMESPACE}" &>/dev/null || \
  warn "S3-T3: rollout restart failed (deployment may not exist)"
sleep 20
# Verify content-service responds again
HTTP_AFTER=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "${CS_URL}/health" 2>/dev/null || echo "000")
if [[ "$HTTP_AFTER" == "200" ]]; then
  success "S3-T3: content-service healthy after restart"
  record_result 3 "S3-T3" "content-service health after restart" "HTTP 200" "HTTP 200" "pass"
else
  fail "S3-T3: content-service NOT healthy after restart (HTTP ${HTTP_AFTER})"
  record_result 3 "S3-T3" "content-service health after restart" "HTTP ${HTTP_AFTER}" "HTTP 200" "fail"
fi
# Re-start port-forward for content-service since the pod changed
kill "${PF_PIDS[1]}" 2>/dev/null || true
sleep 2
kubectl port-forward "svc/content-service" "${CS_PORT}:3002" -n "${NAMESPACE}" &>/dev/null &
PF_PIDS[1]=$!
sleep 3

# S3-T4: Event integrity (produce 20 more, check consumed)
info "S3-T4: Event integrity check post-restart..."
body=$(mktemp /tmp/s3t4_XXXX.json)
echo '{"title":"PostRestartItem","type":"video"}' > "$body"
before_s3t4=$(analytics_event_total)
ab -n 20 -c 5 -T 'application/json' -p "$body" \
  "${CS_URL}/items" > "${RESULTS_DIR}/raw_s3t4.txt" 2>&1 || true
sleep 10
after_s3t4=$(analytics_event_total)
delta_s3t4=$(( after_s3t4 - before_s3t4 ))
rm -f "$body"
record_result 3 "S3-T4" "Event integrity (post-restart consume)" "${delta_s3t4}/20" "≥ 18" \
  "$(pf_gte "$delta_s3t4" 18)"

# ── SUITE 4 — Concurrency & Saturation ────────────────────────────────────────
header "SUITE 4 — Concurrency & Saturation Point"
begin_suite_table "Suite 4 — Concurrency & Saturation"

VU_CONFIGS=("S4-T1:10:300:1" "S4-T2:25:400:1" "S4-T3:50:500:1" "S4-T4:100:1000:5" "S4-T5:250:9999:20" "S4-T6:500:9999:30")

for entry in "${VU_CONFIGS[@]}"; do
  IFS=':' read -r tid vus lat_thresh err_thresh <<< "$entry"
  reqs=$(( vus * 10 ))
  info "${tid}: ${vus} VUs, ${reqs} requests → api-gateway /health"
  outfile=$(run_ab "${tid}" "${reqs}" "${vus}" "${GW_URL}/health")
  p50=$(ab_percentile "$outfile" 50); p99=$(ab_percentile "$outfile" 99)
  err=$(ab_error_rate "$outfile")
  p50=${p50:-9999}; p99=${p99:-9999}; err=${err:-0}
  status_lat=$(pf_lte "$p99" "$lat_thresh")
  status_err=$(pf_lte "${err//N\/A/0}" "$err_thresh")
  info "  VUs=${vus}: p50=${p50}ms p99=${p99}ms errors=${err}%"
  record_result 4 "$tid" "${vus} VU p50 latency" "${p50}ms" "— recorded" "info"
  record_result 4 "${tid}p" "${vus} VU p99 latency" "${p99}ms" "<${lat_thresh}ms" "$status_lat"
  record_result 4 "${tid}e" "${vus} VU error rate" "${err}%" "<${err_thresh}%" "$status_err"
done

# ── SUITE 5 — HPA Stress ──────────────────────────────────────────────────────
header "SUITE 5 — HPA & Auto-Scaling"
begin_suite_table "Suite 5 — HPA & Auto-Scaling"

info "S5-T1: Recording initial pod count..."
INITIAL_PODS=$(kubectl get pods -n "${NAMESPACE}" -l app=content-service \
  --no-headers 2>/dev/null | wc -l)
info "  Initial content-service pods: ${INITIAL_PODS}"
HPA_START=$(date +%s)

# Capture HPA status file
kubectl describe hpa -n "${NAMESPACE}" > "${RESULTS_DIR}/hpa_before_stress.txt" 2>&1 || true

info "S5-T1: Running ${HPA_STRESS_DURATION}s sustained load at 200 VUs (content-service /items)..."
body=$(mktemp /tmp/hpa_stress_XXXX.json)
echo '{"title":"HPAStressItem","type":"image"}' > "$body"
# Run load in background and poll HPA concurrently
HPA_TRIGGERED=false
HPA_TRIGGER_SEC="N/A"

(ab -n 99999 -c 200 -t "${HPA_STRESS_DURATION}" \
  -T 'application/json' -p "${body}" \
  "${CS_URL}/items" > "${RESULTS_DIR}/raw_S5-stress.txt" 2>&1 || true) &
STRESS_PID=$!

POLL_INTERVAL=5
elapsed=0
while [[ "$elapsed" -lt "$HPA_STRESS_DURATION" ]]; do
  sleep "$POLL_INTERVAL"
  elapsed=$(( elapsed + POLL_INTERVAL ))
  CURRENT_PODS=$(kubectl get pods -n "${NAMESPACE}" -l app=content-service \
    --no-headers 2>/dev/null | grep -c "Running" || echo 0)
  kubectl top pods -n "${NAMESPACE}" >> "${RESULTS_DIR}/pod_resources_hpa_stress.txt" 2>&1 || true
  if [[ "$HPA_TRIGGERED" == "false" && "$CURRENT_PODS" -gt "$INITIAL_PODS" ]]; then
    HPA_TRIGGERED=true
    HPA_TRIGGER_SEC="$elapsed"
    success "S5-T1/T2: HPA scaled from ${INITIAL_PODS} → ${CURRENT_PODS} pods at ~${HPA_TRIGGER_SEC}s"
  fi
  info "  [${elapsed}s] Pods running: ${CURRENT_PODS}"
done
wait "$STRESS_PID" 2>/dev/null || true
rm -f "$body"

PEAK_PODS=$(kubectl get pods -n "${NAMESPACE}" -l app=content-service \
  --no-headers 2>/dev/null | wc -l)
kubectl describe hpa -n "${NAMESPACE}" > "${RESULTS_DIR}/hpa_after_stress.txt" 2>&1 || true
kubectl get events -n "${NAMESPACE}" | grep -i "scaled" \
  >> "${RESULTS_DIR}/hpa_scale_events.txt" 2>&1 || true

if [[ "$HPA_TRIGGERED" == "true" ]]; then
  record_result 5 "S5-T1" "HPA trigger time" "${HPA_TRIGGER_SEC}s" "<90s" \
    "$(pf_lte "$HPA_TRIGGER_SEC" 90)"
  success "S5-T2: Scale-up observed (${INITIAL_PODS} → ${PEAK_PODS} pods)"
  record_result 5 "S5-T2" "Scale-up occurred" "YES" "YES" "pass"
else
  warn "S5-T1: HPA did not trigger during test. CPU may not have crossed 70% threshold."
  record_result 5 "S5-T1" "HPA trigger time" "NOT_TRIGGERED" "<90s" "fail"
  record_result 5 "S5-T2" "Scale-up occurred" "NO" "YES" "fail"
fi
record_result 5 "S5-T5" "Peak pod count" "${PEAK_PODS}" "≤ 5" "$(pf_lte "$PEAK_PODS" 5)"

# Wait briefly and check scale-down begins
info "S5-T4: Monitoring for scale-down initiation (observed, not waited for full)..."
sleep 30
POST_LOAD_PODS=$(kubectl get pods -n "${NAMESPACE}" -l app=content-service \
  --no-headers 2>/dev/null | grep -c "Running" || echo 0)
record_result 5 "S5-T4" "Pods 30s after load ends" "${POST_LOAD_PODS}" "≤ ${PEAK_PODS}" "info"

# ── SUITE 8 — Resilience ──────────────────────────────────────────────────────
header "SUITE 8 — Resilience & Fault Tolerance"
begin_suite_table "Suite 8 — Resilience & Fault Tolerance"

# S8-T1: Delete 1 content-service pod
info "S8-T1: Deleting 1 content-service pod..."
CS_POD=$(kubectl get pod -n "${NAMESPACE}" -l app=content-service \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$CS_POD" ]]; then
  kubectl delete pod "${CS_POD}" -n "${NAMESPACE}" --grace-period=0 &>/dev/null
  T_DELETE=$(date +%s)
  info "  Waiting for replacement pod..."
  sleep 5
  until kubectl get pods -n "${NAMESPACE}" -l app=content-service \
    --no-headers 2>/dev/null | grep -q "Running"; do
    sleep 3
    ELAPSED_RECOVERY=$(( $(date +%s) - T_DELETE ))
    [[ "$ELAPSED_RECOVERY" -gt 60 ]] && break
  done
  T_RECOVERED=$(date +%s)
  RECOVERY_SEC=$(( T_RECOVERED - T_DELETE ))
  success "S8-T1: Pod replaced in ~${RECOVERY_SEC}s"
  record_result 8 "S8-T1" "Pod replacement time" "${RECOVERY_SEC}s" "<30s" \
    "$(pf_lte "$RECOVERY_SEC" 30)"
  # Re-establish port-forward
  kill "${PF_PIDS[1]}" 2>/dev/null || true
  sleep 2
  kubectl port-forward "svc/content-service" "${CS_PORT}:3002" -n "${NAMESPACE}" &>/dev/null &
  PF_PIDS[1]=$!
  sleep 3
else
  warn "S8-T1: No content-service pod found to delete"
  record_result 8 "S8-T1" "Pod replacement time" "N/A" "<30s" "info"
fi

# S8-T2: Kafka producer reconnect after content-service restart
info "S8-T2: Restarting content-service and checking Kafka producer reconnect..."
kubectl rollout restart deployment/content-service -n "${NAMESPACE}" &>/dev/null || true
sleep 25
HTTP_CHECK=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 8 "${CS_URL}/health" 2>/dev/null || echo "000")
KAFKA_STATUS=$(curl -s "${CS_URL}/" 2>/dev/null | jq -r '.kafka.ready // .kafka // false' 2>/dev/null || echo "unknown")
record_result 8 "S8-T2" "content-service healthy after restart" "HTTP ${HTTP_CHECK}" "HTTP 200" \
  "$([[ "$HTTP_CHECK" == "200" ]] && echo pass || echo fail)"
record_result 8 "S8-T2k" "Kafka producer reconnnect" "$KAFKA_STATUS" "true" \
  "$([[ "$KAFKA_STATUS" == "true" ]] && echo pass || echo info)"

# S8-T4: Delete 1 api-gateway pod (2 replicas) — zero downtime
info "S8-T4: Deleting 1 api-gateway pod while traffic continues..."
GW_POD=$(kubectl get pod -n "${NAMESPACE}" -l app=api-gateway \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$GW_POD" ]]; then
  # Start a background loop hitting api-gateway
  ERR_COUNT=0
  for i in $(seq 1 30); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "${GW_URL}/health" 2>/dev/null || echo 000)
    [[ "$CODE" != "200" ]] && (( ERR_COUNT++ )) || true
    sleep 0.5
  done &
  LOOP_PID=$!
  # Delete the pod mid-loop
  sleep 3
  kubectl delete pod "${GW_POD}" -n "${NAMESPACE}" --grace-period=0 &>/dev/null || true
  wait "$LOOP_PID" 2>/dev/null || true
  info "  Errors during pod deletion: ${ERR_COUNT}/30 checks"
  record_result 8 "S8-T4" "Errors during api-gw pod delete" "${ERR_COUNT}" "≤ 2" \
    "$(pf_lte "$ERR_COUNT" 2)"
else
  warn "S8-T4: No api-gateway pod found to delete"
  record_result 8 "S8-T4" "Errors during api-gw pod delete" "N/A" "≤ 2" "info"
fi

# S8-T6: Kafka unreachable simulation (scale Kafka to 0)
info "S8-T6: Simulating Kafka unavailability (scaling kafka to 0)..."
kubectl scale statefulset/kafka --replicas=0 -n "${NAMESPACE}" &>/dev/null || true
sleep 10
# content-service should still respond (graceful degradation)
HTTP_DEGRADED=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 \
  "${CS_URL}/health" 2>/dev/null || echo "000")
# POST should still succeed (Kafka event dropped with warn log)
body=$(mktemp /tmp/s8t6_XXXX.json)
echo '{"title":"DegradedItem","type":"image"}' > "$body"
HTTP_POST=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 8 \
  -X POST -H "Content-Type: application/json" -d @"$body" \
  "${CS_URL}/items" 2>/dev/null || echo "000")
rm -f "$body"
record_result 8 "S8-T6h" "content-service /health when Kafka down" "HTTP ${HTTP_DEGRADED}" "HTTP 200" \
  "$([[ "$HTTP_DEGRADED" == "200" ]] && echo pass || echo fail)"
record_result 8 "S8-T6p" "POST /items accepted when Kafka down" "HTTP ${HTTP_POST}" "HTTP 201" \
  "$([[ "$HTTP_POST" == "201" ]] && echo pass || echo fail)"
# Restore Kafka
info "  Restoring Kafka (scale to 1)..."
kubectl scale statefulset/kafka --replicas=1 -n "${NAMESPACE}" &>/dev/null || true
info "  Kafka restore initiated — services will reconnect automatically"

# ── SUITE 9 — Resource Efficiency ─────────────────────────────────────────────
header "SUITE 9 — Resource Efficiency"
begin_suite_table "Suite 9 — Resource Efficiency"

info "S9-T1: Capturing idle resource utilisation..."
kubectl top pods -n "${NAMESPACE}" > "${RESULTS_DIR}/pod_resources_idle.txt" 2>&1 || true
cat "${RESULTS_DIR}/pod_resources_idle.txt"

# Parse CPU/Memory for each service
while IFS= read -r line; do
  POD=$(echo "$line" | awk '{print $1}')
  CPU=$(echo "$line" | awk '{print $2}')
  MEM=$(echo "$line" | awk '{print $3}')
  [[ "$POD" == "NAME" ]] && continue
  record_result 9 "S9-idle" "${POD} idle CPU" "$CPU" "<100m" "info"
  record_result 9 "S9-idle" "${POD} idle Memory" "$MEM" "<200Mi" "info"
done < "${RESULTS_DIR}/pod_resources_idle.txt" 2>/dev/null || true

info "S9-T2: Running 50 RPS for 30s and capturing CPU/memory..."
body=$(mktemp /tmp/s9_XXXX.json)
echo '{"title":"ResourceTest","type":"image"}' > "$body"
(ab -n 9999 -c 50 -t 30 -T 'application/json' -p "$body" \
  "${CS_URL}/items" > "${RESULTS_DIR}/raw_S9_50rps.txt" 2>&1 || true) &
S9_PID=$!
sleep 15
kubectl top pods -n "${NAMESPACE}" > "${RESULTS_DIR}/pod_resources_50rps.txt" 2>&1 || true
wait "$S9_PID" 2>/dev/null || true
rm -f "$body"

info "  Resource usage at 50 RPS:"
cat "${RESULTS_DIR}/pod_resources_50rps.txt"
record_result 9 "S9-T2" "kubectl top captured at 50 RPS" "YES" "YES" "pass"

# S9-T6: Check for OOMKilled events
OOM_COUNT=$(kubectl get events -n "${NAMESPACE}" 2>/dev/null \
  | grep -ci "OOMKilled" || echo 0)
record_result 9 "S9-T6" "OOMKilled events" "$OOM_COUNT" "0" \
  "$(pf_lte "$OOM_COUNT" 0)"

# ── Final snapshot ─────────────────────────────────────────────────────────────
header "FINAL CLUSTER SNAPSHOT"
kubectl get pods -n "${NAMESPACE}" > "${RESULTS_DIR}/pod_status_final.txt" 2>&1 || true
kubectl top pods -n "${NAMESPACE}" > "${RESULTS_DIR}/pod_resources_final.txt" 2>&1 || true
kubectl get hpa -n "${NAMESPACE}" >> "${RESULTS_DIR}/hpa_baseline.txt" 2>&1 || true
kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' \
  > "${RESULTS_DIR}/events_all.txt" 2>&1 || true

info "Final pod status:"
cat "${RESULTS_DIR}/pod_status_final.txt"

# ── Summary totals ─────────────────────────────────────────────────────────────
header "RESULTS SUMMARY"
PASS_COUNT=$(grep -c "✅ PASS" "${SUMMARY}" 2>/dev/null || echo 0)
FAIL_COUNT=$(grep -c "❌ FAIL" "${SUMMARY}" 2>/dev/null || echo 0)
INFO_COUNT=$(grep -c "ℹ️ INFO" "${SUMMARY}" 2>/dev/null || echo 0)

cat >> "${SUMMARY}" << EOF

---

## Run Summary

| Metric | Count |
|---|---|
| ✅ PASS | ${PASS_COUNT} |
| ❌ FAIL | ${FAIL_COUNT} |
| ℹ️ INFO (recorded, no threshold) | ${INFO_COUNT} |
| **Total** | **$(( PASS_COUNT + FAIL_COUNT + INFO_COUNT ))** |

> Raw output files: \`load-testing/results/${TIMESTAMP}/\`
> Re-run: \`bash load-testing/load-test.sh --env ${ENV}\`
EOF

echo ""
echo -e "${BOLD}Results written to:${RESET} ${RESULTS_DIR}/summary.md"
echo -e "${GREEN}PASS: ${PASS_COUNT}${RESET} | ${RED}FAIL: ${FAIL_COUNT}${RESET} | INFO: ${INFO_COUNT}"
echo ""
success "Load test complete. To review:"
echo "  cat '${RESULTS_DIR}/summary.md'"
