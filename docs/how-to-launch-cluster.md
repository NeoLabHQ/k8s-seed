# How to launch a cluster

The runbook for seeding one Kubernetes cluster with Argo CD and handing it over
to the gitops repository. The procedure is identical for the main cluster and
for every spoke; the differences are listed at the end.

Budget about fifteen minutes, most of it waiting for pods.

## Before you start

You need a reachable cluster and a kubectl context pointing at it. The seed
does not create the cluster — use your provider's tooling, or
`just create-local-cluster` for a throwaway local one. That recipe creates a
k3d cluster and switches your kubectl context to it, named `k3d-<name>`
(`k3d-k8s-seed` by default); delete it again with `just delete-local-cluster`.

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
- [k3d](https://k3d.io/), only if you want `just create-local-cluster`.

Confirm you are pointed at the cluster you think you are:

```bash
just contexts
just current-context
```

This check is cheap and the mistake it prevents is not. Bootstrap is a one-time,
admin-credentialed, imperative operation; there is no dry run that tells you
afterwards which cluster you hit.

## Register the GitHub App

Argo CD clones the gitops repository as a GitHub App, per
[the Argo CD GitHub App credential docs][argocd-github-app]. One app can serve
every cluster: it has no callback URL and nothing else that is per-cluster. It is
also the only GitHub registration this seed asks for — the seed configures no
SSO, so there is no OAuth App to register alongside it.

[argocd-github-app]: https://argo-cd.readthedocs.io/en/stable/user-guide/private-repositories/#github-app-credential

In the organisation that owns the gitops repository, under **Settings → Developer
settings → GitHub Apps → New GitHub App**
([docs](https://docs.github.com/en/apps/creating-github-apps/setting-up-a-github-app/creating-a-github-app)):

- **Where can this GitHub App be installed?** — *Only on this account*.
- **Webhook** — deselect *Active*. The app only clones; it needs no events.
- **Permissions** — *Repository permissions → Contents: Read-only*, and nothing
  else. Argo CD's wording: "Ensure your application has at least `Read-only`
  permissions to the `Contents` of the repository. This is the minimum
  requirement." ([docs][argocd-github-app]). GitHub names the same one from its
  side, in [choosing permissions for a GitHub App][gh-permissions]: "If you want
  your app to use an installation or user access token to authenticate for
  HTTP-based Git access, you should request the `Contents` repository
  permission."

  Leave the Metadata permission at whatever GitHub selects: neither page states
  that it is mandatory, so this runbook neither asserts it nor tells you to
  lower it.

  If you later reuse this app for something else — the ApplicationSet Pull
  Request generator, GitHub notifications, anything that writes back — see
  ["Beyond the minimum permission"](#beyond-the-minimum-permission) below, one
  sourced entry per feature, because no upstream page collects them.

[gh-permissions]: https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app

Then, from the app's page:

1. **Generate a private key** under *Private keys*. GitHub downloads a `.pem`
   and keeps only the public half, so that file is the only copy —
   [managing private keys][gh-private-keys]. Save it outside this repository.
2. **Install App** on the account, choosing *Only select repositories* → the
   gitops repository — [installing your own GitHub App][gh-install]. Note that
   "The app will always have at least read-only access to all public
   repositories on GitHub" ([docs][gh-install]), so this step narrows private
   access only.
3. Note the **App ID** from the app's settings page. It is not the Client ID
   shown beside it: "The app ID is different from the client ID"
   ([docs][gh-install-token]).
4. Note the **installation ID**, the number at the end of the installation's
   settings URL, `https://github.com/organizations/<org>/settings/installations/<id>`.
   The documented route is the REST API — `GET /orgs/{org}/installation` and
   friends ([docs][gh-install-token]) — which needs the app's own JWT; the URL
   is the practical one.

   This repository asks for the installation ID by choice, not because Argo CD
   requires it. Of the CLI equivalent, Argo CD says: "The
   `--github-app-installation-id` flag is optional. If omitted, Argo CD will
   automatically discover the installation ID based on the repository's
   organization." ([docs][argocd-github-app]). That sentence is about the flag;
   nothing found says the Secret field may be omitted. Setting it explicitly
   costs one lookup and removes the discovery step from the bootstrap path, so
   this seed asks for it.

[gh-private-keys]: https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps
[gh-install]: https://docs.github.com/en/apps/using-github-apps/installing-your-own-github-app
[gh-install-token]: https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app

Nothing in this repository ever stores the key itself — `.env` holds the path to
the `.pem`, not the key. A PEM is multi-line, and the road from `.env` to the
Secret is not: even where a quoted multi-line value survives dotenv parsing,
`envsubst` expands into YAML that it does not parse, so the second and every
later line of the PEM would land at column zero and the manifest would stop
parsing. `just bootstrap` reads the file and encodes it to a single base64 line
instead, so the exact bytes reach the Secret and the key is never re-typed,
re-quoted or re-indented on the way.

### Beyond the minimum permission

No single page enumerates the full set. Argo CD's feature pages name no
permissions at all, so each entry below pairs the Argo CD page that says what a
feature calls with GitHub's endpoint reference,
[permissions required for GitHub Apps][gh-rest-permissions], which lists every
REST endpoint under the permission and access level it requires. Grant one only
when you switch that feature on, and only if you reuse this app for it.

[gh-rest-permissions]: https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps

- **ApplicationSet Pull Request generator** — Pull requests: Read-only. It "uses
  the API of an SCMaaS provider (GitHub, Gitea, or Bitbucket Server) to
  automatically discover open pull requests within a repository" and
  authenticates with "A `Secret` name containing a GitHub App secret in
  repo-creds format", which is this Secret's format —
  [the Pull Request generator docs][argocd-pr-generator]. That page names no
  permission. The call it must make, `GET /repos/{owner}/{repo}/pulls`, is
  listed in the reference under Repository permissions for "Pull requests" at
  access `read`.

  [argocd-pr-generator]: https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Pull-Request/

- **ApplicationSet SCM Provider generator** — nothing beyond the baseline could
  be established. It "uses the GitHub API to scan an organization in either
  github.com or GitHub Enterprise" — [the SCM Provider generator docs][argocd-scm-provider]
  — and its scan, `GET /orgs/{org}/repos`, is listed under Metadata at access
  `read` — the Metadata permission described above, left as GitHub sets it.
  Filtering repositories by file reads
  `GET /repos/{owner}/{repo}/contents/{path}`, listed under Contents at access
  `read`, which is already granted.

  [argocd-scm-provider]: https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-SCM-Provider/

- **Notifications to GitHub** — depends on what you send, and Argo CD says only
  "Change repository permissions to enable write commit statuses and/or
  deployments and/or pull requests comments" —
  [the notifications GitHub service docs][argocd-notifications-github]. In the
  reference those three are `POST /repos/{owner}/{repo}/statuses/{sha}` under
  Commit statuses at access `write`; `POST /repos/{owner}/{repo}/deployments`
  under Deployments at access `write`; and
  `POST /repos/{owner}/{repo}/issues/{issue_number}/comments`, which is listed
  under both Issues and Pull requests at access `write` and flagged there as
  needing additional permissions. Which of those two suffices for a comment is
  not something these pages settle — verify it against the notifications you
  configure rather than granting both.

  [argocd-notifications-github]: https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/services/github/

- **Anything that writes to the gitops repository through this app** —
  Contents: Read and write, because `PUT /repos/{owner}/{repo}/contents/{path}`
  is listed under Contents at access `write`. Argo CD itself never writes. For
  a tool that pushes with git instead of the contents API —
  argocd-image-updater's git write-back is the common one — no page was found
  stating the level git push requires, so confirm it before assuming
  Read-only is enough or that write is.

- **GitHub Enterprise Server** is not a permission but an extra Secret field,
  `githubAppEnterpriseBaseUrl` — see `bootstrap/repo-secret.yaml`.

## Fill in `.env`

Copy `.env.example` to `.env` and fill it in. Every field is documented in
place; the shape of it is:

- `TARGET_CLUSTER_NAME` — the only value that differs between clusters. It selects
  `generated/clusters/<name>/` in the gitops repository.
- `GITOPS_REPO_URL` and `GITOPS_TARGET_REVISION` — where the gitops repository
  is and which revision to track. The URL must be the HTTPS one; a GitHub App
  authenticates git over HTTP, not SSH.
- `GITOPS_REPO_GITHUB_APP_ID`, `GITOPS_REPO_GITHUB_APP_INSTALLATION_ID` and
  `GITOPS_REPO_GITHUB_APP_PRIVATE_KEY_PATH` — the GitHub App you just
  registered. The last one is the path to the `.pem`, not its contents; the
  recipe reads and encodes the file, so nothing multi-line ever goes in `.env`.
- `ARGO_HOST` — the hostname this cluster's Argo CD will answer on. It becomes
  `global.domain` in the chart and the Argo CD external URL. It does not resolve
  until the gitops repository has delivered ingress and DNS.

There is deliberately nothing about SSO in `.env`. The seed installs an
admin-account-only Argo CD and the gitops repository owns 100% of SSO — the
issuer, the client credentials and the RBAC that follows them. See
[Authentication](../README.md#authentication).

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
   `generated/clusters/$TARGET_CLUSTER_NAME/` in the gitops repository.
4. Argo CD syncs that path. Among the Applications it finds there is one that
   manages Argo CD itself. That is the handoff.

The handoff transfers ownership; it does not clean up after the seed. That is
why the seed configures no SSO at all: anything it wrote into `argocd-cm` would
outlive the handoff and sit alongside whatever the gitops repository configures
later — see
[SSO signs in and then drops you](#sso-signs-in-and-then-drops-you) for the
failure that produced on clusters seeded by older versions.

## Verify it

```bash
just verify
```

This asserts rather than reports: it waits for every Argo CD Deployment to go
available and then reads the root Application's sync status, exiting non-zero if
either is wrong. A clean run prints the workloads plus a `root` Application whose
`PATH` column reads `generated/clusters/<your cluster name>`.

`Synced` and `Unknown` both pass. `Unknown` is not automatically a problem — see
the next section — whereas `OutOfSync` means Argo CD read the path and disagrees
with it, which is a real failure worth stopping on.

Get in with:

```bash
just argo-password   # the initial admin password
just argo-ui         # port-forward to http://localhost:8080
```

### Day 0 has no ingress and no SSO, and that is correct

Port-forwarding is the only way to reach Argo CD after bootstrap, and the admin
password is the only way to log in. This is not a broken installation.

Ingress needs an ingress controller and certificates need cert-manager, and
neither is part of the seed — they arrive from the gitops repository, which
Argo CD has only just started reconciling. SSO belongs to that repository too,
and it has the same dependency whichever issuer it picks: a redirect URI points
at `ARGO_HOST`, which does not resolve to anything until DNS and ingress exist.

Once the gitops repository has delivered ingress-nginx, cert-manager and
external-dns, `https://$ARGO_HOST` starts working, and SSO follows once that
repository configures it. Until then, `just argo-ui` and the admin account are
the supported path.

Note also that a user who does eventually sign in gets no permissions at all to
begin with. Argo CD's default RBAC policy is empty, and mapping your GitHub org
or team to a role is part of the Argo CD configuration the gitops repository
owns.

### When the root Application sits `Unknown`

`Unknown` means Argo CD could not determine the desired state. There are two
very different reasons, and they are easy to tell apart.

Ask the Application itself first — it records the reason:

```bash
kubectl get application root --namespace argocd \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
```

**The gitops repository has nothing at that path yet.** The message reads
`generated/clusters/<name>: app path does not exist`. Expected on a fresh gitops
repository, and it resolves itself once that repository's generator has produced
`generated/clusters/<name>/` — that tree is generated rather than hand-authored,
so this is something to run or wait for on the gitops side, not a directory you
create by hand. Nothing is wrong with the seed.

**Argo CD cannot reach the repository at all.** A wrong URL, a GitHub App that
was never installed on this repository or has lost its `Contents: Read-only`
permission, a revoked private key, an App ID or installation ID belonging to
something else. The message names the failure instead —
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

### SSO signs in and then drops you

**This is a repair for a legacy cluster.** The current seed cannot produce this
state: it configures no SSO and sets `dex.enabled: false`, so it creates neither
the ConfigMap key nor the Deployment below. Clusters seeded before that change
still carry both, and nothing removes them automatically — this is how they are
fixed.

You reach GitHub, authorise, come back to Argo CD and land on the login page,
logged out. The server log shows the sign-in succeeding and the very next
request failing:

```bash
kubectl logs deployment/argocd-server --namespace argocd | grep -i "verify session"
```

`failed to verify provider token: token verification failed for all audiences`
next to a successful `Web login successful` means Argo CD is signing users in
against one issuer and verifying their session tokens against another. Check
whether `argocd-cm` holds both keys:

```bash
kubectl get configmap argocd-cm --namespace argocd -o yaml \
  | grep -E '^  (oidc|dex)\.config:'
```

Two lines is the fault: the bundled Dex takes the verification path regardless of
which issuer the login used. It happens on a cluster that an older seed gave a
`dex.config` and a bundled Dex of its own, and that the gitops repository later
moved onto a central broker. The handoff leaves both the key and the Deployment
behind, for the reasons in
[gitops-repo.md](gitops-repo.md#argo-cd-must-manage-itself-at-the-version-it-was-seeded-with).

Fixing it means removing what that older seed left, not re-running bootstrap,
which refuses on a handed-over cluster anyway. The `dex.config` it wrote is a key
no Argo CD Application owns, and `argocd-dex-server` is a Deployment from its
Helm release, so both are deleted directly, once, by hand:

```bash
kubectl patch configmap argocd-cm --namespace argocd \
  --type json -p '[{"op": "remove", "path": "/data/dex.config"}]'
kubectl delete deployment argocd-dex-server --namespace argocd
kubectl rollout restart deployment/argocd-server --namespace argocd
```

Restart `argocd-server` so it picks up the change immediately. A cluster seeded
by the current seed never reaches this state, because neither the key nor the
Deployment is created in the first place.

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
repository: `generated/clusters/main/` additionally carries Kargo, which the
spokes do not run. The seed is deliberately identical everywhere, so that
per-cluster variation lives where it can be reviewed as a diff and reconciled
continuously, rather than in an imperative script run once from somebody's
laptop.
