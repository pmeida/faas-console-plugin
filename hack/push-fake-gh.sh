#!/usr/bin/env bash
set -euo pipefail

# Build and push the fakegithub image to the cluster's internal registry.
# Used locally before running builder-run.sh make e2e.
# In CI, ci-operator builds the image and injects FAKEGITHUB_PULL_SPEC instead.
#
# Prerequisites: oc login, podman
# Usage: hack/push-fake-gh.sh
# Output (last line): pull spec to use as FAKEGITHUB_PULL_SPEC

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"

NAMESPACE="${NAMESPACE:-console-functions-plugin}"
REGISTRY_PORT=5001
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"
CONTAINER_CMD="podman"

if ! command -v oc &>/dev/null; then
  log::error "oc CLI not found. Install from https://console.redhat.com/openshift/downloads"
  exit 1
fi

if ! oc whoami &>/dev/null; then
  log::error "Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi

oc get namespace "$NAMESPACE" &>/dev/null 2>&1 || oc create namespace "$NAMESPACE"

ARCHES=$(oc get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}' 2>/dev/null | sort -u || true)
if [[ -z "$ARCHES" ]]; then
  BUILD_PLATFORM="linux/amd64"
  log::warn "Could not detect cluster node architectures, falling back to ${BUILD_PLATFORM}"
else
  BUILD_PLATFORM=$(echo "$ARCHES" | sed 's/^/linux\//' | tr '\n' ',' | sed 's/,$//')
  log::info "Cluster architectures detected: ${BUILD_PLATFORM}"
fi

# On macOS, podman runs in a VM that can't reach localhost, so we bind to all
# interfaces and push via the host's LAN IP. On Linux, localhost works directly.
if [[ "$(uname)" == "Darwin" ]]; then
  PUSH_TARGET=$(ifconfig | awk '/inet / && !/127.0.0.1/ {print $2; exit}')
  if [ -z "$PUSH_TARGET" ]; then
    log::error "Could not determine host IP address."
    exit 1
  fi
  PUSH_TARGET="${PUSH_TARGET}:${REGISTRY_PORT}"
else
  PUSH_TARGET="localhost:${REGISTRY_PORT}"
fi

log::step "Pushing fakegithub image to internal registry"

log::info "Port-forwarding registry to ${PUSH_TARGET}..."
oc port-forward svc/image-registry \
  --address='::' --address='0.0.0.0' \
  "${REGISTRY_PORT}:5000" \
  -n openshift-image-registry &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT INT TERM
sleep 5

LOCAL_IMAGE="${PUSH_TARGET}/${NAMESPACE}/fakegithub:latest"

log::info "Building image..."
"$CONTAINER_CMD" build \
  --platform="${BUILD_PLATFORM}" \
  --file="${ROOT_DIR}/Dockerfile.fakegithub" \
  --tag="${LOCAL_IMAGE}" \
  "${ROOT_DIR}"

log::info "Logging in to internal registry..."
"$CONTAINER_CMD" login "${PUSH_TARGET}" \
  --username unused \
  --password "$(oc create token builder -n "$NAMESPACE")" \
  --tls-verify=false

log::info "Pushing image..."
"$CONTAINER_CMD" push --tls-verify=false "${LOCAL_IMAGE}"

kill $PF_PID 2>/dev/null || true
trap - EXIT

PULL_SPEC="${INTERNAL_REGISTRY}/${NAMESPACE}/fakegithub:latest"
log::step "Done"
log::info "Set FAKEGITHUB_PULL_SPEC=${PULL_SPEC}"

# Output the pull spec as the last line (for scripted consumption)
echo "${PULL_SPEC}"
