# Agent Substrate on OpenShift: Main Challenges

**Short version for the decision.** Hands-on spike, 2026-11-25, upstream v1.0.1 on an OCP 5.1 nightly (K8s 1.37.2). The full control plane runs on OpenShift. Every problem found has a known workaround; none is a hard incompatibility. Details and evidence: [README.md](README.md) (spike log at the bottom).

## What just works

- Kubernetes 1.37 APIs (ClusterTrustBundle, PodCertificateRequest) - GA and on by default, nothing to toggle. Older OCP (4.x = K8s 1.35, 5.0 = 1.36) is below Substrate's floor.
- CRDs, controllers, Postgres, Envoy data plane, rustfs, the certificate machinery - plain workloads, no changes.

## The challenges

| # | Challenge | Fix needed | Effort |
|---|---|---|---|
| 1 | **SCC admission.** OpenShift's default `restricted-v2` rejects Substrate's pods: pinned UIDs (postgres 70, rustfs 10001, atenet 65532), and the atelet/worker pods need hostPaths, UID 0, extra capabilities, `unconfined` seccomp. | Custom SCCs bound to the right service accounts (`anyuid` for the pinned-UID components; a privileged-equivalent SCC for atelet and the gVisor workers). Cleaner upstream alternative for the atenet pods: drop the hard-coded UID pins (they don't need a specific UID) and let `restricted-v2` assign one - that is what the independent lab did; `anyuid` is only intrinsic where the image demands its UID (postgres 70). | Medium - one-time, well understood |
| 2 | **SELinux.** RHCOS denies `container_t` access to the `/var/lib/ate` hostPath (labeled `container_var_lib_t`) and blocks the workers' cgroup remount - confirmed via `ausearch` on the node. Spike used `spc_t`; the supportable fix is a proper SELinux policy module shipped with the product. Note the fix must cover SELinux *categories*, not just types: the independent lab showed the worker's MCS category mismatching the directory label denies traversal and file creation even where types would allow. | SELinux policy module (or `spc_t` as a stopgap). | Medium |
| 3 | **Low-port binds.** On OCP 5.1, binding :443 fails even with CAP_NET_BIND_SERVICE - verified empirically with a busybox test pod; crictl shows the capability in the container's effective set, so the cause is likely user-namespace ownership of the pod netns (the new `restricted-v3` SCC demanding `hostUsers=false` points the same way; not root-caused). | Pod-level sysctl `net.ipv4.ip_unprivileged_port_start` on ate-api-server and every worker pod - `443` (the independent lab's tighter value, opening only the needed port) is preferable to our spike's `0`. Upstream already does this for one component (atenet-egress) but not the others. | Small, but needs an upstream RFE: the WorkerPool template exposes no securityContext/sysctls field, so worker pods can't be configured today without patching the generated Deployment. |
| 4 | **Image pulls.** The atelet pulls actor images anonymously; OCP's internal registry requires auth and serves a service-CA cert the distroless images don't trust. | CA bundle + `SSL_CERT_FILE` for the atelet/workers, and either an anonymous registry or a credential-provider path for OCP (the built-in one is GKE/kubelet-shaped). | Medium |
| 5 | **Namespace lifecycle.** Every demo namespace gets PSA `restricted` and loses its SCC bindings when recreated. An installer must label namespaces and bind SCCs as it creates them. | Install-time automation. | Small |
| 6 | **Open: gVisor sandbox file I/O.** The counter demo's first sandbox boots (gVisor systrap, image pulled, container started) but a write-then-read of a file inside the sandbox fails (write reports success, read gets ENOENT; nothing lands in the host overlay upper). Looks like an upstream gVisor/RHCOR-kernel issue, not an OpenShift integration one. Not root-caused. | Unknown - needs upstream investigation. | Unknown |

## Bottom line

- **On OCP 5.1+ (K8s 1.37): no fundamental blocker.** Items 1-5 are admission-control/SELinux/sysctl/registry plumbing with known patterns - the kind of work an "OCP-enablement" release would bundle (curated SCC, SELinux module, installer changes, a couple of upstream RFEs).
- **Item 6 is the only real unknown** and it is an upstream sandbox-runtime issue, not something OCP integration caused.
- On OCP 4.x/5.0 the version floor alone is a hard blocker until those clusters reach K8s 1.37 (5.1).
- **The microVM (Kata/Cloud-Hypervisor) sandbox class is untested** on OCP: it needs `/dev/kvm` (absent on our spike nodes), and the independent lab observed a further SELinux denial when atelet tried to register `ate.dev/kvm` with the kubelet device-plugin socket - expect additional SELinux work on that path.

## Independent cross-validation

A second, independent lab run (SNO 5.1.0-ec.2 on libvirt/KVM, SELinux enforcing, upstream v1.0.1, gvisor class) hit **the same OCP friction set in the same order**: certificate APIs missing on 5.0 / present on 5.1, postgres UID 70 SCC rejection, atenet fixed-UID 65532 rejections, the api-server `:443` bind EPERM (fixed with the same sysctl), atelet SCC + SELinux hostPath denial, and the worker-pod SCC wall (hostPath, UID 0, unconfined seccomp, SYS_ADMIN/NET_ADMIN). That convergence means the enablement cost documented here is reproducible, not an artifact of our cluster.

Where the two runs diverge: that lab stopped at the gVisor worker's **cgroup-delegation remount** - SELinux enforcing denies `container_t` the `{ remount }` of `cgroup_t` - because its worker SCC kept the default `container_t` type. Our run forces `seLinuxOptions.type: spc_t` via the custom worker SCC, which passes that denial (workers Ready, `cgroup delegation ready` in the logs); a proper SELinux policy module would be the supportable equivalent. Our own stopping point is one stage deeper, inside the gVisor sandbox itself (challenge 6), which that lab never reached. Their report also suggests the tighter sysctl value `ip_unprivileged_port_start=443` (rather than `0`) for the eventual upstream RFE.
