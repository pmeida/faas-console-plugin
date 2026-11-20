# Plugin resource manifests

Single source of truth for the console plugin's resource definitions
(SRVOCF-1095, Option B). These files are copied into the plugin image at
`/manifests` by the Dockerfile. The functions-operator pulls that image
in-process, renders the templates, validates the result against an allowlist,
and applies it. This directory is the single source of truth: the Helm
chart is retired and the operator's Go builders are removed - an image
without /manifests fails reconciliation loudly rather than falling back
to built-in definitions.

**The point of this layout:** adding or changing plugin resources, including
new backend flags, is a change in this repo only. The operator is a generic
consumer and does not grow per-feature code.

## Contract with the operator

- `compatibility.yaml` declares `formatVersion`; the operator refuses to
  apply manifests whose format version it does not understand.
- Files are Go `text/template`s. The operator supplies a fixed vocabulary of
  values:
  - `.Namespace`, `.Name`, `.Image`, `.CertSecret` - deployment coordinates.
  - `.APIServerURL`, `.ClusterID` - cluster facts the operator reads from
    the Infrastructure and ClusterVersion CRs.
  - `.Config` - the operator's `controller-config` ConfigMap, verbatim. This
    is the user-facing knob path (OLM populates it from the Subscription's
    `spec.config.env`). Missing keys render as empty strings.
  - `.Env` - a deliberately small allowlist of operator environment
    variables (`GH_API_URL` today), for template fallbacks like
    `{{ or .Config.ghApiUrl .Env.GH_API_URL }}`.
- New flags follow the pattern already in `deployment.yaml`: read the knob
  from `.Config` (with an `.Env` fallback where one exists) and emit the arg
  conditionally. No operator change is needed for a new knob as long as its
  value comes from the config ConfigMap or a static default.
- Only these kinds are accepted: ServiceAccount, Role, RoleBinding, Service,
  ConfigMap, Deployment, ConsolePlugin. A new resource kind is a deliberate
  operator change (allowlist + RBAC), not boilerplate.
- Namespaced resources must target `.Namespace`; ConsolePlugin is
  cluster-scoped.
- The definitions here deliberately mirror the operator's current Go
  builders (`consoleplugin_controller.go`) so switching the operator to this
  source is a no-op behavior change. Resources the retired Helm chart created
  that the operator does not yet manage (service-ca ConfigMap, Thanos args,
  monitoring) migrate here in follow-ups.
