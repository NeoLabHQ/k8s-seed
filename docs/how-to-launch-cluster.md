# How to launch a cluster

The runbook for seeding one Kubernetes cluster with Argo CD and handing it over
to the gitops repository. The procedure is identical for the main cluster and
for every spoke; the differences are listed at the end.

Budget about fifteen minutes, most of it waiting for pods.

## Before you start

You need a reachable cluster and a kubectl context pointing at it. The seed
does not create the cluster — use your provider's tooling, or `just kind-cluster`
for a throwaway local one.

Install these CLIs:

- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/)
- [helm-diff](https://github.com/databus23/helm-diff). Not optional.
  `helmfile apply` needs it just as `helmfile diff` does, so it is a
  prerequisite of `just bootstrap` and `just sync`, not only of `just diff`.
- [helmfile](https://github.com/helmfile/helmfile)
- [just](https://github.com/casey/just)
- `envsubst`, from GNU gettext. Present on most Linux distributions; on macOS
  `brew install gettext`.
- [kind](https://kind.sigs.k8s.io/), only if you want `just kind-cluster`.

Confirm you are pointed at the cluster you think you are:

```bash
just contexts
just current-context
```

This check is cheap and the mistake it prevents is not. Bootstrap is a one-time,
admin-credentialed, imperative operation; there is no dry run that tells you
afterwards which cluster you hit.

## Register the GitHub OAuth App

Argo CD authenticates users through the Dex bundled in its Helm chart, and Dex
delegates to GitHub. Each cluster needs its own GitHub OAuth App, because an
OAuth App allows exactly one callback URL and each cluster has its own hostname.

In your GitHub organisation, under **Settings → Developer settings → OAuth Apps**,
create a new app:

- **Homepage URL** — `https://<the hostname this cluster's Argo CD will use>`
- **Authorization callback URL** — the same hostname with `/api/dex/callback`
  appended

Generate a client secret and keep both values for the next step.

Note down the organisation name too. Out of the box the connector accepts any
GitHub account — everyone lands on the Argo CD login and, because default RBAC
is empty, gets no permissions once there. That is an unnecessarily wide
authentication boundary, so set `GITHUB_ORG` below to the organisation that owns
the app and Dex will turn away everyone outside it.

If you later move to a central Dex broker that fronts GitHub for every cluster,
you will not need one app per cluster any more. That migration is a change of
values, not of the seed: see `OIDC_ISSUER_URL` below.

## Fill in `.env`

Copy `.env.example` to `.env` and fill it in. Every field is documented in
place; the shape of it is:

- `TARGET_CLUSTER_NAME` — the only value that differs between clusters. It selects
  `clusters/<name>/` in the gitops repository.
- `GITOPS_REPO_URL`, `GITOPS_TARGET_REVISION`, and `GITOPS_REPO_USERNAME` /
  `GITOPS_REPO_PASSWORD` — the git credential Argo CD reads that repository
  with.
- `ARGO_HOST` — the hostname from the OAuth App you just registered.
- `OIDC_CLIENT_ID` and `OIDC_CLIENT_SECRET` — that app's credentials.
- `GITHUB_ORG` — the organisation allowed to sign in. Optional, but leaving it
  empty lets any GitHub account reach the login.
- `OIDC_ISSUER_URL` — leave empty. Setting it switches the bundled Dex off and
  trusts an external issuer instead.

There are no defaults for the values that matter, and a missing one always fails
before anything is created, so a botched `.env` cannot leave you
half-bootstrapped. Which message you get depends on who reads the value: the
chart values fail during template rendering with helmfile naming the variable,
while the credential and the root Application's parameters fail on a shell guard
in the recipe, as `TARGET_CLUSTER_NAME: set TARGET_CLUSTER_NAME in .env`.

## Run the bootstrap

```bash
just bootstrap
```

Four things happen:

1. `helmfile apply` creates the `argocd` namespace and installs the argo-cd
   Helm release, then the gitops repository credential Secret is applied.
2. The recipe waits for `argocd-server` to roll out.
3. `bootstrap/root-app.yaml` is applied — an Argo CD `Application` pointing at
   `clusters/$TARGET_CLUSTER_NAME/` in the gitops repository.
4. Argo CD syncs that path. Among the Applications it finds there is one that
   manages Argo CD itself. That is the handoff.

## Verify it

```bash
just verify
```

This asserts rather than reports: it waits for every Argo CD Deployment to go
available and then reads the root Application's sync status, exiting non-zero if
either is wrong. A clean run prints the workloads plus a `root` Application whose
`PATH` column reads `clusters/<your cluster name>`.

`Synced` and `Unknown` both pass. `Unknown` is not automatically a problem — see
the next section — whereas `OutOfSync` means Argo CD read the path and disagrees
with it, which is a real failure worth stopping on.

Get in with:

```bash
just argo-password   # the initial admin password
just argo-ui         # port-forward to http://localhost:8080
```

### Day 0 has no ingress, and that is correct

Port-forwarding is the only way to reach Argo CD after bootstrap, and the admin
password is the only way to log in. This is not a broken installation.

Ingress needs an ingress controller and certificates need cert-manager, and
neither is part of the seed — they arrive from the gitops repository, which
Argo CD has only just started reconciling. SSO has the same dependency: the
GitHub callback URL points at `ARGO_HOST`, which does not resolve to anything
until DNS and ingress exist.

Once the gitops repository has delivered ingress-nginx, cert-manager and
external-dns, `https://$ARGO_HOST` starts working and SSO with it. Until then,
`just argo-ui` is the supported path.

Note also that signing in through GitHub will initially grant no permissions at
all. Argo CD's default RBAC policy is empty, and mapping your GitHub org or team
to a role is part of the Argo CD configuration the gitops repository owns.

### When the root Application sits `Unknown`

`Unknown` means Argo CD could not determine the desired state. There are two
very different reasons, and they are easy to tell apart.

Ask the Application itself first — it records the reason:

```bash
kubectl get application root --namespace argocd \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
```

**The gitops repository has nothing at that path yet.** The message reads
`clusters/<name>: app path does not exist`. Expected on a fresh gitops
repository, and it resolves itself the moment you commit `clusters/<name>/`.
Nothing is wrong with the seed.

**Argo CD cannot reach the repository at all.** A wrong URL, an expired token, a
credential for a different repository. The message names the failure instead —
`authentication required`, `repository not found`, a host that will not resolve.
The same errors appear where the fetch actually happens:

```bash
kubectl logs deployment/argocd-repo-server --namespace argocd
```

A missing path produces no error there, so the two are easy to tell apart.

Immediately after bootstrap you may also see a transient
`connection refused ...:8081` — that is the application controller reaching
argocd-repo-server before it finished starting. Force a re-check rather than
reading a stale condition:

```bash
kubectl annotate application root --namespace argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

You can also ask Argo CD what credentials it believes it has. Port-forward the
API with `just argo-ui`, log in with the admin password, and run:

```bash
argocd repo list
```

The repository should be listed with `STATUS` `Successful`. If it is missing,
the credential Secret did not apply; if it is listed as `Failed`, the credential
is wrong.

## The handoff is one-way

Once Argo CD manages itself, **never run `just bootstrap` against this cluster
again.**

After the handoff two things claim ownership of the same resources: the Helm
release created here, and the Argo CD Application in the gitops repository.
They agree only as long as the chart version and values match exactly. Running
bootstrap again re-asserts whatever is in this repository's `.env` and
`helmfile.yaml` at that moment, and if that has drifted from gitops the two
will overwrite each other in a loop.

`just bootstrap` refuses if it finds a self-managed `argocd` Application, so the
mistake is hard to make by accident. To change Argo CD on a bootstrapped
cluster, change its version or values in the gitops repository.

`just sync` and `just diff` run helmfile alone and are useful **before** the
handoff — while you are still iterating on the seed on a throwaway cluster.
After the handoff they carry the same hazard as bootstrap.

## Main cluster versus a spoke

The procedure above does not change. The only difference in this repository is
`TARGET_CLUSTER_NAME`.

Everything that actually distinguishes the main cluster lives in the gitops
repository: `clusters/main/` additionally carries Kargo, which the spokes do not
run. The seed is deliberately identical everywhere, so that per-cluster variation
lives where it can be reviewed as a diff and reconciled continuously, rather
than in an imperative script run once from somebody's laptop.
