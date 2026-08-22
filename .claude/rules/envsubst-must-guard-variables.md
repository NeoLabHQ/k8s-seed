---
title: Guard Variables Before envsubst Into apply
---

# Guard Variables Before envsubst Into apply

`envsubst` substitutes an unset variable with an empty string and exits 0. Piping it
straight into `kubectl apply` therefore ships a structurally valid manifest with a
blank credential, URL, or path to a live cluster. Guard every variable in the recipe
that consumes it, not only in its caller — private recipes get invoked directly.

## Incorrect

The recipe trusts its caller to have checked. Run on its own with the variables
unset, it applies a repository Secret whose url, app id, installation id and private
key are all `""` — a GitHub App credential that authenticates as nobody.

```just
_apply-repo-secret:
    @envsubst '$GITOPS_REPO_URL $GITOPS_REPO_GITHUB_APP_ID $GITOPS_REPO_GITHUB_APP_INSTALLATION_ID $GITOPS_REPO_GITHUB_APP_PRIVATE_KEY_B64' \
        < bootstrap/repo-secret.yaml | kubectl apply -f -
```

## Correct

`${VAR:?message}` fails on unset *and* empty, before anything reaches the cluster,
and names the variable the operator has to set.

```just
_apply-repo-secret:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${GITOPS_REPO_URL:?set GITOPS_REPO_URL in .env}"
    : "${GITOPS_REPO_GITHUB_APP_ID:?set GITOPS_REPO_GITHUB_APP_ID in .env}"
    : "${GITOPS_REPO_GITHUB_APP_INSTALLATION_ID:?set GITOPS_REPO_GITHUB_APP_INSTALLATION_ID in .env}"
    : "${GITOPS_REPO_GITHUB_APP_PRIVATE_KEY_PATH:?set GITOPS_REPO_GITHUB_APP_PRIVATE_KEY_PATH in .env}"

    # (the real recipe also rejects a non-numeric id and a key file that is
    # missing, not a PEM, or passphrase-protected — see the justfile)

    key_path="$GITOPS_REPO_GITHUB_APP_PRIVATE_KEY_PATH"
    GITOPS_REPO_GITHUB_APP_PRIVATE_KEY_B64=$(base64 < "$key_path" | tr -d '\n')
    export GITOPS_REPO_GITHUB_APP_PRIVATE_KEY_B64
    : "${GITOPS_REPO_GITHUB_APP_PRIVATE_KEY_B64:?empty encoding of '$key_path' — is the file empty?}"

    envsubst '$GITOPS_REPO_URL $GITOPS_REPO_GITHUB_APP_ID $GITOPS_REPO_GITHUB_APP_INSTALLATION_ID $GITOPS_REPO_GITHUB_APP_PRIVATE_KEY_B64' \
        < bootstrap/repo-secret.yaml | kubectl apply -f -
```

A variable the recipe derives rather than reads is still a variable `envsubst`
expands, so it is guarded like the rest: the base64 above is checked after it is
computed, not assumed non-empty because the path it came from was set.
