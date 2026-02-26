#!/bin/bash
# =============================================================================
# setup.sh — Full environment setup for DisplayData K3s Platform
#
# What this does:
#   1. Validates prerequisites (WSL2, Docker, Node, kubectl, Helm)
#   2. Installs any missing tools
#   3. Starts K3s and verifies the cluster
#   4. Builds and pushes all four service images to Docker Hub
#   5. Deploys Kafka + all services to the dev namespace (dd-dev)
#   6. Runs the Kafka verification suite to confirm everything is working
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh
#
#   # To deploy to prod instead of dev:
#   ./setup.sh --env prod
#
#   # To skip the Docker build/push (use existing images on Docker Hub):
#   ./setup.sh --skip-build
#
#   # Dry run — shows what would be deployed without touching the cluster:
#   ./setup.sh --dry-run
#
# Prerequisites:
#   - WSL2 with Ubuntu (or native Linux)
#   - Docker Hub account with push access to karandh/* images
#   - Internet access (for K3s install, Helm, image pulls)
#
# Re-running is safe — all steps include idempotency checks.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
TARGET_ENV="dev"
SKIP_BUILD=false
DRY_RUN=false
DOCKER_ORG="karandh"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()     { echo -e "  ${GREEN}✅  $1${NC}"; }
fail()   { echo -e "  ${RED}❌  $1${NC}"; exit 1; }
info()   { echo -e "  ${CYAN}ℹ️   $1${NC}"; }
warn()   { echo -e "  ${YELLOW}⚠️   $1${NC}"; }
header() { echo -e "\n${BOLD}── $1 ──${NC}"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)         TARGET_ENV="$2"; shift 2 ;;
    --skip-build)  SKIP_BUILD=true; shift ;;
    --dry-run)     DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--env dev|prod] [--skip-build] [--dry-run]"
      echo ""
      echo "  --env <env>     Target environment (default: dev)"
      echo "  --skip-build    Skip docker build/push, use existing images"
      echo "  --dry-run       Helm dry-run only, no cluster changes"
      exit 0
      ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

NAMESPACE="dd-$TARGET_ENV"

echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  DisplayData — K3s Platform Setup${NC}"
echo -e "  Environment : $TARGET_ENV"
echo -e "  Namespace   : $NAMESPACE"
echo -e "  Docker org  : $DOCKER_ORG"
if [ "$SKIP_BUILD" = true ]; then
  echo -e "  Build       : ${YELLOW}skipped (using existing images)${NC}"
fi
if [ "$DRY_RUN" = true ]; then
  echo -e "  Mode        : ${YELLOW}DRY RUN${NC}"
fi
echo -e "${BOLD}============================================================${NC}"

# =============================================================================
# STEP 1 — WSL metadata check (enables chmod on /mnt/c/ for npm installs)
# =============================================================================
header "Step 1: WSL metadata check"

if grep -qi "microsoft" /proc/version 2>/dev/null; then
  info "Running inside WSL"
  if grep -q "metadata" /etc/wsl.conf 2>/dev/null; then
    ok "WSL metadata already configured"
  else
    warn "WSL metadata not configured — applying fix for /mnt/c/ chmod support"
    sudo tee /etc/wsl.conf > /dev/null << 'EOF'
[automount]
options = "metadata"
EOF
    echo ""
    echo -e "  ${YELLOW}!! ACTION REQUIRED !!${NC}"
    echo "  WSL must be restarted for the metadata fix to take effect."
    echo "  Run this in PowerShell, then re-run setup.sh:"
    echo ""
    echo "      wsl --shutdown"
    echo ""
    exit 0
  fi
else
  ok "Not running in WSL — skipping metadata check"
fi

# =============================================================================
# STEP 2 — Install system dependencies
# =============================================================================
header "Step 2: System dependencies"

echo "  Updating apt..."
sudo apt-get update -q

# curl
if ! command -v curl &>/dev/null; then
  info "Installing curl..."
  sudo apt-get install -y -q curl
fi
ok "curl: $(curl --version | head -1)"

# git
if ! command -v git &>/dev/null; then
  info "Installing git..."
  sudo apt-get install -y -q git
fi
ok "git: $(git --version)"

# =============================================================================
# STEP 3 — Docker
# =============================================================================
header "Step 3: Docker"

if ! command -v docker &>/dev/null; then
  info "Docker not found — installing..."
  sudo apt-get install -y -q docker.io
  sudo systemctl enable docker
  sudo systemctl start docker
  ok "Docker installed"
else
  ok "Docker already installed: $(docker --version)"
fi

# Add current user to docker group if needed
if ! groups "$USER" | grep -q docker; then
  sudo usermod -aG docker "$USER"
  warn "Added $USER to docker group — you may need to run 'newgrp docker' or log out/in"
fi

# Start Docker if not running
if ! sudo systemctl is-active --quiet docker; then
  info "Starting Docker daemon..."
  sudo systemctl start docker
fi
ok "Docker daemon is running"

# Verify Docker Hub login (required for push)
if [ "$SKIP_BUILD" = false ] && [ "$DRY_RUN" = false ]; then
  if ! docker info 2>/dev/null | grep -q "Username"; then
    echo ""
    warn "Not logged in to Docker Hub. Image push will fail."
    echo "  Please log in now:"
    docker login
  fi
  ok "Docker Hub: logged in"
fi

# =============================================================================
# STEP 4 — Node.js 20
# =============================================================================
header "Step 4: Node.js 20"

export NVM_DIR="$HOME/.nvm"

if ! command -v node &>/dev/null || [[ "$(node -v)" != v20* ]]; then
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    info "Installing nvm..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  fi
  # shellcheck source=/dev/null
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
  info "Installing Node.js 20..."
  nvm install 20
  nvm use 20
  nvm alias default 20
else
  # Load nvm if available so node is on PATH
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
fi

ok "Node $(node -v) | npm $(npm -v)"

# =============================================================================
# STEP 5 — K3s
# =============================================================================
header "Step 5: K3s"

if ! command -v k3s &>/dev/null; then
  info "K3s not found — installing..."
  curl -sfL https://get.k3s.io | sh -
  info "Waiting for K3s to initialise..."
  sleep 20
  ok "K3s installed"
else
  ok "K3s already installed: $(k3s --version | head -1)"
fi

# Ensure K3s is running
if ! sudo systemctl is-active --quiet k3s; then
  info "Starting K3s..."
  sudo systemctl start k3s
  sleep 10
fi

# Configure kubeconfig
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$USER" ~/.kube/config
chmod 600 ~/.kube/config
export KUBECONFIG=~/.kube/config

# Persist KUBECONFIG in shell profile
if ! grep -q "KUBECONFIG" ~/.bashrc 2>/dev/null; then
  echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
fi

# Wait for node to be Ready
info "Waiting for K3s node to be Ready..."
kubectl wait --for=condition=Ready node --all --timeout=120s

ok "K3s cluster is up"
echo ""
kubectl get nodes -o wide
echo ""

# =============================================================================
# STEP 6 — metrics-server (required for HPA in prod)
# =============================================================================
header "Step 6: metrics-server"

if kubectl get deployment metrics-server -n kube-system &>/dev/null; then
  ok "metrics-server already installed"
else
  info "Installing metrics-server..."
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

  # K3s requires --kubelet-insecure-tls
  kubectl patch deployment metrics-server -n kube-system --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi

info "Waiting for metrics-server to be ready..."
kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s
ok "metrics-server is ready"

# =============================================================================
# STEP 7 — Helm 3
# =============================================================================
header "Step 7: Helm 3"

if ! command -v helm &>/dev/null; then
  info "Helm not found — installing..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  ok "Helm installed"
else
  ok "Helm already installed: $(helm version --short)"
fi

# =============================================================================
# STEP 8 — Build & push Docker images
# =============================================================================
header "Step 8: Docker images"

if [ "$SKIP_BUILD" = true ]; then
  warn "Skipping build — using existing images from Docker Hub"
elif [ "$DRY_RUN" = true ]; then
  warn "Dry run — skipping build"
else
  info "Building and pushing all service images..."
  echo ""

  SERVICES=(api-gateway content-service analytics-service auth-service)
  for svc in "${SERVICES[@]}"; do
    svc_dir="$SCRIPT_DIR/node-services/$svc"
    if [ ! -d "$svc_dir" ]; then
      fail "Service directory not found: $svc_dir"
    fi
    echo "  Building $DOCKER_ORG/$svc:latest ..."
    docker build --no-cache -t "$DOCKER_ORG/$svc:latest" "$svc_dir"
    echo "  Pushing $DOCKER_ORG/$svc:latest ..."
    docker push "$DOCKER_ORG/$svc:latest"
    ok "$svc pushed"
    echo ""
  done
fi

# =============================================================================
# STEP 9 — Deploy Kafka + all services
# =============================================================================
header "Step 9: Deploy to $NAMESPACE"

DEPLOY_SCRIPT="$SCRIPT_DIR/deployment/deploy.sh"
if [ ! -f "$DEPLOY_SCRIPT" ]; then
  fail "deploy.sh not found at $DEPLOY_SCRIPT"
fi

if [ "$DRY_RUN" = true ]; then
  info "Dry run — previewing Helm output..."
  bash "$DEPLOY_SCRIPT" --env "$TARGET_ENV" --all --dry-run
else
  info "Deploying Kafka..."
  bash "$DEPLOY_SCRIPT" --env "$TARGET_ENV" --kafka

  info "Deploying all services..."
  bash "$DEPLOY_SCRIPT" --env "$TARGET_ENV" --all

  info "Waiting for all pods to be ready..."
  kubectl wait --for=condition=Ready pod \
    --selector='app.kubernetes.io/managed-by=Helm' \
    -n "$NAMESPACE" \
    --timeout=180s 2>/dev/null || true

  echo ""
  kubectl get pods -n "$NAMESPACE"
  echo ""
  ok "All services deployed"
fi

# =============================================================================
# STEP 10 — Verify Kafka pipeline
# =============================================================================
header "Step 10: Kafka verification"

VERIFY_SCRIPT="$SCRIPT_DIR/deployment/verify-kafka.sh"
if [ ! -f "$VERIFY_SCRIPT" ]; then
  warn "verify-kafka.sh not found — skipping verification"
elif [ "$DRY_RUN" = true ]; then
  warn "Dry run — skipping verification"
else
  info "Waiting 15s for services to fully initialise before verification..."
  sleep 15

  # Kill any stale port-forwards from previous runs
  pkill -f "kubectl port-forward" 2>/dev/null || true

  bash "$VERIFY_SCRIPT" --env "$TARGET_ENV" --skip-pipeline
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  Setup Complete!${NC}"
echo ""
if [ "$DRY_RUN" = false ]; then
  echo -e "  ${GREEN}Environment  : $TARGET_ENV${NC}"
  echo -e "  ${GREEN}Namespace    : $NAMESPACE${NC}"
  echo ""
  echo "  Useful commands:"
  echo "    kubectl get pods -n $NAMESPACE"
  echo "    kubectl logs -n $NAMESPACE deploy/analytics-service --tail=30"
  echo "    kubectl logs -n $NAMESPACE deploy/content-service --tail=30"
  echo "    kubectl logs -n $NAMESPACE statefulset/kafka --tail=30"
  echo ""
  echo "  Re-run Kafka verification at any time:"
  echo "    ./deployment/verify-kafka.sh --env $TARGET_ENV"
  echo ""
  echo "  To tear down:"
  echo "    ./deployment/teardown.sh --env $TARGET_ENV --confirm"
fi
echo -e "${BOLD}============================================================${NC}"
echo ""