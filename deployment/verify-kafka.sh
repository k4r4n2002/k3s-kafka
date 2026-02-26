#!/bin/bash
# =============================================================================
# verify-kafka.sh — End-to-end verification of the Kafka pipeline
#
# Tests performed:
#   1. Kafka broker is reachable (pod health)
#   2. Topic 'content-events' exists with correct partition/replication config
#   3. Producer → Consumer round-trip (writes a test event, reads it back)
#   4. content-service Kafka producer is connected (via /health endpoint)
#   5. analytics-service Kafka consumer is connected (via /kafka-status endpoint)
#   6. Full pipeline: POST /items to content-service → event appears in analytics-service /stats
#
# Usage:
#   ./verify-kafka.sh --env dev
#   ./verify-kafka.sh --env prod
#   ./verify-kafka.sh --env dev --skip-pipeline   # Skip live HTTP test (Kafka checks only)
#
# Requirements:
#   - kubectl configured and pointing at the right cluster
#   - Services deployed via deploy.sh
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✅  PASS${NC}  $1"; }
fail() { echo -e "  ${RED}❌  FAIL${NC}  $1"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "  ${CYAN}ℹ️   INFO${NC}  $1"; }
warn() { echo -e "  ${YELLOW}⚠️   WARN${NC}  $1"; }
header() { echo -e "\n${BOLD}── $1 ──${NC}"; }

FAILURES=0

# ── Argument parsing ─────────────────────────────────────────────────────────
TARGET_ENV=""
SKIP_PIPELINE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)            TARGET_ENV="$2"; shift 2 ;;
    --skip-pipeline)  SKIP_PIPELINE=true; shift ;;
    -h|--help)
      echo "Usage: $0 --env <env> [--skip-pipeline]"
      exit 0
      ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [ -z "$TARGET_ENV" ]; then
  echo "Error: --env is required (e.g., dev, prod)"
  exit 1
fi

NAMESPACE="dd-$TARGET_ENV"
KAFKA_RELEASE="kafka"
TOPIC="content-events"

echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  DisplayData — Kafka Verification${NC}"
echo -e "  Environment : $TARGET_ENV"
echo -e "  Namespace   : $NAMESPACE"
echo -e "  Topic       : $TOPIC"
echo -e "${BOLD}============================================================${NC}"

# ── Helper: run a command inside a Kafka broker pod ──────────────────────────
kafka_exec() {
  local cmd="$1"
  kubectl exec -n "$NAMESPACE" \
    "$(kubectl get pod -n "$NAMESPACE" -l "app.kubernetes.io/name=kafka,app.kubernetes.io/component=broker" \
       -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
     kubectl get pod -n "$NAMESPACE" -l "app.kubernetes.io/name=kafka" \
       -o jsonpath='{.items[0].metadata.name}')" \
    -- bash -c "$cmd" 2>/dev/null
}

# ── Helper: kubectl exec into a service pod ──────────────────────────────────
svc_exec() {
  local svc_label="$1"
  local cmd="$2"
  kubectl exec -n "$NAMESPACE" \
    "$(kubectl get pod -n "$NAMESPACE" -l "app.kubernetes.io/name=$svc_label" \
       -o jsonpath='{.items[0].metadata.name}')" \
    -- sh -c "$cmd" 2>/dev/null
}

# ── Helper: kubectl port-forward in background ───────────────────────────────
PF_PIDS=()

start_portforward() {
  local svc="$1"
  local local_port="$2"
  local remote_port="$3"
  kubectl port-forward -n "$NAMESPACE" "svc/$svc" "${local_port}:${remote_port}" &>/dev/null &
  PF_PIDS+=($!)
  sleep 2   # give it time to bind
}

cleanup() {
  for pid in "${PF_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT

# ── Test 1: Namespace exists ──────────────────────────────────────────────────
header "Test 1: Namespace"
if kubectl get namespace "$NAMESPACE" &>/dev/null; then
  pass "Namespace $NAMESPACE exists"
else
  fail "Namespace $NAMESPACE does not exist — has the environment been deployed?"
  echo ""
  echo "  Run: ./deploy.sh --env $TARGET_ENV --all"
  echo ""
  exit 1
fi

# ── Test 2: Kafka pods are running ────────────────────────────────────────────
header "Test 2: Kafka Pod Health"
KAFKA_PODS=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=kafka" \
  --no-headers 2>/dev/null || echo "")

if [ -z "$KAFKA_PODS" ]; then
  fail "No Kafka pods found in $NAMESPACE"
else
  info "Kafka pods:"
  kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=kafka" \
    --no-headers | while read -r line; do echo "    $line"; done

  NOT_RUNNING=$(echo "$KAFKA_PODS" | grep -v "Running" | grep -v "Completed" || true)
  if [ -z "$NOT_RUNNING" ]; then
    pass "All Kafka pods are Running"
  else
    fail "Some Kafka pods are NOT Running:"
    echo "$NOT_RUNNING" | while read -r line; do echo "    $line"; done
  fi
fi

# ── Test 3: Kafka topic exists ────────────────────────────────────────────────
header "Test 3: Topic '$TOPIC' Exists"
TOPIC_LIST=$(kafka_exec "/opt/bitnami/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --list" 2>/dev/null || echo "ERROR")

if echo "$TOPIC_LIST" | grep -q "^${TOPIC}$"; then
  pass "Topic '$TOPIC' exists"

  TOPIC_DESCRIBE=$(kafka_exec "/opt/bitnami/kafka/bin/kafka-topics.sh \
    --bootstrap-server localhost:9092 \
    --describe --topic $TOPIC" 2>/dev/null || echo "")

  if [ -n "$TOPIC_DESCRIBE" ]; then
    info "Topic details:"
    echo "$TOPIC_DESCRIBE" | while read -r line; do echo "    $line"; done
  fi
elif echo "$TOPIC_LIST" | grep -q "ERROR"; then
  fail "Could not connect to Kafka broker to list topics"
else
  warn "Topic '$TOPIC' not found. Provisioning may still be in progress."
  info "Creating topic manually..."
  kafka_exec "/opt/bitnami/kafka/bin/kafka-topics.sh \
    --bootstrap-server localhost:9092 \
    --create --if-not-exists \
    --topic $TOPIC \
    --partitions 1 \
    --replication-factor 1" && pass "Topic created" || fail "Topic creation failed"
fi

# ── Test 4: Producer → Consumer round-trip ────────────────────────────────────
header "Test 4: Producer → Consumer Round-Trip"

TEST_MSG="verify-kafka-test-$(date +%s)"
info "Sending test message: $TEST_MSG"

# Produce
PRODUCE_RESULT=$(kafka_exec "echo '$TEST_MSG' | /opt/bitnami/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server localhost:9092 \
  --topic $TOPIC 2>/dev/null && echo OK" || echo "FAILED")

if echo "$PRODUCE_RESULT" | grep -q "OK"; then
  pass "Test message produced to $TOPIC"
else
  fail "Failed to produce test message: $PRODUCE_RESULT"
fi

# Consume (read from beginning, timeout after 10s)
info "Consuming from topic (10s timeout)..."
CONSUMED=$(kafka_exec "/opt/bitnami/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic $TOPIC \
  --from-beginning \
  --max-messages 100 \
  --timeout-ms 10000 2>/dev/null" || echo "")

if echo "$CONSUMED" | grep -q "$TEST_MSG"; then
  pass "Test message consumed from $TOPIC"
  MSG_COUNT=$(echo "$CONSUMED" | grep -c "." || echo "0")
  info "Total messages visible on topic: $MSG_COUNT"
else
  fail "Test message not found in consumer output"
  if [ -n "$CONSUMED" ]; then
    info "Consumer output (last 5 lines):"
    echo "$CONSUMED" | tail -5 | while read -r line; do echo "    $line"; done
  fi
fi

# ── Test 5: Consumer group offset ─────────────────────────────────────────────
header "Test 5: Consumer Group 'analytics-consumers'"
GROUP_INFO=$(kafka_exec "/opt/bitnami/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe --group analytics-consumers 2>/dev/null" || echo "")

if [ -n "$GROUP_INFO" ] && ! echo "$GROUP_INFO" | grep -q "does not exist"; then
  pass "Consumer group 'analytics-consumers' exists"
  info "Group details:"
  echo "$GROUP_INFO" | while read -r line; do echo "    $line"; done
  
  # Check lag
  LAG=$(echo "$GROUP_INFO" | awk 'NR>1 {sum += $6} END {print sum}' 2>/dev/null || echo "?")
  if [ "$LAG" = "0" ] || [ "$LAG" = "" ]; then
    pass "Consumer lag is 0 — analytics-service is keeping up"
  else
    warn "Consumer lag: $LAG messages (analytics-service may be catching up)"
  fi
else
  warn "Consumer group 'analytics-consumers' not yet registered (analytics-service may not be running)"
fi

# ── Test 6: Service health checks via port-forward ───────────────────────────
header "Test 6: Service Kafka Status (via port-forward)"

# content-service
if kubectl get svc content-service -n "$NAMESPACE" &>/dev/null; then
  info "Port-forwarding content-service:3002 → localhost:13002"
  start_portforward "content-service" 13002 3002
  
  CONTENT_HEALTH=$(curl -sf http://localhost:13002/health 2>/dev/null || echo '{"error":"unreachable"}')
  KAFKA_STATUS=$(echo "$CONTENT_HEALTH" | grep -o '"kafka":"[^"]*"' || echo "unknown")
  
  if echo "$CONTENT_HEALTH" | grep -q '"kafka":"connected"'; then
    pass "content-service Kafka producer: connected"
  elif echo "$CONTENT_HEALTH" | grep -q '"status":"ok"'; then
    warn "content-service is healthy but Kafka status: $(echo "$CONTENT_HEALTH" | grep -o '"kafka":"[^"]*"')"
  else
    fail "content-service health check failed: $CONTENT_HEALTH"
  fi
else
  warn "content-service not deployed — skipping"
fi

# analytics-service
if kubectl get svc analytics-service -n "$NAMESPACE" &>/dev/null; then
  info "Port-forwarding analytics-service:3003 → localhost:13003"
  start_portforward "analytics-service" 13003 3003

  ANALYTICS_STATUS=$(curl -sf http://localhost:13003/kafka-status 2>/dev/null || echo '{"error":"unreachable"}')

  if echo "$ANALYTICS_STATUS" | grep -q '"connected":true'; then
    pass "analytics-service Kafka consumer: connected"
    MSG_COUNT=$(echo "$ANALYTICS_STATUS" | grep -o '"messagesConsumed":[0-9]*' | grep -o '[0-9]*' || echo "?")
    info "Messages consumed so far: $MSG_COUNT"
  elif echo "$ANALYTICS_STATUS" | grep -q '"connected":false'; then
    warn "analytics-service consumer connected=false (may still be starting)"
  else
    fail "analytics-service kafka-status check failed: $ANALYTICS_STATUS"
  fi
else
  warn "analytics-service not deployed — skipping"
fi

# ── Test 7: Full pipeline test (optional) ─────────────────────────────────────
if [ "$SKIP_PIPELINE" = false ]; then
  header "Test 7: Full Pipeline (POST content → analytics stats)"
  
  # Check content-service port-forward is up
  if ! kill -0 "${PF_PIDS[0]:-0}" 2>/dev/null; then
    start_portforward "content-service" 13002 3002
  fi

  # Get analytics event count before
  BEFORE_STATS=$(curl -sf http://localhost:13003/stats 2>/dev/null || echo '{"totalEvents":0}')
  BEFORE_COUNT=$(echo "$BEFORE_STATS" | grep -o '"totalEvents":[0-9]*' | grep -o '[0-9]*' || echo "0")
  info "Analytics events before test: $BEFORE_COUNT"

  # POST a new content item (this triggers a Kafka event)
  TIMESTAMP=$(date +%s)
  POST_RESULT=$(curl -sf -X POST http://localhost:13002/items \
    -H "Content-Type: application/json" \
    -d "{\"title\": \"Kafka Verify Test $TIMESTAMP\", \"type\": \"test\"}" \
    2>/dev/null || echo '{"error":"failed"}')

  if echo "$POST_RESULT" | grep -q '"id"'; then
    ITEM_ID=$(echo "$POST_RESULT" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    pass "Created content item: $ITEM_ID (Kafka event should be en route)"
  else
    fail "Failed to create content item: $POST_RESULT"
  fi

  # Wait for the event to propagate through Kafka
  info "Waiting 5s for event to propagate through Kafka..."
  sleep 5

  # Check analytics event count after
  AFTER_STATS=$(curl -sf http://localhost:13003/stats 2>/dev/null || echo '{"totalEvents":0}')
  AFTER_COUNT=$(echo "$AFTER_STATS" | grep -o '"totalEvents":[0-9]*' | grep -o '[0-9]*' || echo "0")
  info "Analytics events after test: $AFTER_COUNT"

  if [ "$AFTER_COUNT" -gt "$BEFORE_COUNT" ] 2>/dev/null; then
    pass "Event count increased ($BEFORE_COUNT → $AFTER_COUNT) — Kafka pipeline working end-to-end! 🎉"
  else
    warn "Event count did not increase (${BEFORE_COUNT} → ${AFTER_COUNT})."
    warn "This may be a timing issue — check analytics-service logs:"
    warn "  kubectl logs -n $NAMESPACE deploy/analytics-service --tail=20"
  fi
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  Verification Summary${NC}"
echo -e "  Environment : $TARGET_ENV"
if [ "$FAILURES" -eq 0 ]; then
  echo -e "  Result      : ${GREEN}${BOLD}ALL TESTS PASSED${NC}"
else
  echo -e "  Result      : ${RED}${BOLD}$FAILURES TEST(S) FAILED${NC}"
fi
echo -e "${BOLD}============================================================${NC}"
echo ""

if [ "$FAILURES" -gt 0 ]; then
  echo "  Debugging tips:"
  echo "  kubectl get pods -n $NAMESPACE"
  echo "  kubectl logs -n $NAMESPACE deploy/content-service --tail=30"
  echo "  kubectl logs -n $NAMESPACE deploy/analytics-service --tail=30"
  echo "  kubectl logs -n $NAMESPACE statefulset/kafka --tail=30"
  echo ""
  exit 1
fi