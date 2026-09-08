## Component Diagrams

These diagrams show which processes run where and how they communicate for each make target. 
Legend: 
- `[process]` = native OS process
- `[container]` = local Podman container
- `[pod]` = Kubernetes/OpenShift pod, parallelograms = external cloud services.

---

### make dev

```mermaid
graph TB
    subgraph local["Local Machine"]
        browser["Browser"]
        console["[container]\nOCP Console\n(:9000)"]
        plugin["[process]\nPlugin (webpack)\n(:9001)"]
        backend["[process]\nGo Backend\n(:8080)"]
    end

    subgraph gh["GitHub (cloud)"]
        ghapi[/"GitHub API\napi.github.com"/]
        ghactions[/"GitHub Actions\n(workflow runner)"/]
    end

    subgraph cluster["OpenShift Cluster"]
        kubeapi["Kube API Server"]
        knative["Knative / Functions"]
    end

    browser --> console
    console --> plugin
    console --> backend
    backend -- "push code,\nstore secrets" --> ghapi
    ghapi -- "push triggers" --> ghactions
    ghactions -- "func deploy\n(kubeconfig secret)" --> kubeapi
    kubeapi --> knative
    backend --> kubeapi
```

---

### make dev-fake-gh

```mermaid
graph TB
    subgraph local["Local Machine"]
        browser["Browser"]
        console["[container]\nOCP Console\n(:9000)"]
        plugin["[process]\nPlugin (webpack)\n(:9001)"]
        backend["[process]\nGo Backend\n(:9080)"]
        subgraph fgh["[process] fakegithub (:8090)"]
            fghapi["fakegithub API"]
            actrunner["act runner\n(-self-hosted)"]
            memstore["In-memory store\n(repos, git objects,\nsecrets, variables, runs)"]
        end
        funcdeploy["[process]\nfunc deploy"]
        lifecycle["[containers]\nCNB lifecycle\n(via Podman)"]
    end

    subgraph cluster["OpenShift Cluster"]
        kubeapi["Kube API Server"]
        registry["Image Registry"]
        knative["Knative / Functions"]
    end

    browser --> console
    console --> plugin
    console --> backend
    backend -- "gh-api-url=localhost:8090" --> fghapi
    fghapi --> memstore
    fghapi -- "UpdateRef triggers" --> actrunner
    actrunner --> memstore
    actrunner -- "runs on host" --> funcdeploy
    funcdeploy -- "build" --> lifecycle
    lifecycle -- "push image" --> registry
    funcdeploy -- "deploy\n(kubeconfig secret)" --> kubeapi
    kubeapi --> knative
    backend --> kubeapi
```

---

### make test-e2e

Runs Playwright tests against an already-running dev environment (either `make dev` or `make dev-fake-gh`). The environment determines whether a real or fake GitHub is used.

```mermaid
graph TB
    subgraph local["Local Machine (already running)"]
        console["[container]\nOCP Console\n(:9000)"]
        plugin["[process]\nPlugin (webpack)\n(:9001)"]
        backend["[process]\nGo Backend\n(:8080)"]
        fgh["[process]\nfakegithub\n(:8090)\n(only with dev-fake-gh)"]
    end

    subgraph test["Test Runner (Playwright)"]
        pw["[process]\nPlaywright\ntest suite"]
        seed["fakegithub.ts\nhelpers"]
    end

    pw -- "browser automation" --> console
    console --> plugin
    console --> backend
    seed -- "POST /_admin/seed\nPOST /_admin/reset" --> fgh
    backend --> fgh
```

---

### hack/builder-run.sh make e2e

Local equivalent of the Prow CI flow. Builds and runs a builder container that executes `make e2e` with a real cluster kubeconfig.

```mermaid
graph TB
    subgraph local["Local Machine"]
        sh["[process]\nbuilder-run.sh"]
        subgraph builder["[container]\nBuilder (Dockerfile.buildroot)"]
            pw["[process]\nPlaywright\ntest suite"]
            seed["fakegithub.ts\nhelpers"]
            pf["[process]\nkubectl port-forward\nlocalhost:8090"]
        end
    end

    subgraph cluster["OpenShift Cluster"]
        subgraph fghpod["[pod]\nfakegithub pod"]
            fghapi["fakegithub API"]
            actrunner["act runner\nFUNC_BUILDER=s2i"]
            memstore["In-memory store\n(repos, git objects,\nsecrets, variables, runs)"]
        end
        pluginpod["[pod]\nPlugin pod\n(backend + frontend)"]
        console["[pod]\nOCP Console"]
        kubeapi["Kube API Server"]
        knative["Knative / Functions"]
        s2ibuild["OpenShift Build\n(S2I)"]
        registry["Internal Registry"]
    end

    sh -- "builds + runs" --> builder
    pw -- "browser automation" --> console
    console --> pluginpod
    pluginpod -- "gh-api-url=fakegithub.svc:8090" --> fghapi
    seed -- "admin API" --> pf
    pf -- "port-forward" --> fghapi
    fghapi --> memstore
    fghapi -- "UpdateRef triggers" --> actrunner
    actrunner --> memstore
    actrunner -- "func deploy --builder=s2i" --> s2ibuild
    s2ibuild --> registry
    s2ibuild --> knative
    pluginpod --> kubeapi
    kubeapi --> knative
```

---

### make e2e (Prow CI only)

Runs inside a Prow job pod in the cluster farm. Identical cluster-side topology to `builder-run.sh make e2e`.

```mermaid
graph TB
    subgraph farm["cluster-x (from cluster farm)"]
        subgraph prow["[pod] Prow Job"]
            pw["[process]\nPlaywright\ntest suite"]
            seed["fakegithub.ts\nhelpers"]
            pf["[process]\nkubectl port-forward\nlocalhost:8090"]
        end
    end

    subgraph cluster["OpenShift Cluster (console-functions-plugin ns)"]
        subgraph fghpod["[pod]\nfakegithub pod"]
            fghapi["fakegithub API"]
            actrunner["act runner\nFUNC_BUILDER=s2i"]
            memstore["In-memory store\n(repos, git objects,\nsecrets, variables, runs)"]
        end
        pluginpod["[pod]\nPlugin pod\n(backend + frontend)"]
        console["[pod]\nOCP Console"]
        kubeapi["Kube API Server"]
        knative["Knative / Functions"]
        s2ibuild["OpenShift Build\n(S2I)"]
        registry["Internal Registry"]
    end

    pw -- "browser automation" --> console
    console --> pluginpod
    pluginpod -- "gh-api-url=fakegithub.svc:8090" --> fghapi
    seed -- "admin API" --> pf
    pf -- "port-forward" --> fghapi
    fghapi --> memstore
    fghapi -- "UpdateRef triggers" --> actrunner
    actrunner --> memstore
    actrunner -- "func deploy --builder=s2i" --> s2ibuild
    s2ibuild --> registry
    s2ibuild --> knative
    pluginpod --> kubeapi
    kubeapi --> knative
```

---

### make deploy-dev

```mermaid
graph TB
    subgraph local["Local Machine"]
        podman["[process]\npodman build"]
        pf["[process]\nport-forward\nlocalhost:5001"]
        browser["Browser"]
    end

    subgraph gh["GitHub (cloud)"]
        ghapi[/"GitHub API\napi.github.com"/]
        ghactions[/"GitHub Actions\n(workflow runner)"/]
    end

    subgraph cluster["OpenShift Cluster"]
        intreg["Internal Registry\n:5000"]
        helm["Helm deploy\n(oc apply)"]
        pluginpod["[pod]\nPlugin pod\n(backend + frontend)"]
        console["[pod]\nOCP Console"]
        kubeapi["Kube API Server"]
        knative["Knative / Functions"]
    end

    podman -- "push via port-forward" --> pf
    pf --> intreg
    intreg --> helm
    helm --> pluginpod
    browser --> console
    console --> pluginpod
    pluginpod -- "push code,\nstore secrets" --> ghapi
    ghapi -- "push triggers" --> ghactions
    ghactions -- "func deploy\n(kubeconfig secret)" --> kubeapi
    pluginpod --> kubeapi
    kubeapi --> knative
```
