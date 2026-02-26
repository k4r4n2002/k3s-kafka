#!/bin/bash
# =============================================================================
# teardown.sh — Remove DisplayData Helm releases and Kubernetes namespaces
#
# Usage:
#   ./teardown.sh --env dev              # Tear down dev (all releases + namespace)
#   ./teardown.sh --env prod             # Tear down prod
#   ./teardown.sh --env dev --service api-gateway   # Remove one release only
#   ./teardown.sh --env dev --kafka      # Remove only Kafka release
#   ./teardown.sh --all-envs             # Tear down EVERYTHING (dev + prod)
#
# What it removes:
#   - All Helm releases in the target namespace (app services + Kafka)
#   - The namespace itself (dd-<env>) including all residual resources
#   - PersistentVolumeClaims left behind by Kafka (which Helm does not delete)
#
# Safety:
#   - Requires explicit --confirm flag for namespace deletion (prevents accidents)
#   - Dry-run mode: --dry-run shows what would be removed without touching anything
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ALL_SERVICES=(api-gateway content-service analytics-service auth-service)
KAFKA_RELEASE_NAME="kafka"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # no colour

# ── Argument parsing ─────────────────────────────────────────────────────────
TARGET_ENV=""
TARGET_SERVICE=""
REMOVE_KAFKA=false
ALL_ENVS=false
CONFIRM=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)        TARGET_ENV="$2"; shift 2 ;;
    --service)    TARGET_SERVICE="$2"; shift 2 ;;
    --kafka)      REMOVE_KAFKA=true; shift ;;
    --all-envs)   ALL_ENVS=true; shift ;;
    --confirm)    CONFIRM=true; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: $0 --env <env> [--service <n> | --kafka] [--confirm] [--dry-run]"
      echo "       $0 --all-envs [--confirm] [--dry-run]"
      echo ""
      echo "Flags:"
      echo "  --env <env>        Target environment (dev, prod)"
      echo "  --service <name>   Remove a single Helm release (skips namespace deletion)"
      echo "  --kafka            Remove only the Kafka Helm release"
      echo "  --all-envs         Remove dd-dev AND dd-prod namespaces"
      echo "  --confirm          Required to actually delete namespaces"
      echo "  --dry-run          Show what would be removed, make no changes"
      echo ""
      echo "Examples:"
      echo "  $0 --env dev --dry-run                  # Preview dev teardown"
      echo "  $0 --env dev --confirm                  # Full dev teardown"
      echo "  $0 --env dev --service analytics-service # Remove one service"
      echo "  $0 --env dev --kafka                    # Remove Kafka release only"
      echo "  $0 --all-envs --confirm                 # Nuke everything"
      exit 0
      ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# Validate
if [ "$ALL_ENVS" = false ] && [ -z "$TARGET_ENV" ]; then
  echo -e "${RED}Error:${NC} --env is required (or use --all-envs)"
  exit 1
fi

# ── Helpers ──────────────────────────────────────────────────────────────────
dryrun_prefix() {
  if [ "$DRY_RUN" = true ]; then echo "[DRY RUN] "; fi
}

helm_uninstall() {
  local release="$1"
  local ns="$2"

  if helm status "$release" -n "$ns" &>/dev/null 2>&1; then
    echo -e "  ${CYAN}$(dryrun_prefix)Uninstalling Helm release:${NC} $release (namespace: $ns)"
    if [ "$DRY_RUN" = false ]; then
      helm uninstall "$release" -n "$ns" --wait --timeout 120s || \
        echo -e "  ${YELLOW}Warning:${NC} helm uninstall $release returned non-zero (may already be gone)"
    fi
  else
    echo -e "  ${YELLOW}Skipping:${NC} release '$release' not found in namespace '$ns'"
  fi
}

delete_pvcs() {
  local ns="$1"
  local label_selector="${2:-app.kubernetes.io/name=kafka}"
  local pvcs
  pvcs=$(kubectl get pvc -n "$ns" -l "$label_selector" -o name 2>/dev/null || true)
  if [ -n "$pvcs" ]; then
    echo -e "  ${CYAN}$(dryrun_prefix)Deleting PVCs in $ns (Kafka leaves these behind):${NC}"
    echo "$pvcs" | while read -r pvc; do
      echo "    $pvc"
      if [ "$DRY_RUN" = false ]; then
        kubectl delete "$pvc" -n "$ns" --ignore-not-found
      fi
    done
  else
    echo "  No Kafka PVCs found in $ns"
  fi
}

delete_namespace() {
  local ns="$1"

  if ! kubectl get namespace "$ns" &>/dev/null 2>&1; then
    echo -e "  ${YELLOW}Namespace $ns does not exist — nothing to delete${NC}"
    return
  fi

  if [ "$CONFIRM" = false ] && [ "$DRY_RUN" = false ]; then
    echo -e "  ${YELLOW}⚠️  Namespace deletion requires --confirm flag. Skipping namespace deletion.${NC}"
    echo -e "  Re-run with --confirm to fully remove the namespace."
    return
  fi

  echo -e "  ${RED}$(dryrun_prefix)Deleting namespace:${NC} $ns"
  if [ "$DRY_RUN" = false ]; then
    kubectl delete namespace "$ns" --ignore-not-found --wait=true --timeout=120s || \
      echo -e "  ${YELLOW}Warning:${NC} namespace deletion timed out — may still be terminating"
  fi
}

# ── Teardown a single environment ────────────────────────────────────────────
teardown_env() {
  local env="$1"
  local ns="dd-$env"

  echo ""
  echo "============================================================"
  echo -e "  ${RED}Tearing down environment:${NC} $env  (namespace: $ns)"
  if [ "$DRY_RUN" = true ]; then
    echo -e "  ${YELLOW}DRY RUN — no changes will be made${NC}"
  fi
  echo "============================================================"
  echo ""

  # ── Single release removal modes ─────────────────────────────────────────
  if [ -n "$TARGET_SERVICE" ]; then
    echo "  Mode: single service removal"
    helm_uninstall "$TARGET_SERVICE" "$ns"
    echo ""
    echo -e "  ${GREEN}Done.${NC} Namespace $ns was NOT deleted (single-service mode)."
    return
  fi

  if [ "$REMOVE_KAFKA" = true ]; then
    echo "  Mode: Kafka-only removal"
    delete_pvcs "$ns"
    helm_uninstall "$KAFKA_RELEASE_NAME" "$ns"
    echo ""
    echo -e "  ${GREEN}Done.${NC} Namespace $ns was NOT deleted (kafka-only mode)."
    return
  fi

  # ── Full environment teardown ─────────────────────────────────────────────
  echo "  Mode: full environment teardown"
  echo ""

  # Uninstall app services first (reverse order — gateway last)
  echo "  [1/3] Removing app service Helm releases..."
  for svc in "${ALL_SERVICES[@]}"; do
    helm_uninstall "$svc" "$ns"
  done

  # Delete Kafka PVCs before uninstalling (Helm won't touch them)
  echo ""
  echo "  [2/3] Cleaning up Kafka PVCs..."
  delete_pvcs "$ns"

  # Uninstall Kafka
  helm_uninstall "$KAFKA_RELEASE_NAME" "$ns"

  # Delete namespace (contains any orphaned ConfigMaps, Secrets, etc.)
  echo ""
  echo "  [3/3] Deleting namespace $ns..."
  delete_namespace "$ns"

  echo ""
  if [ "$DRY_RUN" = true ]; then
    echo -e "  ${YELLOW}Dry run complete. No changes made.${NC}"
  else
    echo -e "  ${GREEN}✅  Environment '$env' teardown complete.${NC}"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  DisplayData — Teardown"
if [ "$ALL_ENVS" = true ]; then
  echo "  Scope : ALL ENVIRONMENTS (dev + prod)"
else
  echo "  Scope : $TARGET_ENV"
fi
if [ "$DRY_RUN" = true ]; then
  echo -e "  ${YELLOW}Mode  : DRY RUN${NC}"
fi
echo "============================================================"

if [ "$ALL_ENVS" = true ]; then
  teardown_env "dev"
  teardown_env "prod"
else
  teardown_env "$TARGET_ENV"
fi

echo ""
echo "============================================================"
if [ "$DRY_RUN" = true ]; then
  echo "  Dry run finished. Run without --dry-run to apply."
else
  echo "  Teardown finished."
  if [ "$CONFIRM" = false ] && [ -z "$TARGET_SERVICE" ] && [ "$REMOVE_KAFKA" = false ]; then
    echo ""
    echo -e "  ${YELLOW}Note: Namespaces were not deleted.${NC}"
    echo "  Re-run with --confirm to fully remove namespaces."
  fi
fi
echo "============================================================"
echo ""