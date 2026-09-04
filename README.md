# k8s-seed

The seed for a Kubernetes cluster: install Argo CD, point it at a gitops
repository, hand over.

That is the whole scope. This repository does not install ingress, certificates,
monitoring, databases or applications. It installs the one thing that cannot
install itself, and then stops.

## The split rule

**k8s-seed contains only what cannot be reconciled by Argo CD, because it must
exist before Argo CD does.** Everything else belongs in the gitops repository.

The reasoning is about where change is safe. The bootstrap path here is
imperative, human-run, and uses admin credentials. It is not reconciled, not
drift-detected, and not reviewable as a diff against live state. Every piece of
per-cluster branching placed here is logic that silently rots. Bootstrap runs
once per cluster; gitops runs continuously — so anything that needs upgrading
without re-running a CLI from a laptop against production belongs in gitops,
where ApplicationSets and overlays are built for exactly that.

The irreducible seed is three things:

- the `argo-cd` Helm release,
- the Secret holding the gitops repository credential — a GitHub App,
- the root `Application`, pointing at `generated/clusters/<TARGET_CLUSTER_NAME>/`.

## Layout

```
helmfile.yaml                      the argo repository, one release, one environments block
bootstrap/
  argocd-values.yaml.gotmpl        chart values, rendered by helmfile as a Go template
  repo-secret.yaml                 gitops repository credential
  root-app.yaml                    root Application -> generated/clusters/<TARGET_CLUSTER_NAME>/
docs/
  how-to-launch-cluster.md         the operational runbook
  gitops-repo.md                   what this repository expects of the gitops repository
justfile
.env.example
README.md
```

## Architecture

Every cluster runs its own Argo CD and self-manages from its own path in a shared
gitops repository: a main cluster, which also hosts Kargo, plus dev, staging and
per-white-label production clusters. No cluster reaches another's Kubernetes API.

Because the seed has to be identical on every one of them, exactly one value here
is per-cluster: **`TARGET_CLUSTER_NAME`**, which selects
`generated/clusters/<name>/`. Everything else — the gitops repository URL and
credential, and the Argo CD hostname — is environment configuration, not
topology.

The bootstrap sequence is four steps, and `just bootstrap` keeps all four
visible rather than hiding the last one in a lifecycle hook:

1. `helmfile apply` — namespace, argo-cd release, then the repository credential
2. wait for `argocd-server`
3. `kubectl apply -f bootstrap/root-app.yaml`
4. Argo CD syncs `generated/clusters/<TARGET_CLUSTER_NAME>/`, which contains the
   Application that manages Argo CD itself — handoff complete

After step 4 the cluster manages itself and **bootstrap must never be run against
it again**. See [docs/how-to-launch-cluster.md](docs/how-to-launch-cluster.md).

### Critical

`kubectl` uses `TARGET_CLUSTER_NAME` for the current cluster context, while this .env file and bootstrap script use `TARGET_TARGET_CLUSTER_NAME`, to avvoid collision of it for local development. But for production clusters they must be the same!

## Requirements

Create kubernetes cluster version and configure [kubectl](https://kubernetes.io/docs/tasks/tools/) for connect to it.

Install CLIs:

* [Helm](https://helm.sh/) - The package manager for Kubernetes.
* [Helm Diff](https://github.com/databus23/helm-diff) - A helm plugin that shows a diff explaining what a helm upgrade would change
* [Hemlile](https://github.com/roboll/helmfile) - One file for manage multiple heml charts.
* [Justfile](https://github.com/casey/just) - install by `cargo install just`
* [k3d](https://k3d.io/) - install by `brew install k3d` - for local development

## Usage

```bash
cp .env.example .env    # then fill it in
just bootstrap          # seed the cluster and hand it over
just verify             # assert Argo CD is healthy and the root Application is in a sane state
just argo-password      # day-0 admin password
just argo-ui            # port-forward the UI to http://localhost:8080
```

`just --list` shows the rest. `just contexts` and `just current-context` are
worth running before `just bootstrap`.

Full walkthrough, including registering the GitHub App that reads the gitops
repository, and reading the failure modes:
**[docs/how-to-launch-cluster.md](docs/how-to-launch-cluster.md)**.

What the gitops repository has to provide for any of this to be useful:
**[docs/gitops-repo.md](docs/gitops-repo.md)**.

## Modifying it

**Adding a component?** It almost certainly goes in the gitops repository, not
here. The bar for adding anything to this repository is that Argo CD cannot
install it, because Argo CD does not exist yet.

**Changing Argo CD's configuration** means editing
`bootstrap/argocd-values.yaml.gotmpl`, and then making the matching change in the
gitops repository's self-management Application. The two must stay equivalent —
if the seeded release and the Application that adopts it disagree on chart
version or values, they will fight over the same resources. `helmfile.yaml` pins
a literal chart version, never a range, so that it can be matched exactly.

**Adding a parameter** starts with asking which of the two consumers reads it,
because they are wired up in different files and fail in different places. Both
kinds also go in `.env.example`.

*Chart values* — anything `bootstrap/argocd-values.yaml.gotmpl` reads — go in the
`environments` block of `helmfile.yaml`. Use `requiredEnv` unless a default is
genuinely correct; `env | default` is how a production cluster gets silently
seeded at `argo.k8s.local` pointing at no gitops repository. Required values fail
during rendering, before anything touches the cluster.

*Manifest values* — anything `bootstrap/repo-secret.yaml` or
`bootstrap/root-app.yaml` reads as `${VAR}` — never reach helm at all. They are
expanded by the `envsubst` call in the applying recipe, so add the name to that
recipe's substitution list and guard it there with `: "${VAR:?set VAR in .env}"`.
The guard is not optional: `envsubst` turns an unset or empty variable into the
empty string and exits 0, so without it the manifest reaches the cluster
structurally valid and quietly blank. `GITOPS_REPO_GITHUB_APP_ID`,
`GITOPS_REPO_GITHUB_APP_INSTALLATION_ID`,
`GITOPS_REPO_GITHUB_APP_PRIVATE_KEY_PATH` and `GITOPS_TARGET_REVISION` are this
kind. `GITOPS_REPO_URL` is deliberately both — guarded in the recipes *and*
declared `requiredEnv`, so a bare `helmfile apply` catches it too.

*Multi-line values* do not go in `.env` at all. `envsubst` expands into YAML it
does not parse, so a substituted blob with newlines in it lands with its
continuation lines at column zero and the manifest stops parsing. The GitHub App
private key is the case in point: `.env` carries the *path* to the `.pem` file,
and `_apply-repo-secret` reads it, base64-encodes it to one line, and substitutes
that into `data:` — where the API server decodes it back to the original bytes.
Anything else multi-line should follow the same route.

**Checking a change without a cluster:**

```bash
# renders the chart with your .env
helmfile template

# validates the static manifests, Application CRD included
CRDS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
for f in bootstrap/*.yaml; do
  envsubst < "$f" | kubeconform -strict -schema-location default -schema-location "$CRDS" -
done
```

Rendering with a required variable unset should fail. That is the fail-fast
behaviour working, not a bug.

## Authentication

The seed installs an **admin-account-only** Argo CD. It configures no SSO
whatsoever — no issuer, no client credentials, and, most importantly, no Dex.
The gitops repository owns 100% of SSO.

That is not deferred work. SSO cannot function at bootstrap: the redirect URI is
built from `ARGO_HOST`, which resolves to nothing until the gitops repository has
delivered ingress, DNS and certificates, and where a central broker is the
issuer, the broker is itself a workload that repository deploys, with a client
secret that arrives alongside it. Day-0 access is `just argo-password` and
`just argo-ui`.

Seeding SSO also caused a real outage, which is why
`bootstrap/argocd-values.yaml.gotmpl` sets `dex.enabled: false` unconditionally
and marks that line load-bearing. Argo CD three-way merges `argocd-cm` and prunes
only the keys its own Application declares, so a `dex.config` written by the seed
survives the handoff. The cluster then holds the seed's `dex.config` next to the
gitops repository's `oidc.config`: sign-in follows `oidc.config` and succeeds,
while every subsequent session-token check follows the bundled Dex and fails, so
users log in and land straight back on the login page. Deleting the `dex:` block
as redundant would bring the fault back, because the argo-cd chart defaults
`dex.enabled` to true.

Clusters seeded before this change still carry that `dex.config` and an
`argocd-dex-server` Deployment. The seed no longer creates either, and nothing
removes what an older seed already created —
[docs/how-to-launch-cluster.md](docs/how-to-launch-cluster.md#sso-signs-in-and-then-drops-you)
has the one-off repair.

How Argo CD reads the gitops repository is a different question, and that *is*
seeded, because the root Application cannot clone without it: a **GitHub App**,
installed on the repository with `Contents: Read-only`, whose App ID,
installation ID and private key make up `bootstrap/repo-secret.yaml`. It signs no
humans in; it is the identity Argo CD itself clones with, and the only GitHub
registration this seed asks for.

Authorisation belongs to the gitops repository as well, and the seed grants none
of it: Argo CD's default RBAC policy is empty. Mapping a GitHub org or team to a
role is part of the Argo CD configuration the gitops repository owns.

## Prior art

The app-of-apps shape here is inspired by
[kubefirst](https://github.com/konstructio/kubefirst), which provisions
considerably more. This is not an attempt to replace it: the aim is a minimal
base with minimal maintenance, sized to requirements kubefirst is not going to
satisfy for us.
