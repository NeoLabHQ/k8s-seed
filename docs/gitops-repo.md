# What this repository expects of the gitops repository

k8s-seed seeds a cluster and then gets out of the way. Everything the cluster
actually needs arrives afterwards, from a separate gitops repository that Argo CD
reconciles continuously.

This document is the contract between the two. It is prose on purpose: no
copy-pasteable manifests, because a second copy of the gitops repository's
content would start rotting the day the real one diverges from it.

## The split rule

k8s-seed contains only what cannot be reconciled by Argo CD, because it must
exist before Argo CD does: the argo-cd Helm release, the credential Argo CD reads
the gitops repository with, and the root Application that points it there.

Everything else belongs in the gitops repository. The test is simple — if it can
be reconciled, it should be, because the bootstrap path is imperative, human-run,
uses admin credentials, is not drift-detected, and cannot be reviewed as a diff
against live state. Anything that needs upgrading without someone running a CLI
from a laptop against production belongs on the other side of the line.

## Required layout

The root Application resolves `generated/clusters/<TARGET_CLUSTER_NAME>/`, on the
branch given by `GITOPS_TARGET_REVISION`.

Use cluster-scoped paths from day one, even while there is only one cluster.
A flat layout works right up until the second cluster appears, and then forces a
path migration on a live, self-managing Argo CD — which is exactly the operation
you least want to perform.

The path must render to a set of Argo CD `Application` or `ApplicationSet`
resources. The root Application does not pin a source type, so Argo CD
auto-detects: a directory of plain YAML manifests, a kustomization, or a Helm
chart all work. Pick one and stay with it.

**If you pick plain YAML, keep `generated/clusters/<name>/` flat.** Argo CD reads
only the top level of a directory source unless `spec.source.directory.recurse`
is set, and the root Application cannot set it: any `spec.source.directory` block
makes the source type explicit and switches the auto-detection above off, which
would rule out the kustomization and Helm layouts. Files in a subdirectory would
be silently ignored rather than reported as an error. If you want structure, get
it from a kustomization or a chart, which recurse through their own references.

What is under `generated/clusters/<name>/` is a list of pointers, not the
workloads themselves, and it is written by the gitops repository's own generator
rather than hand-authored. Shared component definitions live elsewhere in the
repository and are referenced per cluster, so that a cluster's manifest reads as
a list of what that cluster runs.

## What a cluster needs to be usable

Immediately after bootstrap the cluster has Argo CD and nothing else. It has no
ingress, no certificates, no DNS, and Argo CD is reachable only by port-forward.
Closing that gap is the gitops repository's first job.

At minimum, every cluster needs:

- **cert-manager**, with the ClusterIssuers for your ACME setup. These used to
  live in this repository under `certificate/`; they follow cert-manager.
- **ingress-nginx**, or whichever ingress controller you standardise on.
- **external-dns**, so `ARGO_HOST` and everything after it resolve without
  manual DNS records.
- **Argo CD itself** — see the next section, it is the subtle one.
- **Argo Rollouts**, for progressive delivery.

The main cluster additionally runs **Kargo**, for promotion between environments.
Spokes do not.

None of these ship here. Argo Rollouts and Kargo in particular are deliberately
absent from k8s-seed: installing them at seed time would mean upgrading them by
re-running a bootstrap CLI against a production cluster.

## Argo CD must manage itself, at the version it was seeded with

The Application that manages Argo CD is the one that completes the handoff, and
it is the one with a sharp edge.

At the moment it first syncs, it adopts resources that the Helm release created
during bootstrap. Adoption is clean only if the Application installs the **same
chart version with the same values** as the seed. If they differ, the Helm
release and Argo CD each believe they own those resources and each will revert
the other's changes.

So, when writing it:

- Pin the same chart version this repository pins. It is a literal version in
  `helmfile.yaml`, never a range, precisely so it can be matched.
- Start from the values in `bootstrap/argocd-values.yaml.gotmpl` and keep them
  equivalent. The parameters that vary — the cluster label, the hostname, the
  OIDC client — are visible there.
- Name it `argocd`, in the `argocd` namespace. `just bootstrap` looks for an
  Application by that name to decide whether the cluster has already been handed
  over, and refuses to re-seed if it finds one.

After the handoff, Argo CD is upgraded by changing the version in the gitops
repository. Never by re-running bootstrap.

This is also where the Argo CD configuration that the seed leaves deliberately
bare belongs — most importantly RBAC. The seed grants SSO users nothing at all;
mapping a GitHub org or team to a role is part of the self-management
Application.

## Ordering

Argo CD syncs the children of the root Application in parallel unless told
otherwise, and several of them cannot tolerate that.

Use sync waves to express the dependencies:

- CRDs before anything that creates custom resources against them.
- cert-manager before its ClusterIssuers, and before any Ingress annotated to
  request a certificate from it.
- The ingress controller before workloads that expect their Ingress to resolve.

Without waves the first sync produces a burst of failures that eventually
resolve themselves through retries. It converges, but it converges noisily, and
it makes a genuinely broken sync hard to spot.

## What does not belong there

**Business applications.** They live in the apps repository. The gitops
repository is cluster infrastructure — the things a cluster needs in order to run
applications, not the applications. This repository used to carry
`identity-manager` and `channel-binder` Applications under `applications/`; they
belong with the apps.

**Imperatively created application secrets.** The old `Makefile` created a dozen
secrets from `.env` with `kubectl create secret`. Those follow the business
applications, and ideally into a real secret manager reached through External
Secrets or a similar operator, rather than being recreated by hand.

**Anything that must exist before Argo CD.** That is this repository, and it is
three files. Keep it that way.
