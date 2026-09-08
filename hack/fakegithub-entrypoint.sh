#!/usr/bin/env bash
# Wrapper entrypoint for the fakegithub container.
# Starts a rootful Podman API socket so that act can drive container builds
# (S2I) via the Docker-compatible HTTP API, then execs the fakegithub binary.
# Requires a privileged pod (real UID 0) so that Podman runs in rootful mode.
set -euo pipefail

PODMAN_SOCK="/run/podman/podman.sock"

# Use vfs storage driver - overlayfs inside a container requires fuse-overlayfs
# and is slower to set up. vfs is simpler and works reliably in privileged mode.
mkdir -p /etc/containers
printf '[storage]\ndriver = "vfs"\n' > /etc/containers/storage.conf

# Start Podman API service in the background.
mkdir -p "$(dirname "$PODMAN_SOCK")"
podman system service --time=0 "unix://${PODMAN_SOCK}" &

# Wait for the socket to appear (up to 10 s).
for i in $(seq 1 20); do
  [ -S "$PODMAN_SOCK" ] && break
  sleep 0.5
done
if [ ! -S "$PODMAN_SOCK" ]; then
  echo "fakegithub-entrypoint: podman system service did not start in time" >&2
  exit 1
fi

export DOCKER_HOST="unix://${PODMAN_SOCK}"

exec /usr/local/bin/fakegithub "$@"
