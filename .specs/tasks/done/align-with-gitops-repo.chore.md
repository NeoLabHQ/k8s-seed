---
title: Align k8s-seed with gitops repo
---

## Initial User Prompt

align with gitops repo

### Context (supplied by the gitops repository)

The gitops repository was restructured **by provenance**: one tree an operator edits, one
tree a generator writes and nobody touches. The half the root Application syncs moved:

| Was | Is now | Who writes it |
| --- | --- | --- |
| `clusters/<cluster>/` | `generated/clusters/<cluster>/` | a generator in the gitops repo |
| `values/<name>/<cluster>.yaml` | `generated/values/<name>/<cluster>.yaml` | same |
| `cluster-definitions/*.yaml` | `definitions/*.yaml` | an operator |
| `components/<name>/component.yaml` | `definitions/components/<name>.yaml` | an operator, and Renovate |
| `values/<name>/_common.yaml` | `definitions/values/<name>.yaml` | an operator |

Only the first row is visible to `k8s-seed`. Everything else in the table is internal to
the gitops repository and must **not** be described here — `docs/gitops-repo.md` states
why: a second copy of the gitops repository's content starts rotting the day the real one
diverges from it.

Requirements as stated by the gitops repository:

1. The root Application must resolve `generated/clusters/<CLUSTER_NAME>/`. The rest of the
   contract is unchanged: the cluster name still selects the directory,
   `GITOPS_TARGET_REVISION` still selects the branch.
2. The path must not be hard-coded in two places. Whatever builds it today keeps being the
   single place it is built, with only the prefix changing.
3. The root Application must still not pin a source type — it must NOT gain a
   `spec.source.directory` block, not even `directory.recurse: true`.
4. Nothing else in the contract changes. The split rule and the "Argo CD must manage itself
   at the version it was seeded with" clause are untouched.

---

## Description

`k8s-seed` seeds a cluster, installs Argo CD, and applies one root `Application` that points
Argo CD at this cluster's path in the gitops repository. That path is an **external contract**
between the two repositories, and the gitops side has moved it: what the root Application
must resolve is now `generated/clusters/<TARGET_CLUSTER_NAME>/`, not `clusters/<TARGET_CLUSTER_NAME>/`.

`bootstrap/root-app.yaml` still renders the old path, so a cluster seeded by `k8s-seed` today
hands over to a directory that does not exist. **This failure is silent.** An Argo CD directory
source over a missing path does not go `Degraded` or `OutOfSync`; the Application simply manages
zero resources and reports `Unknown` — the exact status `just verify` is written to *accept*,
because `Unknown` is also the legitimate day-0 state on an empty gitops repository. The operator
gets a green bootstrap, a green `verify`, and a cluster with no ingress, no certificates, no DNS
and no self-managing Argo CD. Nothing tells them until they go looking.

The fix is one literal in one file. The work is making sure the rest of the repository — the
runbook, the contract document, the README, the `justfile` messages, `.env.example` — does not
keep telling operators the old path, because those texts are the only thing an operator has to
diagnose the silent state against.

**Who this is for:** the operator who bootstraps the first real (Civo) cluster, and every
operator after them. No cluster is currently broken by this — no Civo cluster has ever been
bootstrapped, and the gitops repository's `local` overlay is seeded by its own `just local-root`
recipe rather than by `k8s-seed` — so this task is a prerequisite for the first real bootstrap,
not an incident response.

**Key constraints:**

- The root Application must keep auto-detecting its source type. Adding any `spec.source.directory`
  block (even `recurse: true`) pins the type to `directory` and rules out the kustomization and
  Helm layouts `docs/gitops-repo.md` deliberately allows.
- The path stays built in exactly one place. It is assembled today as a literal prefix plus
  `${TARGET_CLUSTER_NAME}` in `bootstrap/root-app.yaml`; the prefix is the only edit.
- `k8s-seed` cannot be tested end-to-end here: verification without a cluster is a render check,
  and `helmfile`/`kubeconform` are not installed in this devcontainer.

**Scope**

- **Included:**
  - `bootstrap/root-app.yaml` — the rendered `spec.source.path` becomes `generated/clusters/${TARGET_CLUSTER_NAME}`.
  - Every prose, comment and operator-facing message in this repository that names the synced
    path: `README.md`, `justfile`, `.env.example`, `docs/gitops-repo.md`,
    `docs/how-to-launch-cluster.md`, and the comment block of `bootstrap/root-app.yaml`
    (25 occurrences of `clusters/` in total, listed under **Expected Changes**).
  - The runbook's "app path does not exist" troubleshooting text, which quotes the path Argo CD
    reports back verbatim.
  - Correct `docs/how-to-launch-cluster.md` to align with the new path.
  - Making clear, wherever this repository tells an operator that the path will exist, that the
    generated tree is produced by the gitops repository's own generator — without naming or
    describing that generator.
- **Excluded:**
  - Any change to the split rule, to the "Argo CD must manage itself at the version it was seeded
    with" clause, or to any other part of `docs/gitops-repo.md` beyond the path.
  - Describing `definitions/`, `generated/values/`, the generator script, or Renovate wiring in
    this repository. Requirement 4 mentions correcting a citation of
    `components/argocd/component.yaml` "wherever `k8s-seed` cites it" — **verified: this
    repository cites it nowhere** (`grep -rn 'component.yaml'` returns nothing outside `.specs/`),
    so there is nothing to correct. Do not add such a citation.
  - Introducing a new environment variable (e.g. a configurable path prefix) or a second place the
    path is assembled — see **AD-1**.
  - Any new `just` recipe, CI workflow, or `helmfile` change — see **AD-4**.
  - The pre-existing `GITOPS_TARGET_REVISION` default mismatch (`justfile` defaults to `main`,
    `.env.example:20` says it "defaults to `master`"), the README "Critical" paragraph's typos,
    and `.specs/tasks/draft/refactor-app-of-apps-pattern.refactor.md` (a historical draft, left as
    the record of what was decided then). Leave all of these alone and raise them separately;
    fixing them here would smuggle unrelated behaviour into a contract change.

**User Scenarios**

1. **Primary flow** — An operator fills `.env`, runs `just bootstrap` against a fresh cluster, and
   the root Application is created with `spec.source.path: generated/clusters/<their cluster>`.
   Argo CD resolves it, finds the Application that manages Argo CD itself, and the handoff
   completes. `just verify` reports `Synced`, and its `PATH` column reads
   `generated/clusters/<their cluster>`.
2. **Alternative flow (day 0)** — The gitops repository has not generated this cluster's directory
   yet. The root Application sits `Unknown`, `just verify` passes and says so, and the message
   names `generated/clusters/$TARGET_CLUSTER_NAME/` — so the operator looks in the right place.
3. **Error handling** — The path genuinely does not exist. Argo CD's condition reads
   `generated/clusters/<name>: app path does not exist`, and the runbook's troubleshooting section
   quotes that exact string, keeping it distinguishable from a credential failure (which produces
   `authentication required` / `repository not found` and shows up in `argocd-repo-server` logs).
4. **Recovery** — A cluster was seeded against an older revision of this repository and its root
   Application points at the old path. Bootstrap must not be re-run; the runbook tells the operator
   to patch `spec.source.path` on the live Application instead.

---

## Acceptance Criteria

**Checklist:**

| ID | Question | Category | Importance |
|----|----------|----------|------------|
| CK-1 | Does `bootstrap/root-app.yaml` render `spec.source.path` as `generated/clusters/<TARGET_CLUSTER_NAME>` for a non-empty `TARGET_CLUSTER_NAME`? | hard_rule | essential |
| CK-2 | Is the path still assembled in exactly one place — a single literal prefix plus `${TARGET_CLUSTER_NAME}` in `bootstrap/root-app.yaml` — with no second location computing, echoing or defaulting it as a path? | hard_rule | essential |
| CK-3 | Is `spec.source.directory` still absent from the root Application (no `recurse`, no `jsonnet`, no `include`/`exclude`), so Argo CD keeps auto-detecting the source type? | hard_rule | essential |
| CK-4 | Does `grep -rn 'clusters/' README.md justfile .env.example docs bootstrap` return only matches preceded by `generated/`? | hard_rule | essential |
| CK-5 | Was no new environment variable introduced for the path, and does the `envsubst` substitution list in `_apply-root-app` still name exactly `$GITOPS_REPO_URL $GITOPS_TARGET_REVISION $TARGET_CLUSTER_NAME`? | hard_rule | essential |
| CK-6 | Do the operator-facing messages in the `justfile` (`bootstrap` step 4, the already-seeded refusal, the `verify` `Unknown` branch) name `generated/clusters/$TARGET_CLUSTER_NAME/`? | hard_rule | essential |
| CK-7 | Does `docs/gitops-repo.md` "Required layout" state that the root Application resolves `generated/clusters/<TARGET_CLUSTER_NAME>/`, with `GITOPS_TARGET_REVISION` still selecting the branch? | hard_rule | essential |
| CK-8 | Does the runbook's troubleshooting text quote the path Argo CD actually reports — `generated/clusters/<name>: app path does not exist`? | principle | essential |
| CK-9 | Does `just verify`'s documented `PATH` column value in `docs/how-to-launch-cluster.md` match what the recipe will now print? | principle | important |
| CK-10 | Does the repository state, where it tells an operator the path will appear, that the generated tree is written by the gitops repository's generator rather than hand-authored? | principle | important |
| CK-11 | Does `docs/how-to-launch-cluster.md` tell an operator whose cluster was seeded with the old path to patch the live root Application rather than re-run `bootstrap`? | principle | important |
| CK-12 | Is the repository free of any new description of gitops-repository internals — `definitions/`, `generated/values/`, the generator script's name, Renovate wiring? | hard_rule | essential |
| CK-13 | Are the split rule, the "Argo CD must manage itself at the version it was seeded with" section and every other non-path statement in `docs/gitops-repo.md` unchanged? | hard_rule | essential |
| CK-14 | Are the excluded pre-existing issues (`GITOPS_TARGET_REVISION` default mismatch, README "Critical" typos, the historical `refactor-app-of-apps-pattern` draft) left untouched? | principle | important |
| CK-15 | Do the `envsubst` guards in `_apply-root-app` still reject an unset or empty `TARGET_CLUSTER_NAME` and `GITOPS_REPO_URL` before anything is applied? | hard_rule | essential |
| CK-16 | Is the comment in `_apply-root-app` that explains *why* an empty `TARGET_CLUSTER_NAME` is dangerous still accurate about the path it would resolve to (now `generated/clusters/`)? | principle | important |
| CK-17 | Does the diff avoid touching `helmfile.yaml`, `bootstrap/argocd-values.yaml.gotmpl` and `bootstrap/repo-secret.yaml`, none of which carry the path? | principle | pitfall |
| CK-18 | Is the seed still three things — the argo-cd release, the repository credential Secret, the root Application — with no recipe, workflow or file added? | principle | important |

**Regular Checks:**

- [ ] Render passes: `TARGET_CLUSTER_NAME=demo GITOPS_REPO_URL=https://github.com/acme/gitops GITOPS_TARGET_REVISION=main envsubst '$GITOPS_REPO_URL $GITOPS_TARGET_REVISION $TARGET_CLUSTER_NAME' < bootstrap/root-app.yaml | yq '.spec.source.path'` prints `"generated/clusters/demo"`
- [ ] Source type stays unpinned: the same render piped to `yq '.spec.source | has("directory")'` prints `false`
- [ ] Guards still fire: `TARGET_CLUSTER_NAME= just _apply-root-app` exits non-zero with `TARGET_CLUSTER_NAME: set TARGET_CLUSTER_NAME in .env`, without reaching `kubectl`. **Do not use `env -u TARGET_CLUSTER_NAME`** — `set dotenv-load := true` refills the variable from `.env`, the guard never fires, and the recipe runs `kubectl apply` against whatever context is current. An empty *exported* value wins over dotenv and is the safe form; `just --dotenv-path /dev/null` with `GITOPS_REPO_URL` set in the environment is the equivalent alternative.
- [ ] No stale references: `grep -rn 'clusters/' README.md justfile .env.example docs bootstrap | grep -v 'generated/clusters/'` prints nothing
- [ ] `just --list` still parses the `justfile` after the edits
- [ ] Schema check, if `kubeconform` is available (it is not installed in this devcontainer — skip and say so rather than silently passing): the rendered manifest validates with `-strict` against the Argo CD `Application` CRD schema, per the command in `README.md`
- [ ] No code duplication: the path prefix appears in exactly one executable location; every other occurrence is prose about it
- [ ] Boy Scout Rule: only the path-related text is corrected; the explicitly excluded pre-existing issues are left for their own task
- [ ] Reuse honored: the existing `envsubst` + guard mechanism is reused as-is; no new substitution machinery

**Rubric:**

| Criterion | Weight |
|-----------|--------|
| Contract Correctness | 0.30 |
| Documentation Consistency | 0.25 |
| Single Source of the Path | 0.15 |
| Source-Type Neutrality | 0.15 |
| Project Guidelines Alignment | 0.10 |
| Scope Discipline | 0.05 |

**Rubric Score Definitions:**

Scale: 1-5 integers, anchor-relative — each criterion pins `score_2`/`score_4`, and 1/3/5 are placed relative to them.

### Contract Correctness

Whether the manifest this repository applies resolves the path the gitops repository actually
publishes, for the cluster named in `.env`.

Render `bootstrap/root-app.yaml` through `envsubst` with a representative `TARGET_CLUSTER_NAME`
and read `spec.source.path` out of the result. Judge the rendered value, not the file's source
text: a prefix that is correct in the file but lost to a mis-scoped `envsubst` list, or a value
that renders with a leading/trailing slash or a doubled segment, fails here just as an unchanged
literal does.

#### Anchors

**contrast**: the rendered `spec.source.path` is the gitops repository's real path, versus a path that resolves to nothing.

**score_2**:

```text
path: "clusters/demo"
```

**score_4**:

```text
path: "generated/clusters/demo"
```

### Documentation Consistency

Whether every text in this repository that names the synced path now names the new one — prose,
YAML comments, `[doc(...)]` blocks and the strings the recipes echo to the operator alike.

Enumerate the occurrences (`grep -rn 'clusters/' README.md justfile .env.example docs bootstrap`)
and check each one. Weight the operator-facing strings and the troubleshooting quotes highest:
those are what someone reads while staring at an `Unknown` Application, and a stale one sends them
to look in a directory that will never exist. A comment left stale counts, because the comments in
this repository carry the reasoning, not decoration.

#### Anchors

**contrast**: every path reference agrees with the manifest, versus the repository telling the operator one thing while applying another.

**score_2**:

```text
just verify → PATH: generated/clusters/demo
docs/how-to-launch-cluster.md → "`PATH` column reads `clusters/<your cluster name>`."
```

**score_4**:

```text
just verify → PATH: generated/clusters/demo
docs/how-to-launch-cluster.md → "`PATH` column reads `generated/clusters/<your cluster name>`."
```

### Single Source of the Path

Whether the path remains assembled in exactly one place, so the next move of this contract is
again a one-line edit.

Look for any location other than `bootstrap/root-app.yaml` that *computes* the path: a new
variable in `.env.example`, a prefix exported by a recipe, a default in `_apply-root-app`, a
second `envsubst` name. Prose that *describes* the path is not a second source; a shell variable
that constructs it is. A new environment variable is a specific failure here — it also lands
unguarded in `envsubst`, which `.claude/rules/envsubst-must-guard-variables.md` exists to prevent.

#### Anchors

**contrast**: one literal prefix in the manifest, versus the prefix reconstructed somewhere a future edit can miss.

**score_2**:

```text
# .env.example
GITOPS_CLUSTERS_PREFIX=generated/clusters
# root-app.yaml
path: "${GITOPS_CLUSTERS_PREFIX}/${TARGET_CLUSTER_NAME}"
```

**score_4**:

```text
# root-app.yaml — the only place the path is built
path: "generated/clusters/${TARGET_CLUSTER_NAME}"
```

### Source-Type Neutrality

Whether the root Application still lets Argo CD auto-detect the source type, which is what keeps
the kustomization and Helm layouts open to the gitops repository.

Inspect `spec.source` for a `directory` key in any form. Reason about intent too: a change made
"so subdirectories work" pins the type as `directory` and silently forecloses two of the three
layouts the contract allows — the opposite of what the deeper path implies. The flatness
requirement is satisfied on the gitops side, not by a `recurse` flag here.

#### Anchors

**contrast**: `spec.source` carries no `directory` key at all, versus any `directory` block, however minimal.

**score_2**:

```text
  source:
    path: "generated/clusters/${TARGET_CLUSTER_NAME}"
    directory:
      recurse: true
```

**score_4**:

```text
  source:
    repoURL: "${GITOPS_REPO_URL}"
    targetRevision: "${GITOPS_TARGET_REVISION}"
    path: "generated/clusters/${TARGET_CLUSTER_NAME}"
```

### Project Guidelines Alignment

Whether the change respects this repository's written rules: `.claude/rules/envsubst-must-guard-variables.md`,
`.claude/rules/verification-commands-must-assert.md`, `.claude/rules/set-e-command-substitution.md`,
and the documentation philosophy in `docs/gitops-repo.md` (prose, no copied gitops content).

Check that the guards in `_apply-root-app` still reject unset and empty values, that `verify` still
asserts rather than prints, and that no gitops-repository internals were copied in. Comments that
explain *why* must remain true after the edit — a comment justifying a guard by describing the old
path is now misinformation.

#### Anchors

**contrast**: the rules are still enforced and the comments explaining them are still true, versus a rule quietly weakened or a rationale left describing the old world.

**score_2**:

```text
# TARGET_CLUSTER_NAME resolves to the path `clusters/` rather than failing
export TARGET_CLUSTER_NAME="${TARGET_CLUSTER_NAME:-main}"
```

**score_4**:

```text
# an empty TARGET_CLUSTER_NAME resolves to the path `generated/clusters/` rather than failing
: "${TARGET_CLUSTER_NAME:?set TARGET_CLUSTER_NAME in .env}"
```

### Scope Discipline

Whether the diff is the contract change and its documentation, and nothing else.

Read the diff file by file. Unrelated fixes — however correct — belong to their own task; so do
new recipes, workflows and helmfile edits. Equally, a diff that stops at the manifest and leaves
the runbook stale is under-scoped, and under-scoping is the more damaging direction here, because
the docs are the operator's only defence against a silent failure.

#### Anchors

**contrast**: the diff covers the path everywhere and only the path, versus a diff that grows extra fixes or stops at the manifest.

**score_2**:

```text
 bootstrap/root-app.yaml    | 1 +-
 .env.example               | 2 +-   (GITOPS_TARGET_REVISION default "fixed" to main)
 helmfile.yaml              | 3 +-
```

**score_4**:

```text
 bootstrap/root-app.yaml         |  8 ++--
 .env.example                    |  2 +-
 README.md                       |  8 ++--
 docs/gitops-repo.md             |  6 +--
 docs/how-to-launch-cluster.md   | 18 ++++---
 justfile                        | 14 +++---
```

**Test Strategy:**

**Criticality:** MEDIUM-HIGH — infrastructure whose failure mode is silent (a bootstrapped-looking
cluster that manages nothing), on the path to a first production cluster. Mitigated by the change
being one literal in a static manifest with no runtime logic.

This repository has no test framework and no CI gate that renders manifests; `helmfile` and
`kubeconform` are not installed in this devcontainer. Verification is therefore render-level
assertions run from the shell, plus a full bootstrap against the local k3d cluster where an
operator has real gitops credentials. Every check below must **exit non-zero on failure**, per
`.claude/rules/verification-commands-must-assert.md` — piping to `grep -q` or comparing against an
expected string, not eyeballing output.

**Test Matrix:**

| Type | Size | Framework | Dependencies | Gate |
|------|------|-----------|--------------|------|
| smoke | small | shell (`envsubst` + `yq`) | none — both present in the devcontainer | Gate 1 (must pass before review) |
| contract | small | `kubeconform -strict` + Argo CD CRD schema | `kubeconform` (not installed — record as skipped, do not report as passed) | Gate 2 (best-effort) |
| smoke | small | shell (`grep`) | none | Gate 1 |
| e2e | large | `just bootstrap` on k3d + a real gitops repository | k3d cluster, GitHub App credentials, a gitops repo with `generated/clusters/<name>/` | Gate 3 (manual, before the first Civo bootstrap) |

**Test Cases to Cover**

#### CK-1: Does the root Application render the new path?
- [smoke] `TARGET_CLUSTER_NAME=demo GITOPS_REPO_URL=https://github.com/acme/gitops GITOPS_TARGET_REVISION=main envsubst '$GITOPS_REPO_URL $GITOPS_TARGET_REVISION $TARGET_CLUSTER_NAME' < bootstrap/root-app.yaml | yq -e '.spec.source.path == "generated/clusters/demo"'`
- [smoke] a cluster name containing a hyphen (`acme-prod`) renders `generated/clusters/acme-prod` — no quoting or splitting surprises
- [contract] the same render validates under `kubeconform -strict` against the `Application` CRD schema, per `README.md`

#### CK-3: Is the source type still unpinned?
- [smoke] the render piped to `yq -e '.spec.source | has("directory") | not'` exits 0
- [smoke] `grep -c 'directory:' bootstrap/root-app.yaml` is 0

#### CK-4, CK-6, CK-7, CK-8, CK-9: Are all path references updated?
- [smoke] `grep -rn 'clusters/' README.md justfile .env.example docs bootstrap | grep -v 'generated/clusters/'` produces no output (exit 1 from the outer `grep`)
- [smoke] `grep -q 'generated/clusters/<name>: app path does not exist' docs/how-to-launch-cluster.md`
- [smoke] `just --list` exits 0 — the `[doc(...)]` edits did not break `justfile` parsing

#### CK-5, CK-15, CK-16: Do the guards still hold?
- [smoke] `TARGET_CLUSTER_NAME= just _apply-root-app` exits non-zero with `TARGET_CLUSTER_NAME: set TARGET_CLUSTER_NAME in .env`, before any `kubectl` call
- [smoke] `GITOPS_REPO_URL=https://example.com/x just --dotenv-path /dev/null _apply-root-app` fails the same way — the guard, not the cluster, is what stops it
- [smoke] `GITOPS_REPO_URL= just _apply-root-app` exits non-zero naming `GITOPS_REPO_URL` — `:?` catches set-but-empty for both variables
- [smoke] `grep -n "envsubst '" justfile` shows the `_apply-root-app` list unchanged at `$GITOPS_REPO_URL $GITOPS_TARGET_REVISION $TARGET_CLUSTER_NAME`

#### CK-12, CK-13, CK-17, CK-18: Is the contract otherwise untouched?
- [smoke] `git diff --stat` lists only `bootstrap/root-app.yaml`, `.env.example`, `README.md`, `docs/gitops-repo.md`, `docs/how-to-launch-cluster.md`, `justfile`
- [smoke] `git diff docs/gitops-repo.md` touches only the three path lines (25, 38, 46) and no sentence of the split rule or the self-management section
- [smoke] `grep -rn 'definitions/\|generated/values/\|component.yaml' README.md justfile docs bootstrap .env.example` produces no output

#### CK-11: Is the recovery path documented?
- [e2e] on a k3d cluster bootstrapped against the *old* revision, the documented `kubectl patch` moves the root Application to the new path and Argo CD re-resolves it without re-running `bootstrap`

#### End-to-end handoff
- [e2e] `just bootstrap` against k3d with a gitops repository that has `generated/clusters/<name>/` populated: `just verify` exits 0, reports `Synced`, and its `PATH` column reads `generated/clusters/<name>`
- [e2e] the same against a gitops repository *without* that directory: `just verify` exits 0 reporting `Unknown`, and `kubectl get application root -o jsonpath='{range .status.conditions[*]}...'` names `generated/clusters/<name>: app path does not exist`

**Definition of Done:**

- [ ] Every `essential` checklist item answers YES
- [ ] All Regular Checks pass, with `kubeconform` explicitly reported as skipped rather than passed if it is still absent
- [ ] Every Gate 1 test case in **Test Cases to Cover** has been run and passed; Gate 3 (e2e) is documented as run-or-deferred, naming which
- [ ] A rendered `bootstrap/root-app.yaml` resolves `generated/clusters/<TARGET_CLUSTER_NAME>/` and carries no `spec.source.directory`
- [ ] An operator reading any single document in this repository — README, runbook, contract doc, `.env.example`, or a `just` message — is told the same path the manifest applies
- [ ] An operator facing an `Unknown` root Application can tell "the generated directory is not there yet" from "the credential is wrong" using only the runbook
- [ ] An operator whose cluster was seeded with the old path has a documented remedy that does not involve re-running `bootstrap`
- [ ] No gitops-repository internals (`definitions/`, `generated/values/`, generator name, Renovate wiring) were copied into this repository
- [ ] The excluded pre-existing issues are still present and unmodified, recorded as follow-ups rather than fixed here

---

## Solution Strategy

One literal changes; everything else is telling the truth about it.

`bootstrap/root-app.yaml` builds the path as a literal prefix concatenated with
`${TARGET_CLUSTER_NAME}`, expanded by the single `envsubst` call in `just _apply-root-app`. That is
already the single source required by requirement 2, and it is already guarded per
`.claude/rules/envsubst-must-guard-variables.md`. So the mechanism is right and only the constant
is wrong: `clusters/` becomes `generated/clusters/`. No new variable, no new recipe, no change to
the substitution list, no change to the guards.

The remaining 24 occurrences are documentation and operator-facing strings. They matter more than
usual here because the failure this task removes is *silent*: an Argo CD directory source over a
missing path reports `Unknown`, which is also the legitimate day-0 state, so the only thing that
tells an operator which of the two they are looking at is the prose. A stale path in the runbook's
troubleshooting section is not cosmetic — it is the difference between finding the problem and
concluding the seed is fine.

Two properties must survive the edit. First, `spec.source` must stay free of a `directory` block:
the deeper path invites a `recurse: true` that would pin the source type and foreclose the
kustomization and Helm layouts the contract allows. Second, the comments in `root-app.yaml` and
`_apply-root-app` that explain *why* — why the type is unpinned, why an empty cluster name is
dangerous — must be re-read after the edit, because each names the old path as part of its
reasoning.

## Expected Changes

| File | Lines | Change |
|------|-------|--------|
| `bootstrap/root-app.yaml` | 31 | **The behavioural change.** `path: "clusters/${TARGET_CLUSTER_NAME}"` → `path: "generated/clusters/${TARGET_CLUSTER_NAME}"` |
| `bootstrap/root-app.yaml` | 2, 8, 11 | Header comments: "reconciles `clusters/${TARGET_CLUSTER_NAME}/`", "may render `clusters/<name>/` as…", "CONTRACT: as a plain-YAML directory, `clusters/<name>/` must be flat" — all take the `generated/` prefix. The CONTRACT paragraph's reasoning (no `spec.source.directory`) stays verbatim; only the path in it moves. |
| `justfile` | 16, 23 | `[doc(...)]` for `bootstrap`: "manages itself from `clusters/$TARGET_CLUSTER_NAME/`" and step 4 "takes over from `clusters/$TARGET_CLUSTER_NAME/`" |
| `justfile` | 67 | Already-seeded refusal message: "edit its version or values in the gitops repository under `clusters/\$TARGET_CLUSTER_NAME/` instead" |
| `justfile` | 96 | Handoff echo: "Argo CD now reconciles `clusters/$TARGET_CLUSTER_NAME/`." |
| `justfile` | 173 | Comment in `_apply-root-app` explaining the guard: "An empty TARGET_CLUSTER_NAME resolves to the path `clusters/` rather than failing" → `generated/clusters/`. Keep the guard itself untouched. |
| `justfile` | 223, 227 | `verify`'s `Unknown` branch — the comment and the `echo`. This is the message an operator sees in the ambiguous state, so it must name the generated path. |
| `.env.example` | 9 | `TARGET_CLUSTER_NAME` comment: "Selects `clusters/<name>/` in the gitops repository" → `generated/clusters/<name>/`, noting the directory is written by the gitops repository's generator. |
| `README.md` | 27 | The irreducible-seed bullet: "the root `Application`, pointing at `clusters/<TARGET_CLUSTER_NAME>/`" |
| `README.md` | 36 | Layout block: `root-app.yaml  root Application -> clusters/<TARGET_CLUSTER_NAME>/` |
| `README.md` | 52 | Architecture: "`TARGET_CLUSTER_NAME`, which selects `clusters/<name>/`" |
| `README.md` | 62 | Bootstrap sequence step 4: "Argo CD syncs `clusters/<TARGET_CLUSTER_NAME>/`" |
| `docs/gitops-repo.md` | 25 | **The contract statement.** "The root Application resolves `clusters/<TARGET_CLUSTER_NAME>/`, on the branch given by `GITOPS_TARGET_REVISION`." → `generated/clusters/<TARGET_CLUSTER_NAME>/`. Branch clause unchanged. |
| `docs/gitops-repo.md` | 38 | "If you pick plain YAML, keep `clusters/<name>/` flat." — path only; the `spec.source.directory` reasoning that follows is unchanged and remains the justification for requirement 3. |
| `docs/gitops-repo.md` | 46 | "What is under `clusters/<name>/` is a list of pointers, not the workloads themselves." Optionally one clause noting this tree is generated on the gitops side — no more than that (**AD-3**). |
| `docs/how-to-launch-cluster.md` | 212 | `.env` walkthrough: "`TARGET_CLUSTER_NAME` … selects `clusters/<name>/`" |
| `docs/how-to-launch-cluster.md` | 246 | Bootstrap step 3: "an Argo CD `Application` pointing at `clusters/$TARGET_CLUSTER_NAME/`" |
| `docs/how-to-launch-cluster.md` | 259 | Verify section: "`PATH` column reads `clusters/<your cluster name>`" — must match what `verify` prints. |
| `docs/how-to-launch-cluster.md` | 304-305 | Troubleshooting: the quoted Argo CD message `clusters/<name>: app path does not exist`, and "resolves itself the moment you commit `clusters/<name>/`" — the second also needs rewording, since the generated tree is produced by the gitops repository's generator, not hand-committed. |
| `docs/how-to-launch-cluster.md` | 368 | Main-vs-spoke: "`clusters/main/` additionally carries Kargo" |
| `docs/how-to-launch-cluster.md` | new, ~5 lines | Recovery note near the troubleshooting section: a cluster seeded against an older revision points at the old path; do **not** re-run `bootstrap` (it refuses, and would fight the self-managing Argo CD) — patch the live Application instead: `kubectl patch application root -n argocd --type merge -p '{"spec":{"source":{"path":"generated/clusters/<name>"}}}'`. |

**Untouched:** `helmfile.yaml`, `bootstrap/argocd-values.yaml.gotmpl`, `bootstrap/repo-secret.yaml`,
`.github/workflows/`, `.claude/rules/`, `.specs/tasks/draft/refactor-app-of-apps-pattern.refactor.md`.

## Architecture Decisions

### AD-1: Keep the path a literal in the manifest; do not introduce a prefix variable

The obvious alternative is a `GITOPS_CLUSTERS_PREFIX` (or similar) in `.env.example`, substituted
alongside the cluster name. Rejected. It creates a second place the path is assembled, which is
what requirement 2 forbids; it adds an `envsubst` variable, which `.claude/rules/envsubst-must-guard-variables.md`
then requires be guarded in `_apply-root-app`, for a value that is not per-cluster; and it makes a
contract shared by two repositories configurable per operator, so a typo yields a valid manifest
pointing nowhere — the same silent failure this task exists to remove. The prefix is a contract
constant. Contract constants belong in the manifest, versioned with it.

### AD-2: The root Application keeps auto-detecting its source type

`spec.source.directory` is not added in any form. Setting it — even `recurse: true` — pins the type
as `directory` and rules out the kustomization and Helm layouts `docs/gitops-repo.md` allows. The
flatness requirement is met on the gitops side by what the generator emits, not by a flag here.
The existing CONTRACT comment in `root-app.yaml` already records this reasoning; it survives the
edit intact.

### AD-3: Do not describe the gitops repository's internal layout here

`definitions/`, `generated/values/`, the generator script and the Renovate wiring stay unmentioned.
`docs/gitops-repo.md` opens by saying why: it is prose on purpose, because a second copy of the
gitops repository's content starts rotting the day the real one diverges. The one thing worth
saying is that the synced tree is *generated* rather than hand-authored — which changes the
operator's action ("wait for / run the generator on that side", not "create the directory") — and
that is a clause, not a section. Requirement 4's `components/argocd/component.yaml` → 
`definitions/components/argocd.yaml` correction is a no-op here: this repository never cites that
path (verified by `grep`), and adding it now would violate this decision.

### AD-4: No new `just` recipe, workflow or CI gate

A `just check-root-app` that asserts the rendered path is tempting, and the render assertions in
**Test Cases to Cover** are exactly its body. It is still excluded: nothing in this repository runs
it (the only workflows are the `agent-*` ones), `README.md` already documents the equivalent
render-and-validate commands, and the seed is deliberately three files plus a `justfile`. Worth
proposing as its own task — with a CI workflow to run it — rather than smuggling in here.

## Workflow Steps

**Phase 1 — the contract change (blocking, ~1 edit)**

1. Edit `bootstrap/root-app.yaml:31` to `path: "generated/clusters/${TARGET_CLUSTER_NAME}"`.
2. Update the three header comments (lines 2, 8, 11), keeping the CONTRACT reasoning verbatim.
3. Assert immediately, before touching anything else:
   `TARGET_CLUSTER_NAME=demo GITOPS_REPO_URL=https://github.com/acme/gitops GITOPS_TARGET_REVISION=main envsubst '$GITOPS_REPO_URL $GITOPS_TARGET_REVISION $TARGET_CLUSTER_NAME' < bootstrap/root-app.yaml | yq -e '.spec.source.path == "generated/clusters/demo" and (.spec.source | has("directory") | not)'`

**Phase 2 — operator-facing strings (depends on Phase 1)**

4. `justfile` lines 16, 23, 67, 96, 173, 223, 227. Leave the guards and the `envsubst` list alone;
   re-read the comment at 173 so its reasoning matches the new path.
5. `.env.example:9`, adding the "written by the gitops repository's generator" clause.
6. Verify: `just --list` exits 0; `TARGET_CLUSTER_NAME= just _apply-root-app` still refuses, naming
   the variable, without reaching `kubectl`. Note `env -u TARGET_CLUSTER_NAME` does **not** test
   this — `set dotenv-load := true` refills it from `.env` and the recipe proceeds to `kubectl
   apply`; an empty exported value overrides dotenv, so that is the form to use.

**Phase 3 — documents (parallel with Phase 2; independent files)**

7. `docs/gitops-repo.md` lines 25, 38, 46 — path only, nothing else in the file.
8. `README.md` lines 27, 36, 52, 62.
9. `docs/how-to-launch-cluster.md` lines 212, 246, 259, 304-305, 368, then add the recovery note.

**Phase 4 — verification (depends on 1-3)**

10. `grep -rn 'clusters/' README.md justfile .env.example docs bootstrap | grep -v 'generated/clusters/'` → no output.
11. `grep -rn 'definitions/\|generated/values/\|component.yaml' README.md justfile docs bootstrap .env.example` → no output.
12. `git diff --stat` → exactly the six files in **Expected Changes**.
13. Run the Gate 1 smoke cases; run the Gate 2 `kubeconform` case if it is installed, and say
    plainly that it was skipped if it is not.
14. Record Gate 3 (e2e on k3d against a real gitops repository) as run or deferred. Deferring is
    acceptable — it needs GitHub App credentials and a populated gitops repository — but it must be
    stated, not omitted, and it must happen before the first Civo bootstrap.

## Risks

| Risk | Mitigation |
|------|------------|
| The edit lands but a stale doc sends the next operator to the old path while debugging a silent `Unknown`. | CK-4's `grep` gate; the runbook's troubleshooting quote (CK-8) is treated as behaviour, not prose. |
| Someone "fixes" flatness by adding `directory.recurse: true` alongside the deeper path. | AD-2, CK-3, and the Source-Type Neutrality rubric dimension with an explicit `score_2` showing exactly that mistake. |
| The path is parameterised for tidiness, creating a second source and an unguarded `envsubst` variable. | AD-1, CK-2, CK-5. |
| Scope creeps into the adjacent pre-existing defects (revision default, README typos). | Named and excluded explicitly in **Scope**; CK-14 checks they are still there. |
| A cluster seeded against an older revision is left pointing at the dead path, and `bootstrap` refuses to re-run. | The recovery note (CK-11): patch `spec.source.path` on the live Application. |
| The change cannot be verified end-to-end from this devcontainer (`helmfile`, `kubeconform` absent). | Render-level assertions are the Gate 1 requirement; Gate 3 is explicitly deferred-with-a-name rather than silently skipped. |
