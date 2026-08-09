# Workflows and actions, step by step

Three workflows. Each is described step by step, with what it does, why it is written
that way, and how it fails. Where a step exists because something went wrong during
bring-up, that is stated — those are the ones worth keeping.

Swimlane of the whole flow: `docs/diagrams/provisioning-swimlane.drawio`.

---

## Trigger map

| Workflow | Trigger | Runs as | Gate it enforces |
|---|---|---|---|
| `01-intake.yml` | `issues: [opened, edited]` with label `provision-request` | GitHub App token | Schema validation. Invalid claim never becomes a PR. |
| `02-validate-pr.yml` | `pull_request` touching apps/catalog/templates | `GITHUB_TOKEN`, read-only | Generated code matches its manifest. |
| `03-provision.yml` | `push` to `main` touching apps | `TFE_TOKEN` | None — it acts only after both approvals. |

---

## 1. `01-intake.yml` — issue to pull request

### Job configuration

```yaml
jobs:
  intake:
    if: contains(github.event.issue.labels.*.name, 'provision-request')
    runs-on: ubuntu-latest
    defaults:
      run:
        shell: bash
```

Two non-obvious things.

**The label gate.** The issue form declares `labels: ["provision-request"]`. GitHub
does **not** auto-create a label referenced by an issue form. If it does not exist in
the repository, the issue is created without it, the `if` is false, and the workflow
never runs — no error, no annotation, nothing in the Actions tab. This cost a
debugging cycle during bring-up. Create the label as part of repository setup:

```bash
gh label create provision-request --color 1d76db \
  --description "Infrastructure provisioning request from a business unit"
```

**`defaults.run.shell: bash`.** This is the single most important line in the file.
GitHub's default shell on Linux is `bash -e {0}` — **no `pipefail`**. Several steps
below pipe into `tee` to capture a log for the failure comment. Without `pipefail` a
step reports `tee`'s exit status, which is always zero, so a claim that failed
validation was logged as `VALIDATION FAILED:` and then went on to raise a pull request
anyway. That is precisely the failure this workflow exists to prevent, and it looked
like a green run. `shell: bash` runs `bash --noprofile --norc -eo pipefail {0}`.

Note this is deliberately **not** applied to `03-provision.yml`, where a `grep` that
legitimately matches nothing exits 1 and would abort the job.

### Steps

**1. Checkout, Python 3.12, install dependencies.**
`pyyaml jsonschema jinja2 python-hcl2`. Pinning these is a hardening item — see
`04-build-checklist.md`.

**2. Extract the application id.**

```yaml
env:
  BODY: ${{ github.event.issue.body }}
run: |
  python3 - << 'PY' >> "$GITHUB_OUTPUT"
  import os, re
  body = os.environ["BODY"]
  m = re.search(r"###\s*Application id\s*\n+\s*(\S+)", body)
  print(f"id={m.group(1).strip() if m else ''}")
  PY
```

The issue body goes through an **environment variable**, never interpolated into the
script. `${{ github.event.issue.body }}` pasted inline is a script injection: anyone
who can open an issue controls that string, and a body containing a backtick or `$(...)`
executes on the runner. This is the highest-severity pattern in GitHub Actions and it
is easy to write by accident.

**3. Write the issue body to a file** — same reasoning, `printf '%s' "$BODY"`.

**4. Parse the issue into two lane manifests.**

```bash
python3 tools/parse_issue.py /tmp/issue.md "${{ steps.app.outputs.id }}" 2>&1 | tee /tmp/parse.log
```

Splits the two fenced YAML blocks into `infra/apps/<app>/manifest.yaml` and
`security/apps/<app>/access.yaml`. Rejects an issue whose two blocks disagree on
`appId` — a mismatch means the BU pasted one block from another request, and
generating from it would attach a grant to the wrong application.

**5. Validate against the published schemas.** `stackforge/cli.py validate`. Runs both
JSON Schema validation and cross-manifest validation. **This is the gate.** If it
fails, `pipefail` propagates the non-zero exit, remaining steps are skipped, and
control reaches step 8.

**6. Render both lanes.** `stackforge/cli.py render`. Writes four files per lane —
`components.tfcomponent.hcl`, `deployments.tfdeploy.hcl`, `.terraform-version`,
`.terraform.lock.hcl`.

**7. Raise the pull request.**

```yaml
- name: Mint a GitHub App token
  id: app-token
  uses: actions/create-github-app-token@v1
  with:
    app-id: ${{ vars.INTAKE_APP_ID }}
    private-key: ${{ secrets.INTAKE_APP_PRIVATE_KEY }}

- uses: peter-evans/create-pull-request@v6
  with:
    token: ${{ steps.app-token.outputs.token }}
```

The App author solves two separate problems, and both are fatal without it:

- **Downstream workflows.** A pull request created with the default `GITHUB_TOKEN`
  does not trigger further workflow runs. `02-validate-pr.yml` would never fire, and
  the drift guard would silently not exist.
- **Review integrity.** GitHub forbids approving your own pull request. If a human's
  PAT opened it, that human could not approve their own lane, so one person would have
  to sit in both Platform Operations and Security Assurance — and a single approval would satisfy both CODEOWNERS
  rules. The separation of duties would be theatre. A bot author leaves both humans
  free to approve independently.

**8. Report back to the issue.** `if: success()` posts the PR link.
`if: failure()` posts the captured validation log:

> The request could not be processed, so no pull request was raised.
> ```
> VALIDATION FAILED:
>   - components[0] (ack/v1): Additional properties are not allowed
>     ('worker_instance_type' was unexpected)
> ```
> Edit this issue to correct the claim and the check will run again.

Because the trigger includes `edited`, correcting the issue re-runs intake. The BU
never needs to know what a workflow is.

---

## 2. `02-validate-pr.yml` — the drift guard

```yaml
on:
  pull_request:
    paths: ['infra/apps/**', 'security/apps/**', 'catalog/**', 'templates/**']
permissions:
  contents: read
  pull-requests: write
```

Generated paths are included in the filter deliberately. If only manifests were
listed, a pull request touching **only** rendered HCL would match no path, no workflow
would run, and the hand-edit guard would be unreachable — the edit sails through
unchallenged. This is a real trap: the guard appears present and is not.

### Steps

**1. Determine which applications changed.**

```bash
APPS=$(git diff --name-only origin/${{ github.base_ref }}...HEAD \
       | grep -oE '(infra|security)/apps/[^/]+' | cut -d/ -f3 | sort -u | tr '\n' ' ')
```

Needs `fetch-depth: 0`; the default shallow clone cannot compute the merge base.

**2. Re-validate every changed claim.** A manifest can be edited directly in the PR,
bypassing intake. It is validated again here.

**3. Confirm generated files match their manifests.** The core of the workflow:

```bash
for app in ${{ steps.apps.outputs.list }}; do
  python3 stackforge/cli.py render --app "$app" >/dev/null
done
if ! git diff --quiet -- '*/stacks/*'; then
  echo "::error::Generated stack files do not match their manifests."
  git --no-pager diff -- '*/stacks/*'
  exit 1
fi
```

Re-render from the manifest and diff against what is committed. Any difference fails
the PR. This catches hand-editing generated HCL, and equally a template change that
was not re-rendered.

It works only because rendering is deterministic. If output varied — a timestamp, a
dict iteration order — this check would fail randomly and be switched off within a
week. **Determinism is what makes the guard enforceable.**

Verified working: PR #6 hand-edits a region in a generated file and fails with the
drift message.

**4. Summarise the ownership split** into `$GITHUB_STEP_SUMMARY`, so a reviewer sees
which lane they own without reading CODEOWNERS.

---

## 3. `03-provision.yml` — merge to Terraform Cloud

```yaml
on:
  push:
    branches: [main]
    paths: ['infra/apps/**', 'security/apps/**']
environment: nonprod
permissions:
  contents: read
```

`environment: nonprod` is where a deployment-level approval or an environment secret
would attach. The environment must exist or the job fails to start.

### Steps

**1. Determine which applications were merged.**

```bash
BASE=$(git rev-parse HEAD~1 2>/dev/null || git hash-object -t tree /dev/null)
APPS=$(git diff --name-only "$BASE" HEAD | grep -oE '(infra|security)/apps/[^/]+' ...)
```

The fallback exists because on the very first push there is no `HEAD~1`, `git diff`
aborts with `fatal: ambiguous argument 'HEAD~1'`, and the step reports "none" while
exiting zero. Falling back to the empty tree treats everything in the commit as
changed. Needs `fetch-depth: 2`, and assumes squash merges — the repository is
configured squash-only for exactly this reason.

**2. Ensure the Terraform Cloud stacks exist.** `platform/ensure_stacks.py`, which is
idempotent: it creates on first run and PATCHes afterwards, so a re-merge is safe.

Three API facts, each found the hard way against the live API:

- **There is no `GET /projects/{id}/stacks`.** It 404s. The only list route is
  `GET /organizations/{org}/stacks`, and its project filter is not dependable, so the
  script matches on both name and project id client-side.
- **Create is `POST /stacks`**, org-level, with the project passed as a *relationship* —
  not nested under `/projects/{id}/stacks`.
- **The subdirectory is a top-level `working-directory` attribute**, with no leading
  slash. Passing it as `vcs-repo.directory` is accepted, returns 200, and is silently
  dropped — leaving the stack pointed at the repository root where there is no HCL.
  A leading slash returns a 422.

**3. Record what happens next** in the step summary. The workflow never approves or
applies anything; it only ensures the stacks exist and point at the right directory.

---

## 4. What Terraform Cloud does after the merge

1. **Fetch configuration.** TFC pulls the stack's working directory and *bundles the
   source*, resolving module references. Failures here are configuration errors, not
   plan errors, and are reported as stack diagnostics.
2. **Plan each deployment.** One plan per `deployment` block.
3. **Wait for a human.** The plan step goes to `pending-operator`. No `orchestrate`
   auto-approve rule is emitted, deliberately — every deployment stops between plan
   and apply.
4. **Apply publishes outputs**, which unblocks the downstream stack.

### The four Stacks rules that cost the most time

| Rule | Symptom when broken |
|---|---|
| Component files are `*.tfcomponent.hcl` | `*.tfstack.hcl` is the beta name; components are not found |
| Local module sources must be canonical | `./../../modules/x` is rejected during bundling even though it resolves on disk. Must be `../../modules/x` |
| `publish_output` cannot read `component.*` | `There is no referenceable symbol named "component"` |
| `.terraform-version` and `.terraform.lock.hcl` must be committed in each stack directory | A Stack never runs its own init |

### The output chain

This is the part most likely to be written wrong, because the wrong version looks
correct. A published value is **deployment-scoped**, so it takes two hops:

```hcl
# components.tfcomponent.hcl — a stack-level output reading the component
output "cluster_rrsa_issuer" {
  description = "RRSA OIDC issuer URL"
  type        = string
  value       = component.policy_cluster.rrsa_oidc_issuer_url
}
```

```hcl
# deployments.tfdeploy.hcl — forward that named output, per deployment
publish_output "dev_cluster_rrsa_issuer" {
  value = deployment.dev.cluster_rrsa_issuer
}
```

```hcl
# the consuming stack
upstream_input "infra" {
  type   = "stack"
  source = "app.terraform.io/<org>/<project>/policy-app-infra"
}

deployment "dev" {
  inputs = {
    cluster_rrsa_issuer = upstream_input.infra.dev_cluster_rrsa_issuer
  }
}
```

Published names are environment-qualified because a published output belongs to one
deployment. Two deployments publishing a bare `bucket_arns` would collide.

The `source` needs the **project segment** — `app.terraform.io/<org>/<project>/<stack>`.
Omitting it produces HCL that parses and then fails to resolve.

### Both stacks must live in one project

`publish_output` and `upstream_input` only resolve between stacks **in the same
project**. The original design put the two lanes in two projects; that renders valid
HCL which silently fails to resolve in TFC.

`stackforge/cli.py` now refuses to render a split:

```python
if cfg["projects"]["infra"] != cfg["projects"]["security"]:
    sys.exit("[stack-forge] the infra and security projects must be the same: "
             "upstream_input cannot cross a Terraform Cloud project boundary")
```

The cost is real and worth stating plainly: the TFC project is no longer an RBAC
boundary between Platform Operations and Security Assurance. Separation is carried by CODEOWNERS routing and by
the two disjoint RAM roles instead.

### "Missing upstream outputs" is correct behaviour

```
This Stack cannot be deployed because it depends on outputs from upstream Stacks
that haven't been published yet. The following upstream Stacks need a successful
deployment: policy-app-infra (referenced as infra).
```

This is the dependency working, not a fault. A published output only exists after a
**successful apply** — a plan does not produce one. So the security stack cannot plan
until Platform Operations has applied the infra stack.

There is no configuration flag that unblocks it. `upstream_input` has no default or
optional mode; the only unblock is an infra apply. Options:

- **Leave it.** For a demo this is the strongest frame available: Security Assurance physically
  cannot start until Platform Operations finishes, enforced by the platform.
- **Apply a cheap slice.** Narrow the manifest to OSS only. A bucket costs
  approximately nothing, `apply` publishes `bucket_arns`, and the security stack then
  plans and applies RAM objects, which are free. This demonstrates the full chain
  end-to-end for negligible cost. It does create real resources.
- **Apply the full manifest.** Publishes everything, but stands up an ACK cluster,
  which is neither free nor instant.

---

## 5. Failure modes, and what each looks like

| Failure | Where it surfaces | What you see |
|---|---|---|
| Field not in the claim schema | intake | `Additional properties are not allowed ('worker_instance_type' was unexpected)` |
| Unpublished schema version | intake | `unknown claimSchema 'ack/v9' — not published in the catalog` |
| Grant to an undeclared resource | intake | `grants access to 'finance-archive', which is not declared in manifest.yaml` |
| Two YAML blocks disagree on appId | intake | `appId must match` |
| Hand-edited generated file | PR | `Generated stack files do not match their manifests` |
| Missing `provision-request` label | nowhere | Nothing happens at all. Check the label exists. |
| Size not in the sizing map | render | `size 'huge' not in sizing map for ack` |
| Non-canonical module source | TFC bundling | `relative path must be written in canonical form` |
| Upstream not yet applied | TFC | `depends on outputs from upstream Stacks that haven't been published yet` |
| RAM role missing | TFC plan | `EntityNotExist.Role` |
| Trust policy action wrong | TFC plan | `AuthenticationFail.NoPermission`, `PolicyType: AssumeRolePolicy` |

---

## 6. The local test suite

`bash tests/run_tests.sh` — 13 checks, no cloud credentials needed. It is what a
pre-commit hook and the module release pipeline should both run.

Two of these were written after finding that the original versions passed vacuously:

- **Test 11** asserts local module sources are canonical *and* resolvable, and fails if
  its own pattern matches nothing — otherwise a renamed field turns the check into a
  no-op that still reports PASS.
- **Test 13** adds a size to the sizing map and asserts it becomes claimable and
  documented with no other edit, proving the enum is derived rather than copied.

Both were verified to fail when the corresponding template or file is broken. A test
that has never been seen to fail is not yet a test.
