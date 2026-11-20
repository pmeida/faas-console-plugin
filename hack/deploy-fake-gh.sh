#!/usr/bin/env bash
set -euo pipefail

# Build and deploy the fake GitHub server to an OpenShift cluster using ko.
# The image is built from Go source, pushed to the cluster's internal registry,
# and deployed as a Deployment + Service.
#
# Prerequisites: oc login, ko (go install github.com/ko-build/ko@latest)
# Usage: hack/deploy-fake-gh.sh
# Output (last line): in-cluster service URL for the fake GitHub server

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/registry.sh"

NAMESPACE="${NAMESPACE:-console-functions-plugin}"

# --- Prerequisites ---

if ! command -v oc &>/dev/null; then
  log::error "oc CLI not found. Install from https://console.redhat.com/openshift/downloads"
  exit 1
fi

if ! oc whoami &>/dev/null; then
  log::error "Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi

if ! command -v ko &>/dev/null; then
  log::error "ko not found. Install with: go install github.com/google/ko@latest"
  exit 1
fi

# --- Ensure namespace exists ---

oc get namespace "$NAMESPACE" &>/dev/null 2>&1 || oc create namespace "$NAMESPACE"

# --- Build and push with ko ---

log::step "Pushing fake GitHub image to internal registry"

registry::port_forward
trap registry::stop_port_forward EXIT INT TERM

registry::ko_setup "$NAMESPACE" "fakegithub"
KO_PLATFORM=$(registry::cluster_platforms)

log::info "Building and pushing with ko..."
KO_IMAGE=$(cd "${SCRIPT_DIR}/../backend" && ko build --bare --insecure-registry --platform="${KO_PLATFORM}" ./cmd/fakegithub)

log::info "ko produced: ${KO_IMAGE}"

# Extract the digest from the ko output (localhost:5001/ns/fakegithub@sha256:...)
DIGEST="${KO_IMAGE#*@}"
DEPLOY_IMAGE="${INTERNAL_REGISTRY}/${NAMESPACE}/fakegithub@${DIGEST}"

# Kill port-forward, no longer needed
registry::stop_port_forward
trap - EXIT

# --- Deploy ---

log::step "Deploying fake GitHub server"

log::info "Applying Deployment and Service..."
oc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fakegithub
  labels:
    app: fakegithub
spec:
  replicas: 1
  selector:
    matchLabels:
      app: fakegithub
  template:
    metadata:
      labels:
        app: fakegithub
    spec:
      containers:
        - name: fakegithub
          image: ${DEPLOY_IMAGE}
          args:
            - "--port=8090"
            - "--login=e2e-user"
            - "--pat=placeholder-pat"
          ports:
            - containerPort: 8090
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
---
apiVersion: v1
kind: Service
metadata:
  name: fakegithub
  labels:
    app: fakegithub
spec:
  selector:
    app: fakegithub
  ports:
    - port: 8090
      targetPort: 8090
      protocol: TCP
EOF

log::info "Waiting for rollout..."
oc rollout status deployment/fakegithub -n "$NAMESPACE" --timeout=120s

FAKE_GH_URL="http://fakegithub.${NAMESPACE}.svc:8090"
log::step "Fake GitHub server deployed"
log::link "In-cluster URL" "${FAKE_GH_URL}"

# Output the URL as the last line (for scripted consumption)
echo "${FAKE_GH_URL}"
