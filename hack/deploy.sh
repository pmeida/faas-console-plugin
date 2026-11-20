#!/usr/bin/env bash
set -euo pipefail

# Deploy the console plugin to an OpenShift cluster through the
# functions-operator (SRVOCF-1095), using the install.yaml pattern: the
# operator comes from the Serverless Functions catalog (CatalogSource +
# Subscription) and the plugin image is injected through the Subscription's
# spec.config.env, which OLM pipes into the operator Deployment env.
#
# The plugin image carries its resource definitions under /manifests; the
# operator pulls it in-process and applies them. No operator build or
# rebuild is involved: deploying a new plugin image is just a new value for
# CONSOLE_PLUGIN_IMAGE.
#
# OPERATOR_IMAGE (optional, transitional): use a specific operator image -
# e.g. built from a functions-operator branch - instead of the catalog's.
# The Subscription itself cannot override the operator image (spec.config
# covers env vars and volumes only), so the image is patched onto the
# installed CSV, which OLM renders the operator Deployment from. Everything
# else (RBAC, CRDs, lifecycle, env injection) still comes from the catalog.
# Only needed while testing operator changes that the FBC does not carry
# yet; the catalog is not polled in this mode so it cannot overwrite the
# patch mid-run.
#
# Images in the cluster's internal registry get the extra wiring they need
# automatically: pull access for the operator namespace's ServiceAccounts
# and, for the plugin image, a dockerconfigjson secret the operator uses
# for its in-process pull.
#
# Usage: make deploy [IMAGE=...] [GH_API_URL=...] [OPERATOR_IMAGE=...]
# Without IMAGE the operator deploys the plugin image pinned in its CSV
# (the production default, injected at bundle build time); with IMAGE that
# image is injected instead.
# Prerequisites: oc login

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/console.sh"
source "${SCRIPT_DIR}/lib/registry.sh"
source "${SCRIPT_DIR}/lib/wait.sh"

PLUGIN_NAME="${PLUGIN_NAME:-console-functions-plugin}"
SUBSCRIPTION_NAME="serverless-functions"
CATALOGSOURCE_NAME="serverless-functions-catalog"
OPERATOR_NAMESPACE="openshift-operators"
REGISTRY_PULL_SECRET="plugin-registry-auth"
IMAGE="${IMAGE:-}"
GH_API_URL="${GH_API_URL:-}"
OPERATOR_IMAGE="${OPERATOR_IMAGE:-}"
INSECURE="${CONSOLE_PLUGIN_MANIFESTS_INSECURE:-}"
PULL_SECRET="${CONSOLE_PLUGIN_MANIFESTS_PULL_SECRET:-}"

# --- Prerequisites ---

if ! command -v oc &>/dev/null; then
  log::error "oc CLI not found. Install from https://console.redhat.com/openshift/downloads"
  exit 1
fi

if ! oc whoami &>/dev/null; then
  log::error "Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi

if [ -n "${OPERATOR_IMAGE}" ]; then
  log::step "Deploying plugin via the functions-operator (transitional: operator image ${OPERATOR_IMAGE})"
else
  log::step "Deploying plugin via the functions-operator (OLM, plugin image injected)"
fi

# --- Internal-registry wiring ---

# Namespaces whose images the operator namespace's ServiceAccounts must be
# able to pull (plugin pods, and the operator pods when OPERATOR_IMAGE is
# internal too).
GRANT_NAMESPACES=()
if [[ "${IMAGE}" == "${INTERNAL_REGISTRY}"* ]]; then
  GRANT_NAMESPACES+=("$(echo "${IMAGE#${INTERNAL_REGISTRY}/}" | cut -d/ -f1)")

  # The operator's in-process pull of the plugin image needs credentials
  # (the registry requires them) and to skip TLS verification (its
  # certificate is signed by the service CA).
  AUTH=$(printf 'unused:%s' "$(oc whoami -t)" | base64 | tr -d '\n')
  cat <<EOF | oc apply -f - >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: ${REGISTRY_PULL_SECRET}
  namespace: ${OPERATOR_NAMESPACE}
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: '{"auths":{"${INTERNAL_REGISTRY}":{"auth":"${AUTH}"}}}'
EOF
  INSECURE="${INSECURE:-true}"
  PULL_SECRET="${PULL_SECRET:-${REGISTRY_PULL_SECRET}}"
fi
if [[ "${OPERATOR_IMAGE}" == "${INTERNAL_REGISTRY}"* ]]; then
  GRANT_NAMESPACES+=("$(echo "${OPERATOR_IMAGE#${INTERNAL_REGISTRY}/}" | cut -d/ -f1)")
fi
for ns in $(printf '%s\n' "${GRANT_NAMESPACES[@]:-}" | sort -u); do
  [ -z "$ns" ] && continue
  log::info "Granting ${OPERATOR_NAMESPACE} ServiceAccounts pull access to ${ns} images"
  oc policy add-role-to-group system:image-puller \
    "system:serviceaccounts:${OPERATOR_NAMESPACE}" -n "$ns"
done

# --- Operator env entries for the image-manifests path (SRVOCF-1095) ---
# Built without leading indentation and re-indented per consumer. Without
# IMAGE, CONSOLE_PLUGIN_IMAGE is left unset and the operator deploys the
# plugin image pinned in its CSV; the image-manifests path itself is the
# operator's default and needs no flag.

ENV_ENTRIES=""
add_env() {
  ENV_ENTRIES+="${ENV_ENTRIES:+$'\n'}- name: $1"$'\n'"  value: \"$2\""
}
if [ -n "${IMAGE}" ]; then
  add_env CONSOLE_PLUGIN_IMAGE "${IMAGE}"
fi
if [ -n "${GH_API_URL}" ]; then
  add_env GH_API_URL "${GH_API_URL}"
fi
if [ "${INSECURE}" = "true" ]; then
  add_env CONSOLE_PLUGIN_MANIFESTS_INSECURE "true"
fi
if [ -n "${PULL_SECRET}" ]; then
  add_env CONSOLE_PLUGIN_MANIFESTS_PULL_SECRET "${PULL_SECRET}"
fi

# --- Install the operator via OLM ---

# Same CatalogSource + Subscription as install.yaml, plus the env injection.
# In transitional mode the catalog is not polled, so it cannot replace the
# CSV we are about to patch.
REGISTRY_POLL=$( [ -z "${OPERATOR_IMAGE}" ] && echo "  updateStrategy:
    registryPoll:
      interval: \"30m\"" || echo "")
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOGSOURCE_NAME}
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: quay.io/redhat-user-workloads/ocp-serverless-tenant/serverless-functions-fbc-422-ci:latest
  displayName: Serverless Functions
  publisher: Red Hat
${REGISTRY_POLL}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SUBSCRIPTION_NAME}
  namespace: ${OPERATOR_NAMESPACE}
spec:
  channel: candidate-v2
  name: serverless-functions
  source: ${CATALOGSOURCE_NAME}
  sourceNamespace: openshift-marketplace
  config:
    env:
$(echo "${ENV_ENTRIES}" | sed 's/^/    /')
EOF

log::info "Waiting for the operator CSV to install..."
OPERATOR_CSV=""
for i in $(seq 1 60); do
  OPERATOR_CSV=$(oc get subscription "${SUBSCRIPTION_NAME}" \
    -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
  if [ -n "${OPERATOR_CSV}" ]; then
    break
  fi
  if [ "$i" -eq 60 ]; then
    log::error "Subscription did not resolve an installedCSV within 120s."
    oc get catalogsource "${CATALOGSOURCE_NAME}" -n openshift-marketplace -o yaml || true
    oc get subscription "${SUBSCRIPTION_NAME}" -n "${OPERATOR_NAMESPACE}" -o yaml || true
    exit 1
  fi
  sleep 2
done
oc wait --for=condition=Succeeded "csv/${OPERATOR_CSV}" \
  -n "${OPERATOR_NAMESPACE}" --timeout=600s

if [ -n "${OPERATOR_IMAGE}" ]; then
  # Transitional track: swap the operator image on the CSV. OLM renders the
  # operator Deployment from the CSV, so this rolls our build in while the
  # catalog keeps providing everything else.
  log::info "Patching operator image onto ${OPERATOR_CSV}..."
  if ! oc patch "csv/${OPERATOR_CSV}" -n "${OPERATOR_NAMESPACE}" --type=json \
    -p '[{"op":"replace","path":"/spec/install/spec/deployments/0/spec/template/spec/containers/0/image","value":"'"${OPERATOR_IMAGE}"'"}]'; then
    log::error "Could not patch the CSV deployment image. CSV install spec:"
    oc get "csv/${OPERATOR_CSV}" -n "${OPERATOR_NAMESPACE}" \
      -o jsonpath='{.spec.install.spec.deployments}' || true
    exit 1
  fi

  OPERATOR_DEPLOYMENT=$(oc get "csv/${OPERATOR_CSV}" -n "${OPERATOR_NAMESPACE}" \
    -o jsonpath='{.spec.install.spec.deployments[0].name}')
  log::info "Waiting for operator rollout (${OPERATOR_DEPLOYMENT})..."
  oc rollout status "deployment/${OPERATOR_DEPLOYMENT}" \
    -n "${OPERATOR_NAMESPACE}" --timeout=300s
fi

# --- Wait for the operator to reconcile the plugin ---

wait_until "Plugin Deployment found." 30 2 \
  oc get deployment "${PLUGIN_NAME}" -n "${OPERATOR_NAMESPACE}" || {
  log::error "Operator logs:"
  oc logs "deployment/${OPERATOR_CSV}" -n "${OPERATOR_NAMESPACE}" --tail=50 || true
  exit 1
}
oc rollout status "deployment/${PLUGIN_NAME}" -n "${OPERATOR_NAMESPACE}" --timeout=300s

wait_until "ConsolePlugin CR found." 30 2 \
  oc get consoleplugins "${PLUGIN_NAME}"

enable_console_plugin "${PLUGIN_NAME}"

CONSOLE_URL=$(oc get consoles.config.openshift.io cluster -o jsonpath='{.status.consoleURL}')

log::step "Plugin deployed successfully via the operator"
log::link "API" "$CONSOLE_URL/api/proxy/plugin/$PLUGIN_NAME/backend/"
log::link "Console" "$CONSOLE_URL/faas"
log::hint "For full Knative integration: make setup-serverless"
