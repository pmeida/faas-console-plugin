#!/usr/bin/env bash
# Shared helpers for enabling the console plugin on the OpenShift console.
# Requires hack/lib/log.sh to be sourced and the oc CLI.

# enable_console_plugin <plugin-name>
# Enables the plugin on the console operator and restarts the console so it
# picks the plugin up. Idempotent.
enable_console_plugin() {
  local plugin="$1"

  local enabled
  enabled=$(oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' 2>/dev/null || true)
  if echo "$enabled" | grep -q "$plugin"; then
    log::info "Plugin ${plugin} already enabled on console."
  else
    log::info "Patching console operator to enable plugin..."
    oc patch consoles.operator.openshift.io cluster \
      --type=json \
      --patch='[{"op":"add","path":"/spec/plugins/-","value":"'"${plugin}"'"}]'
  fi

  log::info "Restarting console pods to pick up plugin changes..."
  oc rollout restart deployment/console -n openshift-console
  oc rollout status deployment/console -n openshift-console --timeout=300s
}
