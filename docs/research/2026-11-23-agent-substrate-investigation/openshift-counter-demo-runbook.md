# Running the Substrate Counter Demo on OpenShift

Runbook from the 2026-11-25 spike. Verified on an **OCP 5.1 nightly** (5.1.0-0.nightly-2026-11-24-072328, K8s 1.37.2) with upstream **v1.0.1** prebuilt images. Known challenges and status: [openshift-challenges.md](openshift-challenges.md); full evidence: [README.md](README.md).

**Requirement:** OpenShift on Kubernetes **1.37+** (OCP 5.1 or newer). OCP 4.x (1.35) and 5.0 (1.36) are below Substrate's support floor.

## Prerequisites

- `cluster-admin` access to the target cluster
- Go 1.27+, Docker, skopeo on your workstation
- A clone of `agent-substrate/substrate`, checked out at the release tag you install:

```bash
git clone https://github.com/agent-substrate/substrate
cd substrate && git checkout v1.0.1
go build -o bin/ate-setup ./cmd/ate-setup
go install ./cmd/kubectl-ate
```

## 1. Deploy the control plane

The `--kind` install profile (in-cluster rustfs S3 snapshot storage, no GKE requirements) works on OpenShift; it only selects manifests, it does not verify the cluster is kind.

```bash
export KUBECONFIG=<path>   # cluster admin
./bin/ate-setup --context <ctx> --kind deploy ate-system \
  --sandbox-classes=gvisor \
  --storage-bucket-name=ate-snapshots \
  --image-repo ghcr.io/agent-substrate/substrate --image-tag v1.0.1 \
  --credential-provider='{"name":"k8s.io"}' \
  --ingress-allowed-spiffe-ids=spiffe://cluster.local/ns/ate-system/sa/atenet-client
```

## 2. OCP adaptations for `ate-system`

Run once after the deploy (the installer re-apply is idempotent):

```bash
# SELinux + admission for the atelet and the privileged helpers
oc label ns ate-system pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite
for sa in default atenet-router atenet-egress k8s-credential-provider; do
  oc adm policy add-scc-to-user anyuid -z $sa -n ate-system
done
oc adm policy add-scc-to-user privileged -z atelet -n ate-system

# Workers need privileged + forced spc_t (SELinux); the WorkerPool template
# exposes no securityContext, so force it via a custom SCC:
oc get scc privileged -o json | python3 -c "
import json,sys
scc=json.load(sys.stdin)
scc['metadata']={'name':'ateworker-spc'}
scc['seLinuxContext']={'type':'MustRunAs','seLinuxOptions':{'type':'spc_t'}}
scc['users']=[]; scc['groups']=[]
json.dump(scc,sys.stdout)" | oc apply -f -
```

The manifest-level fixes (atelet `spc_t`, ate-api-server port sysctl, registry CA mount) are already carried as `OCP spike (2026-11-25)` comments in the clone's `manifests/ate-install/`; carry them into your checkout the same way, or the installer's re-apply will revert live patches.

**Manifest patches required** (see the spike clone for exact diffs):
- `manifests/ate-install/atelet.yaml`: `seLinuxOptions.type: spc_t` on atelet + objectstore-plugin; `SSL_CERT_FILE` + CA ConfigMap volume for actor-image pulls
- `manifests/ate-install/ate-api-server.yaml`: pod securityContext sysctl `net.ipv4.ip_unprivileged_port_start=0` (binding :443 fails without it on OCP 5.1)

## 3. Actor image registry

The atelet pulls actor images **anonymously**, but OCP's internal registry requires auth. Easiest path: an anonymous in-cluster registry with a service-serving cert (the same CA the atelet already trusts via the bundle above):

```bash
# Deploy registry:2 with a service CA cert (see spike clone / manifests)
# then build the counter image and push it:
cd demos/counter && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /tmp/counter . && cd -
# Dockerfile: FROM gcr.io/distroless/static-debian13:nonroot@sha256:18f4cc26... ; COPY counter /ko-app/counter
docker buildx build --platform linux/amd64 -t counter-demo:v1.0.1 --load .
oc port-forward -n ate-system svc/ate-anon-registry 5000:5000 &
skopeo copy --dest-tls-verify=false docker-daemon:counter-demo:v1.0.1 docker://localhost:5000/counter:v1.0.1
skopeo inspect --tls-verify=false docker://localhost:5000/counter:v1.0.1 | jq -r .Digest
```

Point `demos/counter/counter-template.yaml.tmpl` at `ate-anon-registry.ate-system.svc:5000/counter:v1.0.1@sha256:<digest>` (digest-pinned is mandatory) and `demos/counter/counter.yaml.tmpl` at `ghcr.io/agent-substrate/substrate/ateworker-gvisor:v1.0.1` (demos are not published to ghcr; the worker image is).

## 4. Deploy the demo

```bash
./bin/ate-setup --context <ctx> --kind deploy demo counter
```

**Immediately after it starts** (the demo namespace is recreated, losing labels/bindings), re-apply the namespace adaptations:

```bash
oc label ns ate-demo-counter pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite
oc adm policy add-scc-to-user ateworker-spc -z ateworker -n ate-demo-counter
oc get cm ate-registry-ca -n ate-system -o yaml | sed 's/namespace: ate-system/namespace: ate-demo-counter/' | oc apply -f -
oc patch deploy counter -n ate-demo-counter --type=strategic -p '{"spec":{"template":{"spec":{"securityContext":{"sysctls":[{"name":"net.ipv4.ip_unprivileged_port_start","value":"0"}]},"containers":[{"name":"worker","env":[{"name":"SSL_CERT_FILE","value":"/etc/ate-registry-ca/ca-bundle.crt"}],"volumeMounts":[{"name":"ate-registry-ca","mountPath":"/etc/ate-registry-ca","readOnly":true}]}],"volumes":[{"name":"ate-registry-ca","configMap":{"name":"ate-registry-ca"}}]}}}}'
```

If the deploy's 5-minute rollout wait expires while workers restart, run `deploy demo counter` once more - it is idempotent.

## 5. Current stopping point

The deploy gets through: image pull, OCI bundle, **gVisor sandbox boot, container start** - then fails at the golden snapshot with `wakeup probe for "counter" never returned 200 within 30s`. Root cause: the counter process panics because a write-then-read of a file inside the gVisor sandbox is inconsistent (write reports success, read gets ENOENT, nothing lands in the host overlay upper). This looks like an upstream gVisor/RHCOS issue, not an OpenShift integration one - see challenge #6 in [openshift-challenges.md](openshift-challenges.md).

## 6. Next steps (once the sandbox issue is resolved)

Continue with the rest of the upstream tutorial, https://ate.dev/docs/tutorials/counter/ :

```bash
kubectl ate create actor my-counter-1 -a ate-demo-counter --template counter
kubectl ate proxy actor my-counter-1 -a ate-demo-counter   # serves on localhost:8000
curl -X POST -i http://localhost:8000/    # wake + increment; actor snapshots when idle
```

Then verify the headline claim: idle actors checkpoint to storage and resume with state intact in under 500ms.
