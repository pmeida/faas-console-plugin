# Agent Substrate: Ownership Investigation and Recommendation

**Status:** DRAFT for team decision

**Prepared:** 2026-11-26

**Decision deadline:** Wed 2026-11-25 EOB (answer to Finn; be honest about if we are comfortable; Mike from upper management is involved)

**Audience:** Functions + Console Plugin team, then  Finn, Mike

**Scope of ask (from the PM call):** Does Functions + Plugin want to take ownership of **upstream Agent Substrate**, the way we took on KEDA? Own it "as-is" (no new features on day zero), accept RFEs from the OCP AI team (prioritized over console plugin initially), and tell Finn our team-structure requirements.


## 1. Executive summary and preliminary recommendation

Agent Substrate is a six-month-old, Google-founded, CNCF Sandbox runtime for running **large numbers of sandboxed AI agents on Kubernetes at ~10x density**, by suspending idle agents to tiered storage and resuming them on a shared worker pool in under 500ms. It just hit v1.0, it is extremely active, and the orchestration layer above it (kagent) is **moving its entire runtime onto Substrate**. The strategic momentum is real.

But the ownership proposition has three hard edges the evidence makes unavoidable:

1. **Maintenance surface is large for "support as-is."** ~105k lines of implementation Go (approx; ~155k physical across 727 files), plus a large ~197k-line test suite, across ~274 packages and 14 binaries, 249 vendored modules, and a ~615-issue / ~371-PR open backlog on a 6-month project, weekly releases, and breaking changes openly expected. The stack is deep systems work: gVisor, Cloud Hypervisor microVMs, an Envoy data plane, nftables/netns networking, a Postgres control-plane datastore, OpenFGA authorization, SPIFFE/pod-certificate identity, and S3/GCS snapshot storage. This is broader and deeper than KEDA.

2. **It does not cleanly run on OpenShift today, but the hardest blocker is a timing issue, not a permanent one.** OCP 4.22 is Kubernetes 1.35; OCP 5.0 is 1.36. Substrate's homepage floor is 1.37, and on 1.36 it requires features (`ClusterTrustBundle`, `PodCertificateRequest`) that are beta-but-off-by-default and that OpenShift does not let you toggle individually (and managed ROSA/OSD does not let you toggle at all). **However, all the required feature gates graduate to GA and on-by-default in Kubernetes 1.37 (locked from 1.38), so the first OCP to ship 1.37 (OCP 5.1) clears the version and gate floor with nothing to toggle.** What remains on any OCP: Substrate runs its sandboxes (gVisor, or Kata on Cloud Hypervisor) *nested inside privileged worker pods*, while OpenShift's supported sandbox is node-level Kata (OpenShift sandboxed containers) - an SCC/integration problem, not a fundamental incompatibility.

3. **It is a second bet in the same problem space, without a stated composition story.** Red Hat already productizes **`kubernetes-sigs/agent-sandbox`** as the "Red Hat build of Agent Sandbox" (Kata microVMs, tech preview in OCP 5). The two are **not the same layer**: agent-sandbox is a `Sandbox` CRD that delegates isolation to a node-level RuntimeClass (one sandbox = one pod = one VM), while Substrate is a density/runtime tier that multiplexes many actors onto warm workers via nested in-pod sandboxes with snapshot/resume. The overlap is real but partial: warm pools (`SandboxWarmPool` vs `WorkerPool`) today, and agent-sandbox's aspirational "deep hibernation" roadmap converging on Substrate's core feature tomorrow - plus the customer-confusion cost of two Red Hat answers to "where do agent workloads run." Owning Substrate fills a layer Red Hat currently does not cover, but only if someone states how the two compose (or which wins).

**Preliminary lean (team's to accept or reject): a qualified "yes, but not an unconditional commitment this week."** The team is a good technical fit (Go, controllers, KEDA upstream experience, Knative/serverless suspend-resume adjacency) and the upside is strategically large. But committing to *sole* ownership by Wednesday is premature until Mike/Finn answer three things: (a) the Agent Sandbox overlap/strategy, (b) guaranteed capacity plus an embedded PM (the "not another PIXAA" condition), and (c) a realistic scope, because "no new features" is not credible alongside "RFEs from the OCP AI team, prioritized over frontend." If those are answered well, a yes is defensible. If they cannot be, we should say so now, exactly as Mike asked.

---

## 2. What Agent Substrate is

**The problem.** An AI agent executes untrusted, model-generated code and tool calls, so it must be isolated from host and network. But agents are idle 90-95% of the time (waiting on a model, a tool, or a human) while holding live state (RAM, filesystem, git checkouts, tool sessions). Standard Kubernetes forces a bad trade: a warm pod per agent (pay for idle compute) or scale-to-zero (20s+ cold starts). And scheduling thousands of short-lived agent pods overwhelms etcd and the API server.

**The design.** Substrate adds an actor/worker control and data plane on top of Kubernetes:

- **Actor** = one agent session's state (filesystem, env, memory, network rules), grouped in an **Atespace**, created from an **ActorTemplate**.
- **Worker** = a pre-warmed pod in a **WorkerPool** that provides compute.
- **atenet-router** parks the incoming request, the controller places the actor on a warm worker, state restores from tiered storage in <500ms, and snapshots back when idle. 10-30x oversubscription, 500+ activations/sec.
- **Isolation:** every actor runs in its own **gVisor (runsc)** or **Cloud Hypervisor microVM** sandbox. Plain containers are not supported. gVisor runs *nested inside* worker pods (via an in-pod `runsc` checkpoint/restore helper), so no node-level RuntimeClass is required, which is why it runs on "any conformant Kubernetes."
- **Security:** per-actor SPIFFE X.509 identity, zero credentials inside the sandbox (an egress gateway injects them outside the sandbox), default-deny networking, pluggable egress policy.
- **Framework-agnostic:** an actor is just an OCI image (Claude Code, Codex, LangChain, ADK, Hermes, MCP servers).

**Components (14 binaries):** `ateapi` (gRPC control plane), `atecontroller` (WorkerPool reconciler), `atelet` (node DaemonSet, snapshotting), `atenet` (Envoy routing + proxy sidecars + egress), `ate-idp-server` (actor-JWT OpenID issuer), `ateworker-gvisor` / `ateworker-microvm` (in-pod sandbox helpers), `podcertcontroller` (Pod Certificate polyfill), `credential-provider`, `objectstore-plugin`, `dataplane`, `kubectl-ate` (CLI), `ate-setup` (installer), `benchmarking`.

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

- **kagent** (★4.5k, CNCF Sandbox) is the orchestration layer and is **migrating its runtime fully onto Agent Substrate** (via a `SandboxAgent` CRD; legacy Deployment runtime kept on `release/v0.10.x`). This is the clearest adoption signal Substrate has: the leading K8s agent framework is betting its runtime on it.
- **Google Agent Executor (`google/ax`, ★14.9k)** is Google's distributed agent runtime built on Substrate.
- **Other consumers named by primary sources:** Nous Research (Hermes), VMware vSphere Kubernetes Service, GKE (optimized install).

**The Red Hat overlap.** OpenShift 5 GA'd on 2026-11-09 with an agentic story: OpenShift Lightspeed (supervised agentic ops GA; autonomous troubleshooting + update agent in tech preview), an OpenShift MCP server + MCP gateway (GA), confidential containers, and the **"Red Hat build of Agent Sandbox" (tech preview)**, which "uses OpenShift sandboxed containers to place agent workloads inside VMs". The upstream is `kubernetes-sigs/agent-sandbox`.

So Red Hat has already chosen a **Kata-based, SIG-governed, node-level** agent isolation story. This proposal asks us to own a **Google/CNCF, higher-density** runtime for an overlapping problem - and notably, Substrate's microVM class is *also* Kata (on the Cloud Hypervisor VMM), just nested inside worker pods rather than installed as the node runtime.

**How much do they actually overlap?**

- **Different abstractions.** agent-sandbox's `Sandbox` CRD gives you one long-running, stateful, singleton pod with stable identity and delegates isolation to a node-level RuntimeClass (gVisor or Kata). Substrate multiplexes many actors onto fewer warm workers with snapshot/resume and nested in-pod sandboxes. agent-sandbox has no density, oversubscription, or actor-multiplexing control plane.
- **Genuine overlap today:** warm pools (`SandboxWarmPool`/`SandboxClaim` vs `WorkerPool`) solve the same allocation-latency problem, and both target untrusted agent code.
- **Plausible convergence tomorrow:** agent-sandbox lists "deep hibernation" (state-to-persistent-storage) and memory sharing as *desired features, not shipped ones*. If the SIG builds them, the projects collide on Substrate's core ground.

The two can therefore be framed as complementary (Agent Sandbox = node-level isolation primitive; Substrate = density/scheduling tier above it, sharing the Kata/Cloud Hypervisor lineage) or as competing bets; the shared lineage and the layer gap both strengthen the complementary framing - Substrate fills a layer Red Hat currently does not cover. **Whether Red Hat intends them to compose, and who owns that story, is the single most important open question for Mike** (see Section 9).

---

## 4. Adoption and community health

| Repo | Role | Created | Stars | Forks | Contributors | Commits/30d | Open issues / PRs | Latest |
|---|---|---|---|---|---|---|---|---|
| `agent-substrate/substrate` | runtime (this) | 2026-05-13 | 8,211 | 907 | 133 | 200 | **615 / 371** | v1.0.1 (Nov 20) |
| `kagent-dev/kagent` | orchestration above it | 2025-01-21 | 4,501 | 937 | 226 | 148 | 162 / 140 | v1.0.1 |
| `google/ax` (Agent Executor) | runtime on it | 2026-03-30 | 14,860 | 802 | 28 | 107 | 116 / 12 | v0.3.1 |
| `kubernetes-sigs/agent-sandbox` | SIG isolation (RH build) | 2025-08-12 | 4,693 | n/a | n/a | n/a | 128 / 70 | n/a |

All Apache-2.0. Issue/PR columns are the true split obtained from the `search` API; GitHub's `open_issues_count` field bundles open PRs into the issue number (e.g. Substrate shows 985 = 615 issues + 371 PRs), which is what my first draft mis-reported. Values drift daily.

### Backlog composition (open issues by kind)

| Kind | Open | Notes |
|---|---|---|
| `kind/feature` | 290 | the largest bucket - RFE demand is real |
| `kind/bug` | **219** | the number that matters for "support as-is" |
| `kind/design` | 61 | open design discussions / proto-RFCs |
| `kind/cleanup` | 51 | the refactoring bucket (there is no `kind/refactor`) |
| `kind/docs` | 23 | |
| `kind/performance` | 21 | |
| **Total open issues** | **628** | 30 are `prio/P0`, 46 `prio/P1` |

Read: a 6-month-old project carrying 219 open bugs and 30 P0s is the single clearest signal of the load "as-is" ownership buys. Even triaging at Google's current pace, the backlog grows.

### Who actually drives the project

**Commits by author email domain** (full history, ~1,720 commits, 164 unique authors):

- `google.com`: 1,111 commits, 55 authors
- `users.noreply.github.com`: 313 commits, 40 authors
- `gmail.com`: 163 commits, 49 authors
- `solo.io`: 50 commits (Eitan Yarmush)
- `nvidia.com`: 25 commits (Omer Yahud, Davanum Srinivas)
- `docker.com`: 22 commits
- ~15 other companies with 1-6 commits each (zendesk, giantswarm, coreweave, ...)

Caveat: the gmail/noreply buckets contain confirmed Googlers (e.g. dberkov, company=Google), so the honest split is **roughly 70-80% of commits from Google**. The recurring non-Google contributors are solo.io, Nvidia, and Docker.

**Who merges PRs** (last 300 merged PRs, 12+ distinct mergers) - the de facto maintainer roster:

| Merger | Merges (of 300) | Affiliation |
|---|---|---|
| BenTheElder (Benjamin Elder) | 56 | Google (kind creator) |
| dberkov | 37 | Google |
| LiorLieberman | 34 | Google |
| thockin (Tim Hockin) | 33 | Google (K8s founding engineer) |
| maxsmythe | 25 | Google |
| zoez7 | 24 | unconfirmed |
| EItanya (Eitan Yarmush) | 19 | **solo.io** |
| juli4n, HavenXia, msau42 | 15/15/13 | Google |
| sfunkenhauser, bowei | 7/7 | -/Google |

So yes, "they are a big team": **~12 active mergers, at least 10 Google** (including heavyweight K8s names), one significant external maintainer (solo.io). A team of 3-4 of ours merging regularly would be ~25% of merge activity - enough to be heard, not enough to steer alone.

**Development process**:

- GitHub PRs with a merge queue; at least one maintainer approval required (even for maintainers); DCO enforced
- Behavior changes MUST come with tests; CI on every PR; privileged tests behind `roottest.Require`
- PR sizing convention (S/M/L/XL; XL must be split)
- Semver, with a `breaking-change` label and mandatory upgrade steps in release notes
- Weekly tag-driven releases via GitHub Actions (images job builds+verifies multi-arch, then binaries + draft release)
- RFCs and design discussion via `kind/design` issues, the ate-dev mailing list, and a weekly public community meeting (Thursdays 10-11 PT)
- CNCF Slack: `#substrate-users`, `#substrate-dev`

The process is mature and documented - the risk is not process chaos but *pace*: 200 commits/30d against a growing backlog.

**Read:** very hot, very young, just reached 1.0, Google-led, CNCF Sandbox governance (donated at KubeCon NA 2026). Healthy contributor base and cadence. The flip side of that cadence is instability and a large open backlog (see below).

---

## 5. Cost of ownership (maintenance surface)

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
- **gVisor (runsc)** and the **Kata Containers + Cloud Hypervisor** microVM stack (checkpoint/restore, `userfaultfd` demand paging).
- **Low-level Linux networking:** nftables, netlink, netns, proxy ARP/NDP.
- **Object storage** snapshot backends: AWS S3 and GCS.
- **OpenTelemetry** throughout; a Prometheus/Jaeger/OTel-collector observability stack.

Even the kind "hello world" install pulls **~570 MB of third-party images** (Postgres, Prometheus, OTel collector, rustfs, Envoy, Jaeger) and runs them. "Support as-is, no new features" still means owning CVE response, release engineering, and issue triage across this whole stack, plus the inbound RFE stream from the OCP AI team.

**Honest assessment:** this is a specialized distributed-systems + container-runtime + Linux-networking codebase. The team has the Go/Kubernetes-controller muscle, but gVisor/microVM/Envoy/nftables depth is a new skill area. Staffing this "as-is" credibly is a multi-engineer, ongoing commitment, not a maintenance afterthought.

### Is it overengineered? (addressing the concern head-on)

The concern raised in the call - "overengineered, typical Google" - is partly right:

- **Right:** 14 binaries, ~105k lines, its own Postgres/OpenFGA datastore, Envoy build, nftables networking, credential provider, CSI driver - plus GKE-specific plumbing and multi-cloud storage paths we would never use. That breadth is dead weight under "own as-is," and it showed up as real integration work in the OCP spike.
- **Wrong as a dismissal:** the core problem - suspend/resume of untrusted, sandboxed workloads at 10-30x density, sub-500ms resume, zero credentials in the sandbox - has no shallow version. The security architecture is the product. Google runs it in production and kagent is betting its runtime on it.

**Verdict:** not overengineered, but **broader than our use case, and we pay for the breadth anyway**. The complexity is disciplined (strong tests, mature process, heavyweight maintainers), so it will not collapse under its own weight - but "we would not have built it this way" is normal for adopting a Google-originated runtime (it was true of Knative too).

---

## 6. Technical fit on OpenShift (the crux for "can we even ship this")

**Kubernetes version and feature gates**

- Versions: OCP 4.22 = K8s 1.35, OCP 5.0 = 1.36, **OCP 5.1** - one K8s minor per OCP minor. Upstream's support policy is "latest stable + previous minor" (today 1.36-1.37): 4.22 is outside the window, and 5.0 is nominally inside until 1.38 ships - moot anyway, since 5.0 cannot run Substrate (below).
- **OCP 5.0 is not doable, in any configuration.** On K8s 1.36, the three APIs Substrate needs (`ClusterTrustBundle`, `ClusterTrustBundleProjection`, `PodCertificateRequest`) are beta, off by default, and serving them needs a `--runtime-config` mapping OpenShift's API-server operator does not have. TPNU does not include the gates; and the unsupported `CustomNoUpgrade` escape hatch cannot supply the missing runtime-config either.
- **OCP 5.1 clears the version and gate blockers.** All three gates GA'd on-by-default in K8s 1.37 (locked from 1.38) with the v1 APIs served, so there is nothing to toggle and the ROSA/OSD gate restriction stops mattering.

**Isolation model gap** Substrate's microVM class runs actors in a **Kata Containers guest on the Cloud Hypervisor VMM, nested inside worker pods** (`ateworker-microvm`), and its gVisor class nests `runsc` in pods the same way. The real gap is **in-pod nested sandboxes vs node-level runtime**: Substrate worker pods need elevated privileges (an in-pod VMM using `userfaultfd`, host-assembled rootfs overlays served over virtio-fs, node-local sandbox asset caches), which means custom SCCs on OCP, while OpenShift's supported sandbox is **node-level** Kata (OpenShift sandboxed containers), which is what the Red Hat build of Agent Sandbox uses. This is an SCC/integration and support-boundary problem, not a fundamental incompatibility, and the shared Kata/Cloud Hypervisor lineage strengthens the complementary framing in Section 3.

**Net:** running upstream Substrate unmodified on current OpenShift (4.22/5.0) is blocked by the version/gate floor until the first OCP on K8s 1.37, and heavily caveated (privileged in-pod sandboxes, custom SCCs) even then. Making it a supportable OCP product is itself a project (SCC hardening, a node-level Kata story or documented exception), which collides with the "no new features" framing - but "blocked today" should be read as "blocked until ~5.1," not "does not fit OpenShift."

---

## 7. Comparison with projects we know

How Agent Substrate sizes up against the projects this team already knows: KEDA (which we productize as the Custom Metrics Autoscaler), Knative Functions, the console plugin, and kagent (the layer directly above Substrate). LOC is code-only (excludes blank lines, comments, vendored deps, tests, and generated files), counted with one consistent method across all repos; counts drift daily.

| Project (repo) | Layer / role | Created | Stars | Forks | Contrib. | Commits /30d | Issues / PRs | Latest release | Impl code | Test code |
|---|---|---|---|---|---|---|---|---|---|---|
| **Agent Substrate** `agent-substrate/substrate` | agent runtime (the ask) | 2026-05 | 8,211 | 907 | 133 | 200 | 615 / 371 | v1.0.1 (Nov 20) | **~114k** (Go 105k, Py 9k) | ~202k |
| **KEDA** `kedacore/keda` (-> CMA) | autoscaler (prior adoption) | 2019-02 | 10,738 | 1,599 | 455 | 33 | 230 / 56 | v2.21.1 (Nov 15) | ~44k (Go) | ~110k |
| **Knative Functions** `knative/func` | function CLI + library | 2020-02 | 365 | 231 | 98 | 61 | 56 / 48 | v1.24.0 (Oct 29) | ~36k (Go) | ~42k |
| **faas-console-plugin** `openshift/faas-console-plugin` | our OCP console plugin | 2026-06 | 1 | 6 | 9 | 39 | 6 / 10 | none yet | ~9k (TS 5k, Go 4k) | ~12k |
| **kagent** `kagent-dev/kagent` | orchestration (above Substrate) | 2025-01 | 4,501 | 937 | 226 | 148 | 162 / 140 | v1.0.1 (Nov 12) | ~142k (Go 64k, TS 65k, Py 14k) | ~129k |

All Apache-2.0.

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
| OCP integration | clean (runs on any OCP) | blocked today (gate floor clears on K8s 1.37 / plausibly OCP 5.1; privileged in-pod sandboxes vs node-level Kata remain) |
| Competing RH bet? | no | partial - same problem space, different layer (Agent Sandbox = node-level isolation; overlap: warm pools today, converging roadmaps tomorrow) |
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

1. **Goal.** Why does Red Hat want Substrate at all - a seat at the table below kagent, a product customers run, or a hedge? This determines scope, staffing, and what "success" means.
1. **Relation to Agent Sandbox.** They sit at different layers (see Section 3), so not "which one wins" but: how do they compose, who owns the two-layer story, and what if agent-sandbox's "deep hibernation" roadmap rebuilds Substrate's core feature - which direction does Red Hat consolidate?
1. **What does "owning" mean, practically?** Our working assumption is the KEDA model: contribute upstream toward maintainer seats (become the SMEs) and ship a "Red Hat build of Agent Substrate" downstream. Confirm that assumption.
1. **Why us vs the autoscaler team?** What is the strategic rationale for Functions + Plugin specifically, beyond availability?
1. **Capacity.** Owning a ~105k-LOC (implementation), ~615-issue, 14-binary project "as-is" still needs triage, release engineering, and CVE response. What headcount and skills (gVisor/microVM/Envoy/networking) come with it?
1. **What is actually expected of us on day 0?** "No new features" and "RFEs from the OCP AI team, prioritized over frontend" are contradictory as stated - an RFE is a feature. So what does the first months of ownership concretely look like: triage, releases, and CVE response only? Or landing OCP enablement (itself new work - the spike scoped it)? What is the expected RFE volume and response SLA, and what is deliberately *not* expected?
1. **Plugin impact.** What happens to the console plugin commitments and the 6 months of roadmap if frontend is deprioritized "for the initial time"? How long is "initial"?
1. **Governance and influence.** As a CNCF Sandbox project Google founded, what maintainer standing do we get? Is upstream-first mandatory for OCP enablement changes?
1. **Reversibility.** If we take it and it proves too heavy, can it move to the autoscaler team later without a crisis? What happens to us?
1. **Coordination with kagent.** kagent is adopting Substrate as its runtime. Do we align with kagent-dev, and does that shape priorities?

---

## 10. Team and org requirements (for the Finn conversation)

Non-negotiables to carry in, framed from the call notes ("organized better, not worse, than PIXAA"):

- **Keep the current team intact.** The 6 months of shared context and velocity is the asset; do not scatter it.
- **A dedicated product manager embedded in the team.** Not a shared/absentee PM. This is the explicit "better than PIXAA" condition.
- **Apply the practices we have built** over the last 6 months (refinement flows, ways of working, inbox/backlog discipline, review and refactor cadence).
- **Explicit, funded scope.** Either genuinely "maintenance as-is" with protected plugin time, or a real product mandate with the headcount to match. Not both responsibilities on one team's current capacity.
- **A written charter** for what "ownership" includes (triage, releases, CVEs, RFEs, upstream maintainership) and what it excludes.

### How many of us would it take? (analysis, judgment)

**Ownership model (team's working assumption):** we own the **Red Hat build** of Agent Substrate, KEDA-style. That means three things at once: (1) contribute upstream and drive it, to become the SMEs; (2) build and maintain the downstream (the Red Hat build: OCP enablement, releases, CVEs, backports); (3) absorb internal RFEs (OCP AI team) and drive their resolution, upstream-first. The sizing in Section 10 assumes this model.

For scale: upstream has ~12 active maintainers doing 200 commits/month against 628 open issues, with weekly releases. KEDA, our precedent, needs a similar number of people but runs 6x calmer (33 commits/month) - that is why we could absorb KEDA, but cannot absorb this on the side.

Under the assumed ownership model (Section header) we carry **three streams at once**: driving upstream (becoming SMEs), maintaining the Red Hat build downstream, and absorbing internal RFEs.

- **Minimum to be credible: 4 engineers + a PM.** Everyone blends upstream contribution (roughly a quarter of the project's merge activity is what earns maintainer seats and SME standing), downstream maintenance (tracking weekly upstream releases, backports, CVEs), and internal RFEs by priority. Functions Red Hat normally separates - QE, and sustaining/backport engineering once the product GA's - are additions for later, not day-one asks.
- **Comfortable / real impact: 5-7 engineers.** At that size we can drive upstream direction instead of following it, ship the Red Hat build without heroics, and absorb RFEs without dropping the upstream contribution that makes us SMEs in the first place.
- **At least one of those engineers needs real container-runtime or Linux-networking experience** (gVisor, Envoy, nftables).

This is our own estimate from the data above - pressure-test it against Mike's capacity answer (Q4).

---

## 11. Verification status, and next steps

**Spike status: executed 2026-11-25 on an OCP 5.1 nightly (5.1.0-0.nightly-2026-11-24-072328, K8s 1.37.2), upstream v1.0.1, gvisor sandbox class only.** **The full control plane runs on OCP 5.1** - api-server, controller, idp-server, atenet (Envoy), atelet on all nodes, postgres, rustfs, and the Pod Certificate machinery, which needed zero changes (the Section 6 gate blocker is confirmed gone on 1.37).

Every failure encountered was admission-control / SELinux / sysctl / registry plumbing with a known workaround - the "integration problem, not incompatibility" framing of Section 6 - plus one open issue inside the gVisor sandbox itself (likely upstream, not root-caused). Nothing fundamental blocks Substrate on OCP 5.1, but a supportable product needs: a curated SCC, an SELinux policy module, the port sysctl in worker pod generation, an image-pull credential story, and an install path that labels namespaces and binds SCCs as it goes.

- Challenges and fixes, short form: [openshift-challenges.md](openshift-challenges.md) - including cross-validation by an independent SNO 5.1 lab that hit the same friction set and stopped one stage earlier (the cgroup-remount SELinux denial our `spc_t` SCC passes)
- Step-by-step reproduction on any OCP 5.1+ cluster: [openshift-counter-demo-runbook.md](openshift-counter-demo-runbook.md)
- Cluster-local manifest patches: the clone at `~/Projects/substrate` (searchable via `OCP spike (2026-11-25)` comments)

**Open follow-ups if we proceed:** confirm the Agent Sandbox upstream; root-cause the gVisor sandbox write-then-ENOENT issue (spike stopping point, see above) and the NET_BIND_SERVICE/userns low-port issue; complete the counter tutorial end-to-end (actor create, suspend/resume timing); evaluate whether func-console could be the console FE for Substrate/kagent (separate investigation, noted but not assessed here).
