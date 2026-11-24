# Agent Substrate: Ownership Investigation and Recommendation

**Status:** DRAFT for team decision
**Prepared:** 2026-11-23 (Mon)
**Decision deadline:** Wed 2026-11-25 EOB (answer to Finn; be honest about if we are comfortable; Mike from upper management is involved)
**Audience:** Functions + Console Plugin team, then  Finn, Mike
**Scope of ask (from the PM call):** Does Functions + Plugin want to take ownership of **upstream Agent Substrate**, the way we took on KEDA? Own it "as-is" (no new features on day zero), accept RFEs from the OCP AI team (prioritized over console plugin initially), and tell Finn our team-structure requirements.

> This document is decision support. The "do we feel comfortable owning it" judgment and the Finn conversation are the team's, not this document's. Claims are marked **[verified]** (checked against the live cluster, the repo, or primary sources today) or **[needs confirmation]** (reasoned, not yet proven). See the Evidence log at the end.

---

## 1. Executive summary and preliminary recommendation

Agent Substrate is a six-month-old, Google-founded, CNCF Sandbox runtime for running **large numbers of sandboxed AI agents on Kubernetes at ~10x density**, by suspending idle agents to tiered storage and resuming them on a shared worker pool in under 500ms. It just hit v1.0, it is extremely active, and the orchestration layer above it (kagent) is **moving its entire runtime onto Substrate**. The strategic momentum is real.

But the ownership proposition has three hard edges the evidence makes unavoidable:

1. **Maintenance surface is large for "support as-is."** ~105k lines of implementation Go (approx; ~155k physical across 727 files), plus a large ~197k-line test suite, across ~274 packages and 14 binaries, 249 vendored modules, and a ~615-issue / ~371-PR open backlog on a 6-month project, weekly releases, and breaking changes openly expected. The stack is deep systems work: gVisor, Cloud Hypervisor microVMs, an Envoy data plane, nftables/netns networking, a Postgres control-plane datastore, OpenFGA authorization, SPIFFE/pod-certificate identity, and S3/GCS snapshot storage. This is broader and deeper than KEDA.

2. **It does not cleanly run on OpenShift today.** OCP 4.22 is Kubernetes 1.35; OCP 5.0 is 1.36. Substrate's homepage floor is 1.37, and it requires alpha/beta API features (`ClusterTrustBundle`, `PodCertificateRequest`, `certificates.k8s.io/v1beta1`) that are off by default and that OpenShift does not let you toggle individually (and managed ROSA/OSD does not let you toggle at all). Substrate's isolation is gVisor-first; OCP's supported sandbox runtime is Kata.

3. **It overlaps an existing Red Hat bet.** Red Hat already productizes **`kubernetes-sigs/agent-sandbox`** as the "Red Hat build of Agent Sandbox" (Kata microVMs, tech preview in OCP 5). Owning Google's Substrate (a different, gVisor-based, higher-density runtime for the same problem) is a **second bet in the same layer** unless there is an explicit strategy (Substrate as the density/scheduling tier above Kata isolation, or Substrate superseding Agent Sandbox). That strategy is not stated in the call notes.

**Preliminary lean (team's to accept or reject): a qualified "yes, but not an unconditional commitment this week."** The team is a good technical fit (Go, controllers, KEDA upstream experience, Knative/serverless suspend-resume adjacency) and the upside is strategically large. But committing to *sole* ownership by Wednesday is premature until Mike/Finn answer three things: (a) the Agent Sandbox overlap/strategy, (b) guaranteed capacity plus an embedded PM (the "not another PIXAA" condition), and (c) a realistic scope, because "no new features" is not credible alongside "RFEs from the OCP AI team, prioritized over frontend." If those are answered well, a yes is defensible. If they cannot be, we should say so now, exactly as Mike asked.

---

## 2. What Agent Substrate is

**The problem.** An AI agent executes untrusted, model-generated code and tool calls, so it must be isolated from host and network. But agents are idle 90-95% of the time (waiting on a model, a tool, or a human) while holding live state (RAM, filesystem, git checkouts, tool sessions). Standard Kubernetes forces a bad trade: a warm pod per agent (pay for idle compute) or scale-to-zero (20s+ cold starts). And scheduling thousands of short-lived agent pods overwhelms etcd and the API server. **[verified, primary source: Google OSS blog]**

**The design.** Substrate adds an actor/worker control and data plane on top of Kubernetes:

- **Actor** = one agent session's state (filesystem, env, memory, network rules), grouped in an **Atespace**, created from an **ActorTemplate**.
- **Worker** = a pre-warmed pod in a **WorkerPool** that provides compute.
- **atenet-router** parks the incoming request, the controller places the actor on a warm worker, state restores from tiered storage in <500ms, and snapshots back when idle. 10-30x oversubscription, 500+ activations/sec. **[verified]**
- **Isolation:** every actor runs in its own **gVisor (runsc)** or **Cloud Hypervisor microVM** sandbox. Plain containers are not supported. gVisor runs *nested inside* worker pods (via an in-pod `runsc` checkpoint/restore helper), so no node-level RuntimeClass is required, which is why it runs on "any conformant Kubernetes." **[verified, repo]**
- **Security:** per-actor SPIFFE X.509 identity, zero credentials inside the sandbox (an egress gateway injects them outside the sandbox), default-deny networking, pluggable egress policy. **[verified, repo README/security docs]**
- **Framework-agnostic:** an actor is just an OCI image (Claude Code, Codex, LangChain, ADK, Hermes, MCP servers). **[verified]**

**Components (14 binaries):** `ateapi` (gRPC control plane), `atecontroller` (WorkerPool reconciler), `atelet` (node DaemonSet, snapshotting), `atenet` (Envoy routing + proxy sidecars + egress), `ate-idp-server` (actor-JWT OpenID issuer), `ateworker-gvisor` / `ateworker-microvm` (in-pod sandbox helpers), `podcertcontroller` (Pod Certificate polyfill), `credential-provider`, `objectstore-plugin`, `dataplane`, `kubectl-ate` (CLI), `ate-setup` (installer), `benchmarking`. **[verified]**

---

## 3. Strategic landscape (the part that most affects the decision)

The agentic-infra stack is layered, and there are **competing projects at the isolation/runtime layer**:

```
Orchestration / harness   kagent (CNCF), Google Agent Executor (google/ax)
        |
Agent runtime / density   Agent Substrate  (Google/CNCF)   <-- the ask
        |                        vs
Isolation primitive       kubernetes-sigs/agent-sandbox (SIG)  --> "Red Hat build of Agent Sandbox" (Kata)
        |
Kubernetes                nodes, autoscaling, NetworkPolicies
```

- **kagent** (★4.5k, CNCF Sandbox) is the orchestration layer and is **migrating its runtime fully onto Agent Substrate** (via a `SandboxAgent` CRD; legacy Deployment runtime kept on `release/v0.10.x`). This is the clearest adoption signal Substrate has: the leading K8s agent framework is betting its runtime on it. **[verified, kagent blog]**
- **Google Agent Executor (`google/ax`, ★14.9k)** is Google's distributed agent runtime built on Substrate. **[verified]**
- **Other consumers named by primary sources:** Nous Research (Hermes), VMware vSphere Kubernetes Service, GKE (optimized install). **[verified via vendor blogs; depth of production use not independently confirmed]**

**The Red Hat overlap.** OpenShift 5 GA'd on 2026-11-09 with an agentic story: OpenShift Lightspeed (supervised agentic ops GA; autonomous troubleshooting + update agent in tech preview), an OpenShift MCP server + MCP gateway (GA), confidential containers, and the **"Red Hat build of Agent Sandbox" (tech preview)**, which "uses OpenShift sandboxed containers to place agent workloads inside VMs." **[verified, Red Hat / unite.ai coverage]** The upstream is almost certainly `kubernetes-sigs/agent-sandbox` **[needs confirmation]**.

So Red Hat has already chosen a **Kata-based, SIG-governed** agent isolation story. This proposal asks us to own a **gVisor-based, Google/CNCF, higher-density** runtime for an overlapping problem. The two can be framed as complementary (Agent Sandbox = isolation primitive; Substrate = density/scheduling tier above it) or as competing bets. **Which one Red Hat intends is the single most important open question for Mike** (see Section 9).

---

## 4. Adoption and community health

| Repo | Role | Created | Stars | Forks | Contributors | Commits/30d | Open issues / PRs | Latest |
|---|---|---|---|---|---|---|---|---|
| `agent-substrate/substrate` | runtime (this) | 2026-05-13 | 8,211 | 907 | 133 | 200 | **615 / 371** | v1.0.1 (Nov 20) |
| `kagent-dev/kagent` | orchestration above it | 2025-01-21 | 4,501 | 937 | 226 | 148 | 162 / 140 | v1.0.1 |
| `google/ax` (Agent Executor) | runtime on it | 2026-03-30 | 14,860 | 802 | 28 | 107 | 116 / 12 | v0.3.1 |
| `kubernetes-sigs/agent-sandbox` | SIG isolation (RH build) | 2025-08-12 | 4,693 | n/a | n/a | n/a | 128 / 70 | n/a |

All Apache-2.0. Issue/PR columns are the true split obtained from the `search` API; GitHub's `open_issues_count` field bundles open PRs into the issue number (e.g. Substrate shows 985 = 615 issues + 371 PRs), which is what my first draft mis-reported. Values drift daily. **[verified via GitHub API today]**

**Read:** very hot, very young, just reached 1.0, Google-led, CNCF Sandbox governance (donated at KubeCon NA 2026). Healthy contributor base and cadence. The flip side of that cadence is instability and a large open backlog (see below).

---

## 5. Cost of ownership (maintenance surface)

**[all verified against the cloned repo today]**

| Metric | Value |
|---|---|
| Implementation (excl. vendor, tests, generated) | **~105k Go code lines** (~155k physical, 727 files) + ~9k Python |
| Tests | ~197k code lines (~239k physical, 710 files) |
| Generated Go (`// Code generated`, excl. vendor) | ~58k lines (54 files) |
| Packages / dirs with Go | ~274 |
| Binaries (`cmd/`) | 14 |
| Vendored modules | 249 (141 MB) |
| Manifests (YAML) | 46 |
| Docs (md) | 87 files (~12.8k lines) |
| Open issues / PRs | ~615 / ~371 |
| Release cadence | weekly community release; v1.0.1 days after v1.0 |

Method: all counts exclude `vendor/`. Implementation excludes `*_test.go` and any file carrying the canonical `// Code generated ... DO NOT EDIT` marker. "Code lines" approximates SLOC by dropping blank and `//` comment-only lines (no `cloc`/`tokei` on this host), so treat it as +/- a few percent; "physical" is raw `wc -l`. My first draft's "450k" wrongly summed implementation + generated + tests.

**Operational dependency surface you would be on the hook for:**

- **Envoy** data plane (`go-control-plane`, custom Envoy build) for routing/egress.
- **PostgreSQL** control-plane datastore (pgx, goose migrations, squirrel, testcontainers).
- **OpenFGA** (Zanzibar-style) for authorization policy.
- **SPIFFE/SPIRE-style identity** and Pod Certificate / ClusterTrustBundle plumbing.
- **gVisor (runsc)** and **Cloud Hypervisor** microVM runtimes (checkpoint/restore).
- **Low-level Linux networking:** nftables, netlink, netns, proxy ARP/NDP.
- **Object storage** snapshot backends: AWS S3 and GCS.
- **OpenTelemetry** throughout; a Prometheus/Jaeger/OTel-collector observability stack.

Even the kind "hello world" install pulls **~570 MB of third-party images** (Postgres, Prometheus, OTel collector, rustfs, Envoy, Jaeger) and runs them. "Support as-is, no new features" still means owning CVE response, release engineering, and issue triage across this whole stack, plus the inbound RFE stream from the OCP AI team.

**Honest assessment:** this is a specialized distributed-systems + container-runtime + Linux-networking codebase. The team has the Go/Kubernetes-controller muscle, but gVisor/microVM/Envoy/nftables depth is a new skill area. Staffing this "as-is" credibly is a multi-engineer, ongoing commitment, not a maintenance afterthought.

---

## 6. Technical fit on OpenShift (the crux for "can we even ship this")

**Kubernetes version** **[verified on the live clusters today]**
- OCP 4.22 = Kubernetes **1.35.9** (CoreOS 9, cri-o 1.35).
- OCP 5.0.1 = Kubernetes **1.36.5** (CoreOS 10, cri-o 1.36).
- Substrate homepage floor: **1.37+**. README support policy: "latest stable + previous minor," i.e. 1.36 and 1.37. So **OCP 5.0 (1.36) is just inside the support window; OCP 4.22 (1.35) is not.**

**Feature-gate blocker** **[verified from the installer; OCP-side specifics need confirmation]**
Substrate's own kind installer enables `ClusterTrustBundle`, `ClusterTrustBundleProjection`, `PodCertificateRequest`, and `runtimeConfig: certificates.k8s.io/v1beta1`, with the comment "not enabled by default as of Kubernetes v1.36." OpenShift does not let you toggle individual upstream feature gates; you get `Default`, `TechPreviewNoUpgrade`, or `DevPreviewNoUpgrade` sets, and `TechPreviewNoUpgrade` is irreversible and blocks upgrades. On **managed ROSA/OSD this is not customer-configurable at all.** Whether OCP 5.0's TechPreview set even includes these gates is unconfirmed. **This is the most concrete blocker to running Substrate on OpenShift today.**

**Isolation runtime mismatch.** Substrate is gVisor-first (microVM via Cloud Hypervisor). OpenShift's supported sandbox runtime is **Kata** (OpenShift sandboxed containers), which is what the Red Hat build of Agent Sandbox uses. gVisor nested in worker pods needs privileged/elevated pods, which means custom SCCs on OCP. **[verified architecture; OCP SCC specifics needs confirmation]**

**Net:** running upstream Substrate unmodified on current OpenShift is blocked or heavily caveated today. Making it a supportable OCP product is itself a project (feature-gate enablement path, Kata/gVisor story, SCC hardening), which collides with the "no new features" framing.

---

## 7. Comparison with projects we know

How Agent Substrate sizes up against the projects this team already knows: KEDA (which we productize as the Custom Metrics Autoscaler), Knative Functions, the console plugin, and kagent (the layer directly above Substrate). Metrics gathered 2026-11-23. LOC is code-only (excludes blank lines, comments, vendored deps, tests, and generated files), counted with one consistent method across all repos; counts drift daily.

| Project (repo) | Layer / role | Created | Stars | Forks | Contrib. | Commits /30d | Issues / PRs | Latest release | Impl code | Test code |
|---|---|---|---|---|---|---|---|---|---|---|
| **Agent Substrate** `agent-substrate/substrate` | agent runtime (the ask) | 2026-05 | 8,211 | 907 | 133 | 200 | 615 / 371 | v1.0.1 (Nov 20) | **~114k** (Go 105k, Py 9k) | ~202k |
| **KEDA** `kedacore/keda` (-> CMA) | autoscaler (prior adoption) | 2019-02 | 10,738 | 1,599 | 455 | 33 | 230 / 56 | v2.21.1 (Nov 15) | ~44k (Go) | ~110k |
| **Knative Functions** `knative/func` | function CLI + library | 2020-02 | 365 | 231 | 98 | 61 | 56 / 48 | v1.24.0 (Oct 29) | ~36k (Go) | ~42k |
| **faas-console-plugin** `openshift/faas-console-plugin` | our OCP console plugin | 2026-06 | 1 | 6 | 9 | 39 | 6 / 10 | none yet | ~9k (TS 5k, Go 4k) | ~12k |
| **kagent** `kagent-dev/kagent` | orchestration (above Substrate) | 2025-01 | 4,501 | 937 | 226 | 148 | 162 / 140 | v1.0.1 (Nov 12) | ~142k (Go 64k, TS 65k, Py 14k) | ~129k |

All Apache-2.0. **[verified via GitHub API + local clones, 2026-11-23]**

**How to read it:**

- **Scale of the ask.** Substrate's implementation (~114k code lines) is ~2.6x KEDA, ~3x Knative Functions, and ~12x our plugin. Only kagent is bigger, and kagent spreads its size across three languages (Go controller + TS UI + Python), while Substrate concentrates ~105k lines in a single Go control/data plane we would have to understand deeply.
- **Maturity gap vs the KEDA precedent.** KEDA is ~7.8 years old, 455 contributors, a calm 33 commits/30d: a settled project we adopted after it stabilized. Substrate is ~6 months old, 200 commits/30d, with a 615/371 backlog: we would take it on mid high-churn, the opposite of the KEDA situation.
- **Activity we would inherit.** Substrate's 200 commits/30d is ~6x KEDA's and above kagent's; with weekly releases and openly expected breaking changes, "support as-is" means keeping pace with a fast-moving upstream, not maintaining a stable one.
- **Our starting point.** The plugin is ~9k LOC, 9 contributors, 5 months old. Jumping from that to co-owning a 114k-LOC runtime with a 600+ issue backlog is a large step-change in scope and required skills, which is exactly why the capacity and team-structure questions (Sections 9 and 10) matter.

### The KEDA precedent specifically

"Like we did with KEDA" is the anchor. Where the analogy holds and where it breaks:

| Dimension | KEDA (own upstream -> Custom Metrics Autoscaler) | Agent Substrate |
|---|---|---|
| Maturity at adoption | mature, stable APIs, CNCF graduated-track | 6 months old, v1.0, breaking changes expected |
| Size / surface | focused autoscaler (~44k LOC) | ~114k impl LOC (Go+Py), 14 binaries, deep systems stack |
| Skill adjacency | autoscaling, controllers (strong fit) | controllers yes; gVisor/microVM/Envoy/nftables new |
| OCP integration | clean (runs on any OCP) | blocked today (feature gates, gVisor vs Kata) |
| Competing RH bet? | no | yes (Red Hat build of Agent Sandbox) |
| Governance | CNCF | CNCF Sandbox, Google-founded |

The precedent supports the *model* (own upstream, ship a Red Hat build) and shows the team can do it. It does **not** imply comparable cost or risk: Substrate is materially larger and broader in scope (a multi-component data plane, not one autoscaler), much younger, and less OCP-ready, and it overlaps an existing product.

---

## 8. Options

1. **Own upstream Substrate solely (the ask).** Upside: strategic position below kagent, first-mover, OCP AI RFE impact. Cost: large maintenance load, OCP feasibility work, overlap risk, deprioritized plugin.
2. **Decline; let Mikhail Fedosin's autoscaler team own it.** Upside: protects the plugin roadmap and avoids a second isolation bet. Cost: cede a strategic runtime position the team is well placed for.
3. **Co-own / split.** e.g., we own the runtime/controller and lifecycle; autoscaler team owns scheduling/density; isolation stays with the Agent Sandbox/Kata effort. Upside: shares load, forces a coherent layering story. Cost: coordination overhead; needs org buy-in.
4. **Conditional yes (recommended posture for Wednesday).** Signal willingness and fit, but make the commitment contingent on answers to Section 9 and on the team-structure terms in Section 10. This is consistent with Mike's "say right away if not comfortable" while not throwing away the opportunity.

---

## 9. Open questions for Mike (PM) and Finn

These change the answer and only they can settle them. Ordered by impact.

1. **Strategy vs Red Hat build of Agent Sandbox.** We already ship Agent Sandbox (Kata) for agent isolation. Is Substrate meant to **complement** it (density/scheduling tier), **replace** it, or **compete**? What is the one-runtime story we would be executing?
2. **What does "owning" mean, practically?** Do we fork and carry a downstream, or start contributing and work toward maintainer seats on the upstream? And what is "internal product" here: own the upstream CNCF project and ship a "Red Hat build of Agent Substrate" (the KEDA model), an internal fork, or both? The engagement model (fork vs upstream maintainership) drives cost, our influence over direction, and how fast we can land the OCP changes from Section 6.
3. **Why us vs the autoscaler team?** What is the strategic rationale for Functions + Plugin specifically, beyond availability?
4. **Capacity.** Owning a ~105k-LOC (implementation), ~615-issue, 14-binary project "as-is" still needs triage, release engineering, and CVE response. What headcount and skills (gVisor/microVM/Envoy/networking) come with it?
5. **Is "no new features day 0" real?** It is stated alongside "RFEs from the OCP AI team, prioritized over frontend." What is the RFE volume/SLA expectation, and which wins when they conflict?
6. **Plugin impact.** What happens to the console plugin commitments and the 6 months of roadmap if frontend is deprioritized "for the initial time"? How long is "initial"?
7. **OCP target and feasibility.** Must it run on **managed** OCP (ROSA/OSD), where feature gates are not customer-configurable? What is the supported path for the required K8s features and for gVisor vs Kata on OCP?
8. **Governance and influence.** As a CNCF Sandbox project Google founded, what maintainer standing do we get? Upstream-first, or carry a downstream?
9. **Reversibility.** If we take it and it proves too heavy, can it move to the autoscaler team later without a crisis?
10. **Coordination with kagent.** kagent is adopting Substrate as its runtime. Do we align with kagent-dev, and does that shape priorities?

---

## 10. Team and org requirements (for the Finn conversation)

Non-negotiables to carry in, framed from the call notes ("organized better, not worse, than PIXAA"):

- **Keep the current team intact.** The 6 months of shared context and velocity is the asset; do not scatter it.
- **A dedicated product manager embedded in the team.** Not a shared/absentee PM. This is the explicit "better than PIXAA" condition.
- **Apply the practices we have built** over the last 6 months (refinement flows, ways of working, inbox/backlog discipline, review and refactor cadence).
- **Explicit, funded scope.** Either genuinely "maintenance as-is" with protected plugin time, or a real product mandate with the headcount to match. Not both responsibilities on one team's current capacity.
- **A written charter** for what "ownership" includes (triage, releases, CVEs, RFEs, upstream maintainership) and what it excludes.

---

## 11. Evidence log, verification status, and next steps

**Primary sources consulted today:** Google Open Source blog (Substrate + gVisor CNCF donation), ate.dev, `agent-substrate/substrate` repo (README, `hack/create-kind-cluster.sh`, `go.mod`, code metrics), kagent.dev "Future of kagent" blog, GitHub API (repo stats for substrate/kagent/ax/agent-sandbox), Red Hat OpenShift 5 coverage (unite.ai), and the two live clusters (`oc`).

**Verified today:** architecture and components; code metrics; dependency surface; community stats; Substrate's K8s feature-gate requirements; OCP 4.22 = 1.35.9 and OCP 5.0.1 = 1.36.5; kagent's migration to Substrate; existence of `kubernetes-sigs/agent-sandbox` and the Red Hat build of Agent Sandbox.

**Needs confirmation:** that "Red Hat build of Agent Sandbox" upstream is `kubernetes-sigs/agent-sandbox`; exact OCP 5.0 TechPreview feature-gate contents and whether they cover `PodCertificateRequest`/`ClusterTrustBundle`; OCP SCC requirements for gVisor-in-pod; depth of named adopters' production use; sub-500ms vs sub-100ms resume claim (sources differ: Google says <500ms, kagent says sub-100ms).

**Spike status (hands-on hello-world):** not yet run. Blockers found: the Substrate kind installer manages a container named `kind-registry` and would `docker rm -f` your existing one (port 5000, serving the `tekton` cluster); port 5001 (its default) is also in use. An isolated-registry variant is straightforward but not yet done. An OCP deploy of the counter demo is expected to hit the feature-gate blocker in Section 6. **Recommendation:** run the isolated kind spike to ground the "what owning it feels like" claim, and attempt an OCP 5.0 deploy specifically to document exactly where it fails (that failure is itself evidence for the decision).

**Open follow-ups if we proceed:** confirm the Agent Sandbox upstream; test Substrate on OCP 5.0 (1.36) with a feature-gate path; evaluate whether func-console could be the console FE for Substrate/kagent (separate investigation, noted but not assessed here).
