# Seed parameters come from .env — see .env.example.
set dotenv-load := true

# Show all commands
help:
    @just --list

# ---------------------------------------------------------------------------------------------------------------------
# BOOTSTRAP
# ---------------------------------------------------------------------------------------------------------------------

[doc("""
  Seed this cluster and hand it over to the gitops repository.

  Runs once per cluster. After the handoff Argo CD manages itself from
  clusters/$TARGET_CLUSTER_NAME/ in the gitops repository, and re-running this would
  fight it — so it refuses if the handoff has already happened.

  Steps:
    1. namespace + argo-cd release, then the gitops repository credential
    2. wait for argocd-server
    3. apply the root Application
    4. Argo CD takes over from clusters/$TARGET_CLUSTER_NAME/

  Usage:
    just bootstrap
""")]
bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail

    # Consumed by envsubst rather than helm. GITOPS_REPO_URL is also declared
    # requiredEnv in helmfile.yaml, so a render catches it too; the GitHub App
    # credential is only ever seen here. `_apply-repo-secret` guards these again
    # for its own sake; repeated here to fail before the cluster is touched at
    # all, rather than after `helmfile apply` has already created things.
    : "${GITOPS_REPO_URL:?set GITOPS_REPO_URL in .env}"
    : "${GITOPS_REPO_GITHUB_APP_ID:?set GITOPS_REPO_GITHUB_APP_ID in .env}"
    : "${GITOPS_REPO_GITHUB_APP_INSTALLATION_ID:?set GITOPS_REPO_GITHUB_APP_INSTALLATION_ID in .env}"
    : "${GITOPS_REPO_GITHUB_APP_PRIVATE_KEY_PATH:?set GITOPS_REPO_GITHUB_APP_PRIVATE_KEY_PATH in .env}"
    # Same reasoning one step further: the key is a file, and a path that is set
    # but wrong fails just as late as one that is empty. Cheap to read now,
    # expensive to discover after the release is installed.
    [ -r "$GITOPS_REPO_GITHUB_APP_PRIVATE_KEY_PATH" ] || {
        echo "Refusing: cannot read the GitHub App private key at '$GITOPS_REPO_GITHUB_APP_PRIVATE_KEY_PATH'." >&2
        echo "GITOPS_REPO_GITHUB_APP_PRIVATE_KEY_PATH must be an absolute path to the .pem file." >&2
        exit 1
    }

    # Captured, not inlined into the echo: a command substitution that fails
    # inside `echo` still leaves `echo` succeeding, so `set -e` would not fire
    # and bootstrap would announce an empty context and carry on into the wrong
    # cluster hazard the runbook warns about. Testing the value rather than the
    # exit status treats an empty context like an empty variable, as the `:?`
    # guards above do. kubectl still prints its own reason to stderr.
    context=$(kubectl config current-context || true)
    if [ -z "$context" ]; then
        echo "Refusing: no current kubectl context, so there is no cluster to seed." >&2
        echo "List them with 'just contexts', then 'kubectl config use-context <name>'." >&2
        exit 1
    fi
    echo "Bootstrapping kubectl context: $context"

    if kubectl get application argocd --namespace argocd >/dev/null 2>&1; then
        echo "Refusing: this cluster already has a self-managed 'argocd' Application." >&2
        echo "Bootstrap is a one-time seed. To change Argo CD here, edit its version or" >&2
        echo "values in the gitops repository under clusters/\$TARGET_CLUSTER_NAME/ instead." >&2
        exit 1
    fi

    # Nothing below is rolled back on failure, so the operator has to be told
    # where the sequence stopped. Set after the guards above, which already
    # explain themselves.
    trap 'echo >&2; echo "FAILED at step $step. Nothing was rolled back; fix the cause and re-run." >&2' ERR

    step="1/4 argo-cd release and gitops repository credential"
    echo "==> $step"
    # helmfile renders first, so a missing required parameter fails before
    # anything is created.
    helmfile apply
    # ...then the credential. Kept outside the Helm release on purpose —
    # see bootstrap/repo-secret.yaml.
    just _apply-repo-secret

    step="2/4 waiting for argocd-server"
    echo "==> $step"
    # The root Application is served by argocd-server, so wait for it.
    kubectl rollout status deployment/argocd-server --namespace argocd --timeout=5m

    step="3/4 applying the root Application"
    echo "==> $step"
    just _apply-root-app

    step="4/4 handoff"
    echo
    echo "==> $step: Argo CD now reconciles clusters/$TARGET_CLUSTER_NAME/."
    echo "Check it with 'just verify', open the UI with 'just argo-ui'."

[doc("Apply the gitops repository credential Secret — the GitHub App — with .env expanded into it.")]
_apply-repo-secret:
    #!/usr/bin/env bash
    set -euo pipefail
    # Self-guarding, not caller-dependent. envsubst substitutes an unset or empty
    # variable with the empty string, which yields a structurally valid Secret
    # holding a credential that authenticates against nothing — the same silent
    # emptiness the requiredEnv declarations in helmfile.yaml exist to prevent.
    : "${GITOPS_REPO_URL:?set GITOPS_REPO_URL in .env}"
    : "${GITOPS_REPO_GITHUB_APP_ID:?set GITOPS_REPO_GITHUB_APP_ID in .env}"
    : "${GITOPS_REPO_GITHUB_APP_INSTALLATION_ID:?set GITOPS_REPO_GITHUB_APP_INSTALLATION_ID in .env}"
    : "${GITOPS_REPO_GITHUB_APP_PRIVATE_KEY_PATH:?set GITOPS_REPO_GITHUB_APP_PRIVATE_KEY_PATH in .env}"

    # `:?` catches unset and empty, not wrong, and every wrong value here
    # produces the same outcome: a Secret the API server accepts and Argo CD
    # cannot clone with. The checks below name the ones worth catching early.
    #
    # Both ids are numeric — the Argo CD Secret example is `githubAppID: 1`
    # and `githubAppInstallationID: 2` —
    # https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/
    # and GitHub shows the App ID beside a non-numeric Client ID that is easy to
    # copy instead.
    for var in GITOPS_REPO_GITHUB_APP_ID GITOPS_REPO_GITHUB_APP_INSTALLATION_ID; do
        case "${!var}" in
            *[!0-9]*)
                echo "$var must be the numeric id, not '${!var}'." >&2
                echo "The App ID is not the Client ID; see .env.example." >&2
                exit 1 ;;
        esac
    done

    key_path="$GITOPS_REPO_GITHUB_APP_PRIVATE_KEY_PATH"
    [ -r "$key_path" ] || {
        echo "Cannot read the GitHub App private key at '$key_path'." >&2
        exit 1
    }
    # A public key, a downloaded HTML page or a truncated copy all read fine and
    # all fail at clone time with an error about the credential rather than
    # about the file.
    grep -q -- '-----BEGIN .*PRIVATE KEY-----' "$key_path" || {
        echo "'$key_path' is not a PEM private key." >&2
        echo "It should be the .pem GitHub downloaded, starting -----BEGIN RSA PRIVATE KEY-----." >&2
        exit 1
    }
    # And a passphrase-protected key is a private key that still cannot be used:
    # nothing in argocd-repo-server can be prompted for a passphrase, so it too
    # fails at first clone. Both spellings — PKCS#8's own BEGIN line and PKCS#1's
    # Proc-Type header — mean the same thing here. GitHub never issues one, so
    # this is a key that was encrypted after the fact; decrypt it with
    # `openssl rsa -in <file> -out <file>` and point at the result.
    if grep -q -e '-----BEGIN ENCRYPTED PRIVATE KEY-----' -e 'Proc-Type: 4,ENCRYPTED' "$key_path"; then
        echo "'$key_path' is passphrase-protected, which Argo CD cannot use unattended." >&2
        echo "Decrypt it, or generate a fresh key on the GitHub App's settings page." >&2
        exit 1
    fi

    # Base64 on one line, because envsubst expands into YAML that it does not
    # parse: a multi-line PEM would land under `stringData:` with its
    # continuation lines at column zero. `base64 | tr -d` rather than `base64
    # -w0`, which is GNU-only and would fail on macOS. See bootstrap/repo-secret.yaml.
    GITOPS_REPO_GITHUB_APP_PRIVATE_KEY_B64=$(base64 < "$key_path" | tr -d '\n')
    export GITOPS_REPO_GITHUB_APP_PRIVATE_KEY_B64
    : "${GITOPS_REPO_GITHUB_APP_PRIVATE_KEY_B64:?empty encoding of '$key_path' — is the file empty?}"

    envsubst '$GITOPS_REPO_URL $GITOPS_REPO_GITHUB_APP_ID $GITOPS_REPO_GITHUB_APP_INSTALLATION_ID $GITOPS_REPO_GITHUB_APP_PRIVATE_KEY_B64' \
        < bootstrap/repo-secret.yaml | kubectl apply -f -

[doc("Apply the root Application with .env expanded into it.")]
_apply-root-app:
    #!/usr/bin/env bash
    set -euo pipefail
    # Self-guarding for the same reason as `_apply-repo-secret`: a private
    # recipe can be invoked directly, so it cannot rely on its caller's checks.
    # `main` is a genuinely safe default; the other two have none. An empty
    # TARGET_CLUSTER_NAME resolves to the path `clusters/` rather than failing, and an
    # empty repoURL yields a root Application the cluster accepts and then never
    # syncs — a handoff that looks like it worked.
    export GITOPS_TARGET_REVISION="${GITOPS_TARGET_REVISION:-main}"
    : "${GITOPS_REPO_URL:?set GITOPS_REPO_URL in .env}"
    : "${TARGET_CLUSTER_NAME:?set TARGET_CLUSTER_NAME in .env}"
    envsubst '$GITOPS_REPO_URL $GITOPS_TARGET_REVISION $TARGET_CLUSTER_NAME' \
        < bootstrap/root-app.yaml | kubectl apply -f -

[doc("Re-apply the argo-cd release only. Needs the helm-diff plugin. Safe before handoff; after it, change the gitops repository instead.")]
sync:
    helmfile apply

[doc("Show what `just sync` would change. Needs the helm-diff plugin, as `just sync` and `just bootstrap` do.")]
diff:
    helmfile diff

[doc("Assert Argo CD is healthy and the root Application is in an acceptable state. Fails if not.")]
verify:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "== Argo CD workloads =="
    kubectl get deployment,statefulset --namespace argocd
    kubectl wait --namespace argocd --for=condition=available --timeout=60s deployment --all

    echo
    echo "== Root Application =="
    kubectl get application root --namespace argocd \
        -o custom-columns='NAME:.metadata.name,PATH:.spec.source.path,SYNC:.status.sync.status,HEALTH:.status.health.status'

    # The application controller fills in status a moment after the Application
    # is created, so a verify run straight after bootstrap can read it empty.
    #
    # `|| true` for the same reason as the context capture in `bootstrap`: under
    # `set -e` a query that errors aborts on the assignment itself, before the
    # `case` written to diagnose it can run, leaving the operator with kubectl's
    # raw error and no verdict. Neutralised, a failed query and a genuinely
    # empty status both reach the "" branch that explains them. kubectl still
    # prints its own reason to stderr.
    for _ in $(seq 15); do
        sync=$(kubectl get application root --namespace argocd -o jsonpath='{.status.sync.status}' || true)
        [ -n "$sync" ] && break
        sleep 2
    done

    echo
    case "$sync" in
        Synced)
            echo "OK: root Application is synced." ;;
        # Expected until the gitops repository has a clusters/$TARGET_CLUSTER_NAME/ path.
        # 'When the root Application sits Unknown' in docs/how-to-launch-cluster.md
        # tells this apart from a credential failure.
        Unknown)
            echo "OK: root Application is Unknown — expected while clusters/\$TARGET_CLUSTER_NAME/ is empty." ;;
        "")
            echo "FAILED: Argo CD has not reported on the root Application." >&2
            exit 1 ;;
        *)
            echo "FAILED: root Application is '$sync'." >&2
            exit 1 ;;
    esac

# ---------------------------------------------------------------------------------------------------------------------
# ACCESS
# ---------------------------------------------------------------------------------------------------------------------

[doc("Print the initial admin password. Day-0 login, before SSO is usable.")]
argo-password:
    @kubectl get secret argocd-initial-admin-secret --namespace argocd \
        -o jsonpath='{.data.password}' | base64 -d && echo

[doc("Port-forward the Argo CD UI to http://localhost:8080. The only way in until gitops delivers ingress.")]
argo-ui:
    @echo "Argo CD UI: http://localhost:8080 — user 'admin', password from 'just argo-password'"
    kubectl port-forward --namespace argocd svc/argocd-server 8080:80

[doc("List kubectl contexts. Worth checking before bootstrapping.")]
contexts:
    kubectl config get-contexts

[doc("Show the kubectl context bootstrap would target.")]
current-context:
    kubectl config current-context

# ---------------------------------------------------------------------------------------------------------------------
# LOCAL TEST CLUSTER
# ---------------------------------------------------------------------------------------------------------------------

[doc("Create a local k3d cluster to try the seed against. Delete it with `k3d cluster delete <name>`.")]
create-local-cluster:
    #!/usr/bin/env bash
    set -euo pipefail
    name="${CLUSTER_NAME:-k8s-seed}"
    k3d cluster create "$name"
    k3d kubeconfig merge "$name" --kubeconfig-switch-context
    kubectl config use-context "k3d-$name"
    kubectl config current-context
    kubectl cluster-info
    kubectl get pods --all-namespaces

switch-to-local-cluster:
    #!/usr/bin/env bash
    set -euo pipefail
    name="${CLUSTER_NAME:-k3d-k8s-seed}"
    kubectl config use-context "$name"
    kubectl config current-context
    kubectl cluster-info
    kubectl get pods --all-namespaces

cluster-info:
    kubectl cluster-info
    kubectl get pods --all-namespaces

[doc("Delete a local k3d cluster")]
delete-local-cluster:
    #!/usr/bin/env bash
    set -euo pipefail
    name="${CLUSTER_NAME:-k8s-seed}"
    k3d cluster delete "$name"

# ---------------------------------------------------------------------------------------------------------------------
# DEVCONTAINER
# ---------------------------------------------------------------------------------------------------------------------

[doc("Get the running devcontainer ID (empty if not running)")]
_sandbox-id:
    @docker ps --filter "label=devcontainer.local_folder={{justfile_directory()}}" --format "{{{{.ID}}" | head -n1

[doc("""
  Start devcontainer and open an interactive shell.

  Description:
    Starts the development container using devcontainer CLI and attaches to an
    interactive zsh shell. First run may take time to build the image.

  Steps:
    1. Runs `devcontainer up` to start the container
    2. Extracts container ID, workspace folder, and user from output
    3. Attaches to the container with docker exec

  Usage:
    just sandbox
""")]
sandbox:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Starting devcontainer... First run can take long time to build the image"
    tmpfile=$(mktemp)
    devcontainer up --workspace-folder . 2>&1 | tee "$tmpfile"
    output=$(cat "$tmpfile")
    rm "$tmpfile"
    container_id=$(echo "$output" | grep -oP '"containerId"\s*:\s*"\K[^"]+')
    workspace=$(echo "$output" | grep -oP '"remoteWorkspaceFolder"\s*:\s*"\K[^"]+')
    user=$(echo "$output" | grep -oP '"remoteUser"\s*:\s*"\K[^"]+')
    if [ -z "$container_id" ]; then
        echo "Error: could not find devcontainer"
        exit 1
    fi
    echo "Attaching to container $container_id as ${user:-root} at $workspace..."
    docker exec -it -u "${user:-root}" -w "${workspace:-/}" "$container_id" zsh

[doc("""
  Attach to a running devcontainer.

  Description:
    Connects to an already running devcontainer shell. Requires that
    the devcontainer was started with `just sandbox` first.

  Steps:
    1. Gets the container ID using _sandbox-id
    2. Inspects container to find workspace and user
    3. Attaches with docker exec

  Usage:
    just attach-sandbox
""")]
attach-sandbox:
    #!/usr/bin/env bash
    set -euo pipefail
    container_id=$(just _sandbox-id)
    if [ -z "$container_id" ]; then
        echo "Error: no running devcontainer found. Run 'just sandbox' first."
        exit 1
    fi
    eval "$(docker inspect "$container_id" | python3 -c "
    import json,sys
    c = json.load(sys.stdin)[0]
    folder = c['Config']['Labels'].get('devcontainer.local_folder','')
    ws = next((m['Destination'] for m in c.get('Mounts',[]) if m['Source'] == folder), '/')
    meta = json.loads(c['Config']['Labels'].get('devcontainer.metadata','[]'))
    user = next((i['remoteUser'] for i in meta if 'remoteUser' in i), 'root')
    print(f'workspace={ws}')
    print(f'user={user}')
    ")"
    echo "Attaching to container $container_id as $user at $workspace..."
    docker exec -it -u "$user" -w "$workspace" "$container_id" zsh

[doc("""
  Stop and remove the devcontainer.

  Description:
    Gracefully stops and removes the running development container.
    Safe to run even if no container is running.

  Steps:
    1. Gets container ID (if any)
    2. Stops the container with docker stop
    3. Removes the container with docker rm

  Usage:
    just stop-sandbox
""")]
stop-sandbox:
    #!/usr/bin/env bash
    set -euo pipefail
    container_id=$(just _sandbox-id)
    if [ -z "$container_id" ]; then
        echo "No running devcontainer found."
        exit 0
    fi
    echo "Stopping container $container_id..."
    docker stop "$container_id" && docker rm "$container_id"
    echo "Done."

[doc("""
  Tear down the devcontainer completely.

  Description:
    `stop-sandbox` removes the container; this also removes the image behind it,
    so the next `just sandbox` starts from a freshly pulled one.

    The devcontainer is image-based (.devcontainer/devcontainer.json), not
    compose-based, so there is no compose project to bring down.

  Usage:
    just down-devcontainer
""")]
down-devcontainer:
    #!/usr/bin/env bash
    set -euo pipefail
    container_id=$(just _sandbox-id)
    if [ -z "$container_id" ]; then
        echo "No running devcontainer found; nothing to tear down."
        exit 0
    fi
    image=$(docker inspect --format '{{{{.Config.Image}}' "$container_id")
    just stop-sandbox
    echo "Removing image $image..."
    docker image rm -f "$image"
    echo "Done."
