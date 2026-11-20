#!/usr/bin/env bash
set -euo pipefail

# Prow e2e test entrypoint (SRVOCF-1095, operator-based): deploys the plugin
# to the ephemeral cluster through the functions-operator and runs Playwright.
#
# Default track: the operator comes from the Serverless Functions catalog
# (the install.yaml pattern) and the PR's plugin image is injected through
# the Subscription's spec.config.env. The operator pulls that image
# in-process and applies the /manifests definitions it carries, so the
# resources under test are exactly the ones in this PR - no operator build,
# no operator bump, one PR. This assumes the catalog's operator already
# supports the image-manifests path, which holds once the operator-side
# change has landed in functions-operator main (the -ci FBC tracks it).
#
# Transitional track (FUNCTIONS_OPERATOR_SOURCE=source): build the operator
# from a git checkout and inject that image instead, for testing plugin
# changes while the operator-side support is still unreleased. Point
# FUNCTIONS_OPERATOR_REPO/REF at the branch carrying it. Not the default
# track.
#
# Called by: make e2e (CI only)
# Prerequisites: ci-operator cluster with PLUGIN_PULL_SPEC injected

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/registry.sh"

ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
INSTALLER_DIR=${INSTALLER_DIR:=${ARTIFACT_DIR}/installer}

# Namespace for the fake GitHub deployment (and, on the transitional track,
# for the operator and plugin). On the default track the operator and plugin
# are managed in openshift-operators.
# Exported so deploy-fake-gh.sh inherits the same value.
export NAMESPACE="${NAMESPACE:-console-functions-plugin}"

OPERATOR_SOURCE="${FUNCTIONS_OPERATOR_SOURCE:-olm}"
FUNCTIONS_OPERATOR_REPO="${FUNCTIONS_OPERATOR_REPO:-https://github.com/openshift/functions-operator.git}"
FUNCTIONS_OPERATOR_REF="${FUNCTIONS_OPERATOR_REF:-main}"
OPERATOR_IMAGE=""

FAKE_GH_PF_PID=""

function copyArtifacts {
  if [ -d "$ARTIFACT_DIR" ]; then
    log::info "Copying artifacts from $(pwd)..."
    cp -r .e2e/results "${ARTIFACT_DIR}/" 2>/dev/null || true
    cp -r .e2e/report "${ARTIFACT_DIR}/" 2>/dev/null || true
  fi
}

function cleanup {
  copyArtifacts
  if [ -n "$FAKE_GH_PF_PID" ]; then
    kill "$FAKE_GH_PF_PID" 2>/dev/null || true
  fi
  oc delete deployment/fakegithub svc/fakegithub -n "${NAMESPACE}" 2>/dev/null || true
}

trap cleanup EXIT

# --- Credentials ---
BRIDGE_KUBEADMIN_PASSWORD="$(cat "${KUBEADMIN_PASSWORD_FILE:-${INSTALLER_DIR}/auth/kubeadmin-password}")"
export BRIDGE_KUBEADMIN_PASSWORD

BRIDGE_BASE_ADDRESS="$(oc get consoles.config.openshift.io cluster -o jsonpath='{.status.consoleURL}')"
export BRIDGE_BASE_ADDRESS

if [[ -z "${PLUGIN_PULL_SPEC:-}" ]]; then
  log::error "PLUGIN_PULL_SPEC is not set. It should be injected by ci-operator as a dependency."
  exit 1
fi

# --- Deploy fake GitHub server ---
log::step "Deploying fake GitHub server"

FAKE_GH_URL=$(hack/deploy-fake-gh.sh | tail -1)
# Injected into the operator as GH_API_URL: the operator renders it into the
# plugin's --gh-api-url argument.
export GH_API_URL="${FAKE_GH_URL}"

# Port-forward fake GH for Playwright admin API access (Playwright runs outside cluster)
oc port-forward svc/fakegithub 8090:8090 -n "${NAMESPACE}" &
FAKE_GH_PF_PID=$!
sleep 3
export FAKE_GITHUB_URL="http://localhost:8090"

# --- Transitional track: build the operator image from source ---

if [ "${OPERATOR_SOURCE}" = "source" ]; then
  log::step "Building functions-operator from ${FUNCTIONS_OPERATOR_REPO}@${FUNCTIONS_OPERATOR_REF} (transitional track)"

  FUNCTIONS_OPERATOR_DIR=$(mktemp -d /tmp/functions-operator.XXXXXX)
  git clone --quiet --depth 1 --branch "${FUNCTIONS_OPERATOR_REF}" \
    "${FUNCTIONS_OPERATOR_REPO}" "${FUNCTIONS_OPERATOR_DIR}"

  # Build with ko and push to the cluster's internal registry, the same
  # mechanism deploy-fake-gh.sh uses.
  oc get namespace "${NAMESPACE}" &>/dev/null || oc create namespace "${NAMESPACE}"

  registry::port_forward

  registry::ko_setup "${NAMESPACE}" "func-operator"
  KO_PLATFORM=$(registry::cluster_platforms)

  log::info "Building and pushing operator image with ko..."
  KO_IMAGE=$(cd "${FUNCTIONS_OPERATOR_DIR}" && \
    ko build --bare --insecure-registry --platform="${KO_PLATFORM}" ./cmd/func-operator)

  registry::stop_port_forward
  OPERATOR_IMAGE="${INTERNAL_REGISTRY}/${NAMESPACE}/func-operator@${KO_IMAGE#*@}"
fi

# --- Deploy plugin via the functions-operator ---

log::step "Deploying plugin via the functions-operator"

# The CI registry serves the plugin image anonymously and the cluster pulls
# it with its global pull secret, so no registry credentials are needed
# here - unlike the internal-registry dev flow (see deploy-dev.sh).
IMAGE="${PLUGIN_PULL_SPEC}" \
GH_API_URL="${GH_API_URL}" \
OPERATOR_IMAGE="${OPERATOR_IMAGE}" \
NAMESPACE="${NAMESPACE}" \
  "${SCRIPT_DIR}/deploy.sh"

# --- Install deps and run tests ---
log::step "Running e2e tests"

log::info "Installing dependencies..."
make install-frontend

log::info "Installing Playwright browsers..."
npx playwright install chromium

export CLUSTER_ID=$(oc get clusterversion version -o jsonpath='{.spec.clusterID}')

log::info "Running Playwright e2e tests..."
make test-e2e
