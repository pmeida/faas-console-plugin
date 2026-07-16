#!/usr/bin/env bash

set -euo pipefail

# Parse CLI arguments (all optional, with defaults)
BACKEND_PORT=8080
PLUGIN_PORT=9001
CIDFILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --backend-port) BACKEND_PORT="$2"; shift 2 ;;
    --plugin-port) PLUGIN_PORT="$2"; shift 2 ;;
    --console-port) CONSOLE_PORT="$2"; shift 2 ;;
    --cidfile) CIDFILE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

CONSOLE_IMAGE=${CONSOLE_IMAGE:="quay.io/openshift/origin-console:latest"}
CONSOLE_PORT=${CONSOLE_PORT:-9000}
CONSOLE_IMAGE_PLATFORM=${CONSOLE_IMAGE_PLATFORM:="linux/amd64"}

# Plugin metadata is declared in package.json
PLUGIN_NAME="console-functions-plugin"

echo "Starting local OpenShift console..."

set -a
BRIDGE_USER_AUTH="disabled"
BRIDGE_K8S_MODE="off-cluster"
BRIDGE_K8S_AUTH="bearer-token"
BRIDGE_K8S_MODE_OFF_CLUSTER_SKIP_VERIFY_TLS=true
BRIDGE_K8S_MODE_OFF_CLUSTER_ENDPOINT=$(oc whoami --show-server)
# The monitoring operator is not always installed (e.g. for local OpenShift). Tolerate missing config maps.
set +e
BRIDGE_K8S_MODE_OFF_CLUSTER_THANOS=$(oc -n openshift-config-managed get configmap monitoring-shared-config -o jsonpath='{.data.thanosPublicURL}' 2>/dev/null)
BRIDGE_K8S_MODE_OFF_CLUSTER_ALERTMANAGER=$(oc -n openshift-config-managed get configmap monitoring-shared-config -o jsonpath='{.data.alertmanagerPublicURL}' 2>/dev/null)
set -e
BRIDGE_K8S_AUTH_BEARER_TOKEN=$(oc whoami --show-token 2>/dev/null)
BRIDGE_USER_SETTINGS_LOCATION="localstorage"
BRIDGE_I18N_NAMESPACES="plugin__${PLUGIN_NAME}"

# Don't fail if the cluster doesn't have gitops.
set +e
GITOPS_HOSTNAME=$(oc -n openshift-gitops get route cluster -o jsonpath='{.spec.host}' 2>/dev/null)
set -e
if [ -n "$GITOPS_HOSTNAME" ]; then
    BRIDGE_K8S_MODE_OFF_CLUSTER_GITOPS="https://$GITOPS_HOSTNAME"
fi

echo "API Server: $BRIDGE_K8S_MODE_OFF_CLUSTER_ENDPOINT"
echo "Console Image: $CONSOLE_IMAGE"
echo "Console URL: http://localhost:${CONSOLE_PORT}"
echo "Console Platform: $CONSOLE_IMAGE_PLATFORM"

# Prefer podman if installed. Override with CONTAINER_CMD=docker if needed.
if [ -z "${CONTAINER_CMD:-}" ]; then
    if [ -x "$(command -v podman)" ]; then
        CONTAINER_CMD="podman"
    else
        CONTAINER_CMD="docker"
    fi
fi
if [ "$CONTAINER_CMD" = "podman" ]; then
    PLUGIN_HOST="host.containers.internal"
else
    PLUGIN_HOST="host.docker.internal"
fi
CONTAINER_NETWORK_OPTS="-p ${CONSOLE_PORT}:9000"
if [[ "$BRIDGE_K8S_MODE_OFF_CLUSTER_ENDPOINT" == *"crc.testing"* ]]; then
    if [[ "$CONTAINER_CMD" == "podman" ]] && [[ "$(uname -s)" == "Darwin" ]]; then
        # CRC binds its API to 127.0.0.1 only. Podman containers on macOS
        # run inside a VM and cannot reach the host's loopback. SSH tunnels
        # bridge all directions: -R exposes CRC, plugin, and backend inside
        # the VM; -L makes the console port accessible from the Mac.
        if [[ "$BRIDGE_K8S_MODE_OFF_CLUSTER_ENDPOINT" =~ :([0-9]+) ]]; then
            API_PORT="${BASH_REMATCH[1]}"
        else
            API_PORT="6443"
        fi
        podman machine ssh -- \
            -R "${API_PORT}:127.0.0.1:${API_PORT}" \
            -R "${PLUGIN_PORT}:127.0.0.1:${PLUGIN_PORT}" \
            -R "${BACKEND_PORT}:127.0.0.1:${BACKEND_PORT}" \
            -L "${CONSOLE_PORT}:127.0.0.1:9000" \
            -N &
        SSH_PID=$!
        trap 'pkill -P "$SSH_PID" 2>/dev/null || true; kill "$SSH_PID" 2>/dev/null || true' EXIT
        sleep 1
        if ! kill -0 "$SSH_PID" 2>/dev/null; then
            echo "Error: SSH tunnel to podman VM failed. Is 'podman machine' running?" >&2
            exit 1
        fi
        PLUGIN_HOST="127.0.0.1"
        CONTAINER_NETWORK_OPTS="--network host --add-host api.crc.testing:127.0.0.1"
    else
        CONTAINER_NETWORK_OPTS="${CONTAINER_NETWORK_OPTS} --add-host api.crc.testing:host-gateway"
    fi
fi

BRIDGE_PLUGINS="${PLUGIN_NAME}=http://${PLUGIN_HOST}:${PLUGIN_PORT}"
BRIDGE_PLUGIN_PROXY='{"services":[{"consoleAPIPath":"/api/proxy/plugin/'"${PLUGIN_NAME}"'/backend/","endpoint":"http://'"${PLUGIN_HOST}"':'"${BACKEND_PORT}"'","authorize":false}]}'

# Allow browser to connect to GitHub API (CSP connect-src).
# Production uses ConsolePlugin.spec.contentSecurityPolicy instead.
BRIDGE_CONTENT_SECURITY_POLICY="connect-src=https://api.github.com"

echo "BRIDGE_PLUGINS=$BRIDGE_PLUGINS"
echo "BRIDGE_PLUGIN_PROXY=$BRIDGE_PLUGIN_PROXY"

CIDFILE_OPTS=""
if [ -n "$CIDFILE" ]; then
  CIDFILE_OPTS="--cidfile $CIDFILE"
fi

$CONTAINER_CMD run --pull always --platform $CONSOLE_IMAGE_PLATFORM --rm $CIDFILE_OPTS $CONTAINER_NETWORK_OPTS --env-file <(env | grep ^BRIDGE) $CONSOLE_IMAGE
