# Agent Substrate on OpenShift: Main Challenges

**Short version for the decision.** Hands-on spike, 2026-11-25, upstream v1.0.1 on an OCP 5.1 nightly (K8s 1.37.2). The full control plane runs on OpenShift. Every problem found has a known workaround; none is a hard incompatibility. Details and evidence: [README.md](README.md) (spike log at the bottom).

## What just works

- Kubernetes 1.37 APIs (ClusterTrustBundle, PodCertificateRequest) - GA and on by default, nothing to toggle. Older OCP (4.x = K8s 1.35, 5.0 = 1.36) is below Substrate's floor.
- CRDs, controllers, Postgres, Envoy data plane, rustfs, the certificate machinery - plain workloads, no changes.

## The challenges

| # | Challenge | Fix needed | Effort |
|---|---|---|---|
| 1 | **SCC admission.** OpenShift's default `restricted-v2` rejects Substrate's pods: pinned UIDs (postgres 70, rustfs 10001, atenet 65532), and the atelet/worker pods need hostPaths, UID 0, extra capabilities, `unconfined` seccomp. | Custom SCCs bound to the right service accounts (`anyuid` for the pinned-UID components; a privileged-equivalent SCC for atelet and the gVisor workers). | Medium - one-time, well understood |
| 2 | **SELinux.** RHCOS denies `container_t` access to the `/var/lib/ate` hostPath (labeled `container_var_lib_t`) and blocks the workers' cgroup remount - confirmed via `ausearch` on the node. Spike used `spc_t`; the supportable fix is a proper SELinux policy module shipped with the product. | SELinux policy module (or `spc_t` as a stopgap). | Medium |
| 3 | **Low-port binds.** On OCP 5.1, binding :443 fails even with CAP_NET_BIND_SERVICE - verified empirically with a busybox test pod; crictl shows the capability in the container's effective set, so the cause is likely user-namespace ownership of the pod netns (the new `restricted-v3` SCC demanding `hostUsers=false` points the same way; not root-caused). | Pod-level sysctl `net.ipv4.ip_unprivileged_port_start=0` on ate-api-server and every worker pod. Upstream already does this for one component (atenet-egress) but not the others. | Small, but needs an upstream RFE: the WorkerPool template exposes no securityContext/sysctls field, so worker pods can't be configured today without patching the generated Deployment. |
| 4 | **Image pulls.** The atelet pulls actor images anonymously; OCP's internal registry requires auth and serves a service-CA cert the distroless images don't trust. | CA bundle + `SSL_CERT_FILE` for the atelet/workers, and either an anonymous registry or a credential-provider path for OCP (the built-in one is GKE/kubelet-shaped). | Medium |
| 5 | **Namespace lifecycle.** Every demo namespace gets PSA `restricted` and loses its SCC bindings when recreated. An installer must label namespaces and bind SCCs as it creates them. | Install-time automation. | Small |
| 6 | **Open: gVisor sandbox file I/O.** The counter demo's first sandbox boots (gVisor systrap, image pulled, container started) but a write-then-read of a file inside the sandbox fails (write reports success, read gets ENOENT; nothing lands in the host overlay upper). Looks like an upstream gVisor/RHCOR-kernel issue, not an OpenShift integration one. Not root-caused. | Unknown - needs upstream investigation. | Unknown |

## Bottom line

- **On OCP 5.1+ (K8s 1.37): no fundamental blocker.** Items 1-5 are admission-control/SELinux/sysctl/registry plumbing with known patterns - the kind of work an "OCP-enablement" release would bundle (curated SCC, SELinux module, installer changes, a couple of upstream RFEs).
- **Item 6 is the only real unknown** and it is an upstream sandbox-runtime issue, not something OCP integration caused.
- On OCP 4.x/5.0 the version floor alone is a hard blocker until those clusters reach K8s 1.37 (5.1).
