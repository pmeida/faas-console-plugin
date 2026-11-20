#!/usr/bin/env bash
set -euo pipefail

# Full dev deployment workflow (SRVOCF-1095, operator-based): build the
# plugin image locally, push it to the cluster's internal registry, and
# deploy it through the functions-operator - the same deployment path
# production uses.
#
# The operator itself is never built here: by default it comes from the
# Serverless Functions catalog (the install.yaml pattern), with the dev
# plugin image injected through the Subscription's spec.config.env. The
# plugin image carries its resource definitions under /manifests; the
# operator pulls it in-process and applies them, so iterating on plugin
# resources needs no operator involvement at all. deploy.sh wires up the
# internal-registry pull access and credentials automatically.
#
# To test against an operator carrying unreleased changes, set OPERATOR_IMAGE
# (transitional track, see deploy.sh).
#
# Prerequisites: oc login, podman
# Optional: make setup-serverless (for full Knative/Serverless functionality)
# Usage: make deploy-dev [IMAGE_TAG=...] [NAMESPACE=...] [OPERATOR_IMAGE=...]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/registry.sh"

NAMESPACE="${NAMESPACE:-console-functions-plugin}"
IMAGE_TAG="${IMAGE_TAG:-localhost/faas-console-plugin:latest}"
PLUGIN_NAME="console-functions-plugin"

# --- Prerequisites ---

if ! command -v oc &>/dev/null; then
  log::error "oc CLI not found. Install from https://console.redhat.com/openshift/downloads"
  exit 1
fi

if ! oc whoami &>/dev/null; then
  log::error "Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi

if [ -z "${OCP_VERSION:-}" ]; then
  log::error "OCP_VERSION is not set. Run via 'make deploy-dev'."
  exit 1
fi

if ! command -v podman &>/dev/null; then
  log::error "podman not found."
  exit 1
fi

cluster_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+' || true)
if [ -n "$cluster_version" ] && [ "$cluster_version" != "$OCP_VERSION" ]; then
  log::error "Cluster version (${cluster_version}) is different from plugin compatible target (${OCP_VERSION}). The plugin will not load."
  log::error "Log in to an OCP ${OCP_VERSION} cluster."
  exit 1
fi

oc get namespace "$NAMESPACE" &>/dev/null 2>&1 || oc create namespace "$NAMESPACE"

# --- Build ---

log::step "Building image"
make image IMAGE_TAG="$IMAGE_TAG"

# --- Push to internal registry ---

log::step "Pushing image to internal registry"

registry::port_forward
trap registry::stop_port_forward EXIT

registry::podman_login

PUSH_IMAGE="${REGISTRY_PUSH_TARGET}/${NAMESPACE}/${PLUGIN_NAME}:latest"
DIGEST=$(registry::podman_push "$IMAGE_TAG" "$PUSH_IMAGE")
DEPLOY_IMAGE="${INTERNAL_REGISTRY}/${NAMESPACE}/${PLUGIN_NAME}:latest@${DIGEST}"

registry::stop_port_forward
trap - EXIT

# --- Deploy via the operator ---

IMAGE="${DEPLOY_IMAGE}" \
GH_API_URL="${GH_API_URL:-}" \
OPERATOR_IMAGE="${OPERATOR_IMAGE:-}" \
NAMESPACE="${NAMESPACE}" \
  "${SCRIPT_DIR}/deploy.sh"
