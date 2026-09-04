---
title: Propagate a Documentation Correction to Every Document That Makes the Claim
paths:
  - "**/*.md"
---

# Propagate a Documentation Correction to Every Document That Makes the Claim

When correcting a statement about how the system behaves, grep for that claim across
every document and fix each occurrence in the same change. A correction applied to one
file leaves its siblings asserting the opposite, and a reader who lands on the stale
copy first acts on the version that is wrong. Never report a document as "checked, says
nothing untrue" without diffing its claims against the sentences just written elsewhere.

## Incorrect

The runbook is corrected; README, which makes the same claim, is read and declared clean
because it does not contain the exact wording that was hunted for.

```markdown
<!-- docs/how-to-launch-cluster.md (edited) -->
Moving to a broker is not something to defer: an already-seeded cluster keeps the
bundled Dex and its `dex.config`. Decide before bootstrapping.

<!-- README.md (left alone: "asserts nothing untrue") -->
Argo CD authenticates through the Dex bundled in its own Helm chart. Moving to a
central Dex broker later is a change of values rather than a reshaping of the seed.
```

## Correct

Grep the claim, then correct every document that carries it.

```markdown
<!-- grep -rn "central Dex broker" --include="*.md" . -->

<!-- docs/how-to-launch-cluster.md (edited) -->
Moving to a broker is not something to defer: an already-seeded cluster keeps the
bundled Dex and its `dex.config`. Decide before bootstrapping.

<!-- README.md (edited in the same change) -->
Leave `OIDC_ISSUER_URL` empty and the bundled Dex is the issuer; set it and the seed
installs no Dex and writes no `dex.config`. The choice is made at bootstrap: nothing
later removes what the seed created.
```
