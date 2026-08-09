# Permission caveats — GitHub Actions and Terraform Cloud in an enterprise org

Every place this design meets a permission boundary, what breaks, and what to ask for.
Ordered by how likely it is to stop you, not by severity.

The demo runs on a free GitHub org with OIDC to AliCloud. A corporate environment
differs on both counts, and the differences are not cosmetic.

---

## Part A — GitHub

### A1. Code-owner enforcement needs a paid plan on private repos

"Require review from Code Owners" on a **private** repository requires GitHub Team or
Enterprise. On a free org, CODEOWNERS still *requests* the right reviewers but cannot
*block* the merge.

This is the whole control. Without it the separation of duties is advisory. Confirm
before designing around it, because the failure is silent — the reviewers appear on
the PR exactly as expected and the merge button stays green.

### A2. Teams must exist and hold write access

CODEOWNERS entries that do not resolve are **silently ignored**. No warning, no
annotation. All four of these must exist and have at least write access to the repo:

```
/infra/       @org/platform-operations
/security/    @org/security-assurance
/catalog/     @org/service-governance
/templates/   @org/pipeline-engineering
```

```bash
gh api /orgs/<org>/teams --jq '.[].slug'
gh api /orgs/<org>/teams/<team>/repos --jq '.[] | "\(.name) \(.role_name)"'
```

A CODEOWNERS reference to a team with only read access matches nothing. The PR looks
correctly configured and enforces nothing.

### A3. The default `GITHUB_TOKEN` cannot drive this pipeline

Two independent blockers:

- Pull requests created with `GITHUB_TOKEN` **do not trigger further workflow runs**.
  `02-validate-pr.yml` would never fire.
- Many enterprise orgs set default workflow permissions to read-only and enable
  *"Prevent GitHub Actions from creating or approving pull requests"* at the org level.
  That switch overrides repository settings and cannot be worked around from inside a
  workflow.

You need a GitHub App or a PAT. **A GitHub App is the right answer** — see A4.

### A4. Use a GitHub App, and know what it needs

| Setting | Value |
|---|---|
| Repository permissions | Contents: read & write; Pull requests: read & write; Metadata: read |
| Webhook | Disabled |
| Installation | The repository, or the org |
| Secrets | `INTAKE_APP_PRIVATE_KEY` (secret), `INTAKE_APP_ID` (variable) |

Why an App rather than a PAT:

- **Review integrity.** GitHub forbids approving your own PR. A PAT-authored PR
  disqualifies its owner from approving their lane, which collapses two-team approval
  onto one person. A bot author leaves both humans free.
- **No human dependency.** A PAT dies with the employee who created it.
- **Auditability.** App actions are attributable to the App, not to a person who did
  not do them.
- **Scope.** App permissions are per-repository and narrow; a classic PAT with `repo`
  covers every repository the user can see.

**Caveat found the hard way:** an App installed on *selected repositories* is
**uninstalled** when its only selected repository is deleted. Recreating the repository
does not restore it — `GET /app/installations` returns `[]`. Install org-wide, or
re-install after any repository recreation.

**Caveat:** adding a repository to an existing installation requires a *user-to-server*
token. A classic PAT gets 404 on `PUT /user/installations/{id}/repositories/{repo_id}`.
In practice this is a UI action.

### A5. Pushing workflow files needs `workflow` scope — over HTTPS

Modifying anything under `.github/workflows/` with an OAuth/PAT token requires the
`workflow` scope. **This does not apply to SSH pushes** — SSH does not use the token.
Worth knowing when a CI bot cannot push a workflow change but your laptop can.

### A6. Org policies that will bite

| Policy | Effect |
|---|---|
| Actions restricted to selected actions | `peter-evans/create-pull-request`, `actions/create-github-app-token` must be allowlisted, usually pinned to a full commit SHA |
| Required workflows / rulesets at org level | May conflict with or override branch protection here |
| Prevent Actions creating or approving PRs | Blocks `GITHUB_TOKEN` PR creation entirely (see A3) |
| Self-hosted runners only | Needs egress to `app.terraform.io` and the Terraform registry |
| Commit signing required | The App's commits are signed via the API; a runner doing raw `git commit` is not |
| Push protection / secret scanning | Fine here — no secrets are committed. Verify before making a repo public |

### A7. Third-party actions

Pin to a full commit SHA, not a tag. `@v6` is a moving target under someone else's
control, and it runs with access to your job's secrets. Where policy forbids
third-party actions entirely, `peter-evans/create-pull-request` is replaceable with
`gh pr create` plus a `git push`.

---

## Part B — Terraform Cloud

### B1. Stacks entitlement

Check before designing anything around Stacks:

```bash
curl -s -H "Authorization: Bearer $TFE_TOKEN" \
  https://app.terraform.io/api/v2/organizations/<org>/entitlement-set \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['attributes']['stacks'])"
```

If false, the fallback is classic workspaces: one workspace per lane, the security
workspace consuming infra outputs via `tfe_outputs` or a run trigger. Intake,
validation, generation and CODEOWNERS routing are unaffected — those are the parts the
demo is actually about.

### B2. Token type, and the team-token trap

| Token | Scope | Use |
|---|---|---|
| User | Everything that user can reach | Convenient, wrong for CI — dies with the employee |
| Team | Team's projects/workspaces | **Correct for CI**, needs the Team entitlement |
| Organization | Org-level admin | Too broad for a pipeline |

Free tier reports `teams: false`, so a team token is unavailable there and a user token
is the only option. In a corporate org, use a team token scoped to the project holding
these stacks. A user token in `TFE_TOKEN` on a shared repository is a standing audit
finding.

### B3. Both stacks must be in one project

`publish_output`/`upstream_input` resolve **only within a project**. This forces the
two lanes into one project, which means the TFC project stops being an RBAC boundary
between Platform Operations and Security Assurance. Anyone with write on the project can approve either stack.

Compensating controls, in the order they actually bite:

1. The **RAM roles** are disjoint. The infra credential cannot touch RAM; the security
   credential cannot touch compute or storage. This holds regardless of TFC RBAC.
2. **CODEOWNERS** gates the code — nothing reaches a stack without the right team's
   approval on that path.
3. TFC-side approval is then the weakest of the three. Do not present it as the control.

If a hard TFC boundary is mandatory, the trade is: two projects, no `upstream_input`,
and the security lane takes its inputs from platform config instead of from the infra
stack at runtime.

### B4. Variable sets do **not** implicitly apply to Stacks — this is the big one for your AKSK model

A workspace inherits assigned variable sets automatically. **A Stack does not.** It
must declare a `store` block, and the values are then referenced explicitly:

```hcl
store "varset" "alicloud_ops" {
  name     = "alicloud-prod-ops"     # or id = "varset-..."
  category = "env"                   # "terraform" or "env"
}

deployment "prod" {
  inputs = {
    access_key = store.varset.alicloud_ops.ALICLOUD_ACCESS_KEY
    secret_key = store.varset.alicloud_ops.ALICLOUD_SECRET_KEY
  }
}
```

Consequences for an AKSK-in-an-org-variable-set setup:

- **Migrating a workspace to a Stack silently loses the credential.** The variable set
  is still assigned and still visible in the UI; the Stack simply does not read it.
  The failure appears as an authentication error, which sends you looking at RAM.
- **The variable set must be globally available, or assigned to the Stack's project or
  the Stack itself.** Assigned only to *workspaces* is not enough.
- **`category` must match.** `env` for `ALICLOUD_ACCESS_KEY`-style variables,
  `terraform` for HCL inputs. Getting it wrong yields an empty value, not an error.
- **The generator must emit the `store` block.** In this repository that means adding it
  to `templates/_base/*.deployments.j2`, since deployment files are generated. Do not
  hand-add it to `*/stacks/` — the drift guard will fail the PR, correctly.
- `store.varset.<label>.stable.<NAME>` pins the value into state rather than re-reading
  it each run. Consider it for a credential you rotate, so a rotation mid-run does not
  produce a half-authenticated apply.

### B5. AKSK plus assume-role into the workload account

Your model: a long-lived AccessKey/Secret in a TFC org variable set, used to assume a
prod-operations role in the workload account. The provider shape differs from the demo:

```hcl
provider "alicloud" "this" {
  config {
    region     = var.region
    access_key = var.access_key          # from store.varset
    secret_key = var.secret_key
    assume_role {
      role_arn          = var.ops_role_arn
      role_session_name = "tfc-stack-${var.env}"
      # session_expiration = 3600
    }
  }
}
```

versus the demo's keyless form:

```hcl
provider "alicloud" "this" {
  config {
    region = var.region
    assume_role_with_oidc {
      oidc_provider_arn = var.oidc_provider_arn
      role_arn          = var.role_arn
      oidc_token        = var.identity_token
      role_session_name = "tfc-stack-${var.env}"
    }
  }
}
```

Caveats specific to the AKSK path:

1. **The base credential is standing.** It exists whether or not a pipeline is running,
   and its blast radius is every role it may assume. It is the single highest-value
   secret in the system.
2. **Mark both values sensitive and write-only** in the variable set. A `terraform`-category
   variable that is not marked sensitive can surface in plan output.
3. **Rotation is a real project, not a checkbox.** Every Stack referencing the variable
   set is affected simultaneously. Decide in advance whether you rotate in place or
   dual-key.
4. **Ephemerality.** Declare credential inputs `ephemeral = true` in the component
   variable block so they are not persisted into stack state:
   ```hcl
   variable "secret_key" {
     type      = string
     ephemeral = true
   }
   ```
5. **Scope the trust policy.** The ops role should trust only the specific RAM user
   behind the AKSK, not `acs:ram::*:root`.
6. **Separation still needs two roles.** One AKSK is fine; assume a *different*
   ops role per lane, or the "infra cannot touch RAM" property is lost. This is the
   thing most likely to be quietly dropped during implementation, because one role
   works and nothing fails.
7. **Prefer OIDC where the account allows it.** No standing credential, no rotation,
   per-deployment tokens, and audience/subject conditions in the trust policy. The demo
   proves the AliCloud side works: `identity_token` → `assume_role_with_oidc` →
   `sts:AssumeRole` with an `oidc:aud` condition. If OIDC is not permitted in prod, it
   is often permitted in nonprod — run nonprod keyless and confine AKSK to prod.

### B6. VCS connection

`TFC_OAUTH_TOKEN_ID` (`ot-...`) comes from the org's VCS provider connection. Caveats:

- The connection is owned by whoever authorised it. If that is a personal GitHub
  account, stack VCS access dies with their offboarding. Use a GitHub App-based VCS
  connection.
- The connection must have access to the repository. For an org-wide App installation
  this is automatic; for "selected repositories" it is not.
- `oauth-token-id` is required at stack creation. There is no "connect later" state.

### B7. Approval and RBAC

`pending-operator` is the plan-complete-awaiting-human state. Who may approve is
governed by TFC project permissions — and since both lanes share a project (B3), that
is one permission set covering both stacks. No `orchestrate` auto-approve rule is
emitted here, deliberately: every deployment stops between plan and apply.

### B8. Agents and egress

`execution-mode: remote` runs on HashiCorp infrastructure. If policy requires runs
inside your network, you need TFC Agents (a paid entitlement), an agent pool assigned
to the project, and outbound access from the agent to `app.terraform.io`, the provider
registry, and your module registry.

---

## Part C — The credential chain end to end

```
GitHub Actions ──TFE_TOKEN──────────────▶ Terraform Cloud API   (create/patch stacks)
Terraform Cloud ──VCS OAuth (ot-...)────▶ GitHub                (fetch configuration)
Terraform Cloud ──identity_token JWT────▶ AliCloud STS          (demo: keyless OIDC)
                └─store.varset AKSK─────▶ AliCloud STS          (corporate: assume ops role)
AliCloud STS ──────────────────────────▶ per-lane RAM role      (disjoint permissions)
```

Five distinct credentials, five owners, five rotation stories. The one worth the most
attention is the third: replacing standing AKSK with per-deployment OIDC tokens removes
the only long-lived cloud secret in the chain.

---

## Part D — Pre-flight checklist

Run before promising a date.

**GitHub**
- [ ] Org plan supports code-owner enforcement on the repo's visibility
- [ ] Four teams exist, each with write access, verified via API not the UI
- [ ] GitHub App created, installed org-wide, App ID and private key stored
- [ ] Org policy permits the required third-party actions, pinned to SHAs
- [ ] `provision-request` label exists in the repository
- [ ] Branch protection: code-owner review required, ≥1 approval
- [ ] Squash-merge only, so the provisioning diff range is correct
- [ ] `nonprod` (and any other) environment exists

**Terraform Cloud**
- [ ] `stacks: true` in the entitlement set
- [ ] One project holds both lanes; approval permissions on it are understood
- [ ] Team token available, or a documented decision to accept a user token
- [ ] VCS connection owned by an App/service identity, with repo access
- [ ] Variable set holding the AKSK is global or assigned to the project
- [ ] `store` block emitted by the templates, category correct, values sensitive
- [ ] Credential variables declared `ephemeral = true`

**AliCloud**
- [ ] Two ops roles per environment, disjoint: no `ram:*` on the infra role, nothing
      but `ram:*` on the security role
- [ ] Trust policy scoped to the specific principal, not `acs:ram::*:root`
- [ ] If OIDC: provider exists, audience matches `identity_token`, trust policy action
      is `sts:AssumeRole` (not `sts:AssumeRoleWithOIDC` — that returns
      `AuthenticationFail.NoPermission`, which reads like a policy problem and is not)
