---
title: Refactor project to app-of-apps pattern
---

## Initial User Prompt

refactor project to app-of-apps pattern

### Context

This project is for of highly outdated and not maintained project. It's not used in production.

But it provides usefull blueprint for bootstrap of base k8s cluster that we need.

### Goal

Taking inspiration from https://github.com/konstructio/kubefirst project, this project should be refactored to provide app-of-apps pattern.

### Requirements

#### Target topology (context for the split, not scope of this task)

The eventual architecture is **ArgoCD per cluster**: a main cluster (also hosting Kargo) plus
dev, staging, and per-white-label production clusters. Every cluster self-manages via its own
ArgoCD, pointed at its own path in a shared `gitops` repository. No cross-cluster Kubernetes API
access is assumed.

**This task delivers the seed for one cluster only.** Multi-cluster wiring is a later task. But
because the seed must be *identical* on every cluster, the design below must not bake in any
assumption that only holds for the main cluster.

Parked for the later multi-cluster task: with per-cluster ArgoCD, Kargo on main will need to
either reach spoke ArgoCD APIs for `argocd-update`, or fall back to pure git-commit promotion.
Do not encode either choice into k8s-seed now.

#### The split rule

k8s-seed contains **only what cannot be reconciled by ArgoCD, because it must exist before
ArgoCD does.** Everything else belongs in the `gitops` repository.

The bootstrap path is imperative, human-run, and uses admin credentials. It is not reconciled,
not drift-detected, and not reviewable as a diff against live state. Every piece of per-cluster
branching placed there is logic that silently rots. Per-cluster variation belongs in gitops,
where ApplicationSets and overlays are built for it.

Bootstrap runs once per cluster; gitops runs continuously. Anything that needs upgrading without
re-running a CLI from a laptop against production belongs in gitops.

#### What this repository contains after the refactor

```
k8s-seed/
  helmfile.yaml                     argo-cd release only (Dex bundled via chart)
  bootstrap/
    argocd-values.yaml.gotmpl       chart values, rendered by helmfile
    repo-secret.yaml                gitops repo credential
    root-app.yaml                   root Application -> clusters/<CLUSTER_NAME>/
  docs/
    how-to-launch-cluster.md
    gitops-repo.md
  justfile
  .env.example
  README.md
```

The irreducible seed is three things: the `argo-cd` Helm release, the gitops repo credential
Secret, and the root Application.

**One per-cluster variable: `CLUSTER_NAME`.** Everything else is environment configuration, not
topology: `GITOPS_REPO_URL`, `ARGO_HOST`, GitHub OAuth client id/secret, git credential.

#### Removals

- Remove kubernetes dashboard, cert-manager, kube-prometheus-stack, loki-stack,
  tempo-distributed, strimzi, provectuslab-kafka-ui, mongo-express, redisinsight, eventrouter.
- Remove every other release in `helmfile.yaml` except argocd (kong, mongodb, stackgres, redis).
- Delete `helmfile.dev.yaml`.
- Delete `manifests/` (eventrouter, stackgres profiles, redisinsight, kong operator patch, cors,
  volume).
- Delete `certificate/` — ClusterIssuers follow cert-manager into the gitops repo.
- Delete `applications/` — `identity-manager` and `channel-binder` are business applications and
  belong in the apps repository, reached via gitops.
- Delete `rbac/cluster-admin.yaml`.
- Delete `Makefile`.

#### ArgoCD and authentication

- Keep ArgoCD, pinned to a **current stable chart version verified at implementation time**. Do
  not carry over `^3.11.1` (v2.1 era, years stale).
- Use the **Dex bundled in the argo-cd chart** (`dex.enabled`) for GitHub authentication — zero
  extra components. Configure real SSO via a `dex.config` block in `configs.cm`.
- Note: the current `configs.secret.githubSecret` is the *webhook* secret, not OAuth. This
  repository has never actually done SSO.
- Write the OIDC configuration so the **issuer is a parameter**, so it can later be repointed at
  a central Dex broker without reshaping the seed. Today this means one GitHub OAuth App per
  cluster (OAuth Apps allow a single callback URL).

#### Tooling

- **Keep helmfile.** Keep `helmfile.yaml` thin: the `argo` repository, one release, and an
  `environments:` block for defaults.
- Move chart configuration into `bootstrap/argocd-values.yaml.gotmpl`, rendered natively by
  helmfile as a Go template. The current single 300-line `helmfile.yaml` with inline templating
  is the anti-pattern to avoid.
- Use **`requiredEnv`** for values with no safe default (`CLUSTER_NAME`, `GITOPS_REPO_URL`,
  `ARGO_HOST`, GitHub client id/secret). The current `{{ env "X" | default "..." }}` style is how
  a production cluster gets silently deployed at `argo.k8s.local` pointing at no gitops repo.
  Keep `default` only where a default is genuinely correct.

#### Bootstrap sequence (`just bootstrap`)

1. `helmfile apply` — namespace, repo credential Secret, argo-cd release
2. Wait for `argocd-server` to become ready
3. `kubectl apply -f bootstrap/root-app.yaml`
4. ArgoCD syncs `clusters/<CLUSTER_NAME>/`, which includes the Application that manages ArgoCD
   itself — handoff complete

Keep this sequencing visible in the justfile. Helmfile could run step 3 as a `postsync` hook, but
that hides the most important step in the flow.

**Sharp edge to design around:** at step 4 the gitops Application adopts resources Helm already
owns. Adoption is clean only if chart version and values match the seed; otherwise the Helm
release and ArgoCD fight. This is why `gitops-repo.md` must state the version-matching
requirement and why bootstrap must never be re-run after handoff.

#### Documentation

Replace the single `getting-started.md` from the original prompt with two targeted documents.
Both are **prose only** — guide, requirements, expectations, recommendations. No copy-pasteable
manifests for gitops-repo content; that would be a second source of truth that rots as soon as
the real gitops repo diverges.

**`docs/how-to-launch-cluster.md`** — operational runbook, same procedure for main or any spoke:

- Prerequisites: reachable cluster and kubectl context; CLIs (helm, helm-diff, helmfile, just)
- Registering the GitHub OAuth App for this cluster and its callback URL
- Filling `.env`
- Running bootstrap and verifying it
- Day-0 access is port-forward only — no ingress until gitops delivers ingress-nginx and
  cert-manager. State this explicitly so it does not read as a failure.
- The handoff: once ArgoCD self-manages, never re-run bootstrap against this cluster
- What differs between main and a spoke: only `CLUSTER_NAME`, plus the fact that main's gitops
  path also carries Kargo

**`docs/gitops-repo.md`** — the contract this repository expects the gitops repository to satisfy:

- Required layout `clusters/<name>/`, and what the root Application resolves.
  **Cluster-scoped from day one**, even with one cluster — a flat layout forces a path migration
  when dev arrives.
- What a cluster needs to be usable: cert-manager, ingress-nginx, external-dns, ArgoCD
  self-management, Argo Rollouts; Kargo on main
- Ordering expectations — CRDs and cert-manager before dependents (sync waves)
- Why the self-managed ArgoCD chart version must match what was seeded
- What does *not* belong there: business applications go in the apps repository

**Amends the original requirement "Add Argo Rollouts and Kargo":** this repository does not
install them. They are gitops-repo responsibilities, *documented* in `gitops-repo.md`. No Rollouts
or Kargo manifests ship here.

#### Update README

Explain the new architecture, the split rule, how to use and how to modify it. Point at the two
docs rather than duplicating them.

#### Migrate Makefile to justfile

**Amends the original requirement "copy all existing commands from makefile":** taken literally
this is now wrong — roughly 90% of the targets reference services this refactor deletes. Port the
commands that still have a referent; delete the rest along with the services they served.

Dropped with their services: `apply-base` / `apply-dev-base` chains, `create-dashboard-role`,
`apply-cors`, `apply-dev-cors`, `apply-redisinsight`, `apply-eventrouter`,
`save-stackgres-profiles`, `apply-kong-operator-for-minikube`, `certificate-issuer-*`,
`update-admin-role`, `apps`, `proxy-dashboard`, `proxy-grafana`.

Dropped as business concerns: `save-wasabi-creds`, `save-amocrm-creds`, `save-chatapi-creds`,
`save-mongodb-creds`, `save-redis-creds`, `save-docker-hub-creds`. These are business application
secrets created imperatively from `.env`; they follow the business apps to the apps repository,
ideally behind a real secret manager rather than `kubectl create secret`.

Ported, adapted:

- `sync` → `just bootstrap` (full seed) and `just sync` (helmfile apply only)
- `contexts` / `current-context` → keep; a valuable "am I about to bootstrap the wrong cluster"
  check
- `proxy-argo` → `just argo-ui`, **fixed**: it hardcodes pod name `argocd-server-7cc6fc47d7-bs8rg`
  and broke the first time that pod restarted. Port-forward the service instead.
- `minikube` / `local` → a local test-cluster target; prefer kind over minikube

New:

- `bootstrap`, `diff`, `argo-password` (initial admin secret, needed on day 0 before SSO works),
  `verify` (ArgoCD healthy + root app synced)

Other justfile work:

- `set dotenv-load := true` replaces the Makefile's include/export block
- Keep the existing devcontainer recipes
- Fix `down-devcontainer` — it references project `decision-engine_devcontainer` and a
  `.devcontainer/docker-compose.yaml` that does not exist
- Delete `Makefile`

Rewrite `.env.example` down to the seed parameters only.

#### Failure modes to handle explicitly

- **Missing required parameter** — `requiredEnv` fails during render, before anything touches the
  cluster. No half-bootstrapped state.
- **Gitops repo unreachable, or `clusters/<name>/` missing** — root Application goes `Unknown`. On
  a fresh gitops repo this is *expected*; the runbook must explain how to distinguish it from a
  credential failure (repo-server logs, `argocd repo list`).
- **Re-running bootstrap after handoff** — guard it: `just bootstrap` checks for an existing
  self-managed `argocd` Application and refuses, directing the operator to change the version in
  gitops instead.
- **Day-0 has no ingress** — documented, not a bug.

#### Verification

1. `helmfile template` with a full parameter set — catches `.gotmpl` and chart-values errors with
   no cluster at all
2. The same render with a required variable unset — must fail, proving fail-fast works
3. `kubeconform` over `bootstrap/*.yaml`
4. End-to-end on kind: `just bootstrap` → ArgoCD healthy, root Application created and pointing at
   the correct path. Without a real gitops repo it sits `Unknown`, which is the correct result and
   confirms steps 1–4 of the bootstrap sequence.

No CI exists in the repository today and adding it is out of scope for this task, though steps
1–3 are a few lines if wanted later.

Special note: while kubefirst project provides much more infrustructure, we have different requirements, that he not will satisfy in future. But this is not attempt to replace him, rather provide minimal base, with minimal in maintance efforts.
