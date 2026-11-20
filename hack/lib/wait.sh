#!/usr/bin/env bash
# Shared wait helpers. Requires hack/lib/log.sh to be sourced.

# wait_until <description> <attempts> <interval-seconds> <command...>
# Runs command (quietly) until it succeeds or attempts are exhausted.
# Logs the description on success and on timeout.
wait_until() {
  local desc="$1" attempts="$2" interval="$3"
  shift 3
  local i
  for i in $(seq 1 "$attempts"); do
    if "$@" &>/dev/null; then
      log::info "${desc}"
      return 0
    fi
    if [ "$i" -eq "$attempts" ]; then
      log::error "${desc} did not happen within $((attempts * interval))s."
      return 1
    fi
    sleep "$interval"
  done
}
