#!/usr/bin/env bash
# Shared helpers for pushing images to the OpenShift internal registry.
# Requires hack/lib/log.sh to be sourced and the oc CLI.

# In-cluster address of the integrated registry.
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"

# Local port the registry is forwarded to.
REGISTRY_PORT="${REGISTRY_PORT:-5001}"

# registry::port_forward starts a port-forward to the internal registry.
#
# On macOS, podman runs in a VM that cannot reach localhost, so the forward
# is bound to all interfaces and pushes go via the host's LAN IP; ko and
# other host-native tools use localhost. Sets REGISTRY_PF_PID,
# REGISTRY_LOCAL_TARGET and REGISTRY_PUSH_TARGET.
registry::port_forward() {
  if [[ "$(uname)" == "Darwin" ]]; then
    local host_ip
    host_ip=$(ifconfig | awk '/inet / && !/127.0.0.1/ {print $2; exit}')
    if [ -z "$host_ip" ]; then
      log::error "Could not determine host IP address."
      return 1
    fi
    REGISTRY_PUSH_TARGET="${host_ip}:${REGISTRY_PORT}"
  else
    REGISTRY_PUSH_TARGET="localhost:${REGISTRY_PORT}"
  fi
  REGISTRY_LOCAL_TARGET="localhost:${REGISTRY_PORT}"

  log::info "Port-forwarding registry to ${REGISTRY_PUSH_TARGET}..."
  oc port-forward svc/image-registry \
    --address='::' --address='0.0.0.0' \
    "${REGISTRY_PORT}:5000" \
    -n openshift-image-registry &
  REGISTRY_PF_PID=$!
  sleep 5
}

registry::stop_port_forward() {
  if [ -n "${REGISTRY_PF_PID:-}" ]; then
    kill "$REGISTRY_PF_PID" 2>/dev/null || true
  fi
}

# registry::podman_login logs podman in to the port-forwarded registry with
# the current oc session's token.
registry::podman_login() {
  podman login "$REGISTRY_PUSH_TARGET" \
    -u unused -p "$(oc whoami -t)" --tls-verify=false
}

# registry::podman_push <local-image> <remote-image> tags and pushes with
# podman, echoing the pushed digest.
registry::podman_push() {
  local local_image="$1" remote_image="$2"
  podman tag "$local_image" "$remote_image"
  local digest_file
  digest_file=$(mktemp /tmp/image-digest.XXXXXX)
  log::info "Pushing ${remote_image}..."
  podman push "$remote_image" --tls-verify=false --digestfile "$digest_file"
  local digest
  digest=$(cat "$digest_file")
  rm -f "$digest_file"
  echo "$digest"
}

# registry::ko_setup <namespace> <image-name> logs ko in to the
# port-forwarded registry (builder token) and exports the ko configuration
# for pushing <image-name> into <namespace>.
registry::ko_setup() {
  local namespace="$1" image_name="$2"
  ko login "$REGISTRY_LOCAL_TARGET" \
    -u unused -p "$(oc create token builder -n "$namespace")"
  export KO_DOCKER_REPO="${REGISTRY_LOCAL_TARGET}/${namespace}/${image_name}"
  export KO_DEFAULTBASEIMAGE="registry.access.redhat.com/ubi9/ubi-micro:latest"
  export GOFLAGS="${GOFLAGS:-} -buildvcs=false"
}

# registry::cluster_platforms echoes the cluster's node architectures as a
# comma-separated linux/<arch> list for ko/podman --platform.
registry::cluster_platforms() {
  local arches
  arches=$(oc get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}' 2>/dev/null | sort -u || true)
  if [ -z "$arches" ]; then
    log::warn "Could not detect cluster node architectures, falling back to linux/amd64"
    echo "linux/amd64"
    return
  fi
  echo "$arches" | sed 's/^/linux\//' | paste -sd,
}
