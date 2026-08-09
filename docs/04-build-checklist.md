# Corporate build checklist — enterprise-hardened, repeatable

How to rebuild this in a corporate environment for the four real module types:
**ack**, **ack-nodepool**, **oss**, **ram**.

The demo proves the mechanism. This is what changes when it has to survive an audit,
an on-call rotation, and the person who built it leaving.

Phases are ordered by dependency. Each has an acceptance check — a command whose output
you can paste into a ticket. "It looked right in the UI" is not an acceptance check.

---

## Phase 0 — Decisions to make before writing anything

Each of these is expensive to reverse once applications are onboarded.

| Decision | Options | Default recommendation |
|---|---|---|
| Repository topology | One repo per app, or one repo for all apps | **One repo per app.** CODEOWNERS stays simple, blast radius is one app, and the provisioning diff range is trivial |
| Stack granularity | One stack per lane per app, or per environment | **Per lane per app.** Matches the approval split |
| Project layout | One TFC project per BU, or per environment | **Per BU per environment tier.** Both lanes must share a project |
| Credential model | OIDC, or AKSK + assume role | **OIDC where permitted**, AKSK confined to prod if policy demands |
| Module distribution | Private registry, or git refs | **Private registry.** Semantic versions and a real publish gate |
| Catalog distribution | Shared repo, or a data-carrier action | **Data-carrier action** (see Phase 2) |
| Environment promotion | Branch per env, or deployment blocks | **Deployment blocks in one stack.** One configuration, many deployments |

Write these down with names against them. Every one is a question someone will
re-litigate in month four.

---

## Phase 1 — Module repositories

One repository per module: `terraform-alicloud-ack`, `terraform-alicloud-ack-nodepool`,
`terraform-alicloud-oss`, `terraform-alicloud-ram`.

### 1.1 Structure

```
terraform-alicloud-<x>/
  main.tf  variables.tf  outputs.tf  versions.tf
  claim-schema.yaml            # Service Governance-owned overlay
  examples/                    # at least one per major use
  tests/                       # terraform test, or terratest
  .github/workflows/release.yml
  CHANGELOG.md
```

### 1.2 Hardening per module

- [ ] `required_version` and `required_providers` pinned with `~>`
- [ ] Every variable has a `description` and a `type`; no bare `any`
- [ ] `validation` blocks on anything with a constrained shape
- [ ] Sensitive outputs marked `sensitive = true`
- [ ] No `provider` blocks inside the module — callers configure providers
- [ ] Tagging is mandatory and enforced, not defaulted to `{}`
- [ ] `tflint` and `checkov` clean, or documented suppressions with justification
- [ ] `terraform test` covers at least one plan-time assertion per resource

### 1.3 Module-specific notes

**ack** — the control-plane module only. Do not manage node pools here; that is what
`ack-nodepool` is for, and mixing them makes a node-pool change a cluster change.
`worker_instance_types` and `worker_number` were **removed** in provider 1.212.0 —
node sizing belongs in the node pool resource. Use `vswitch_ids`, not the deprecated
`worker_vswitch_ids`. Expose `enable_rrsa` and default it on: the RAM lane depends on
the RRSA issuer existing.

**ack-nodepool** — must accept a cluster id as an input, so it can be claimed
independently of the cluster. This is what makes "add a GPU pool" a small change. Key
claim fields are size and desired count; taints, labels and runtime versions are
platform concerns and should not be BU-settable without a specific decision.

**oss** — bucket naming is globally unique across AliCloud, so a claim-time pattern is
not enough; add a platform prefix (`<org>-<bu>-<app>-<name>`) during rendering.
Versioning, encryption and public-access-block should be platform defaults that a claim
cannot weaken. Expose `prefixes`, because the RAM lane scopes grants to them.

**ram** — the one that needs the most care. Never expose action lists. Expose an access
*level* that resolves through a Security Assurance-owned map. Keep role, policy and group naming
entirely platform-generated. Trust policies must be scoped: for RRSA, condition on both
`oidc:iss` and `oidc:sub`, never just the issuer, or any service account in the cluster
can assume the role.

### 1.4 Release pipeline

- [ ] Tag triggers: validate → test → publish to the private registry
- [ ] The same job rebuilds the claim schema and opens a PR against the catalog
- [ ] Publish is gated on tests passing; no manual publish path

**Acceptance:** `terraform init` against the registry source resolves the new version,
and the catalog PR appears automatically on tag.

---

## Phase 2 — Catalog repository

`alicloud-service-catalog`, owned by Service Governance. This is a service-governance artefact, not a
library.

- [ ] `catalog/claim-schemas/<type>/<version>.json` — generated, never hand-edited
- [ ] `catalog/sizing-maps/<type>.yaml` — Platform Operations owns sizes, **Security Assurance owns `ram.yaml`**
- [ ] `catalog/template-matrix.yaml` — module source, version pin, template, lane
- [ ] `catalog/CATALOG.md` and `index.json` — generated
- [ ] CODEOWNERS: `ram.yaml` requires Security Assurance approval, independent of everything else
- [ ] A guard workflow that fails if a generated file was hand-edited
- [ ] Channel branches — `catalog-nonprod`, `catalog-prod` — so a change soaks in
      nonprod before prod is promoted onto it

Distribute the catalog as a **data-carrier action** rather than a cross-repo checkout:
consumers reference `your-org/alicloud-service-catalog@catalog-nonprod` and the action
materialises the catalog into the workspace. No token, no cross-repo permission, and
the channel ref is the rollout gate.

**Acceptance:** a sizing-map change merged to `catalog-nonprod` reaches a consuming
repo's next render with no change in the consumer, and the same change is not visible
to `catalog-prod` consumers until promoted.

---

## Phase 3 — Generator

`stack-forge`, published as a versioned composite action.

- [ ] Semantic versioning; consumers pin `@v1.2.0`, never `@main`
- [ ] Deterministic: same inputs, byte-identical output. Enforced by a test
- [ ] `.terraform-version` and `.terraform.lock.hcl` copied into every stack directory
- [ ] Emits a `.stackforge-generated` ledger listing owned files, so the drift guard
      knows exactly what it governs
- [ ] Renders the `store "varset"` block when the credential model is AKSK
- [ ] Refuses to render when the two lanes resolve to different TFC projects
- [ ] Provenance header on every file: manifest digest, catalog channel and digest,
      template digest, forge version

That header is what makes an incident tractable. Given any generated file you can
recover exactly which manifest, which catalog channel and which forge version produced
it, without guessing.

**Acceptance:** rendering the same manifest twice produces no diff; rendering with a
bumped catalog produces a diff confined to the pinned version.

---

## Phase 4 — Application repository template

A repository template so onboarding an app is one click, not a tutorial.

- [ ] `infra/apps/<app>/manifest.yaml`, `security/apps/<app>/access.yaml`
- [ ] `.github/CODEOWNERS` with real teams
- [ ] Three workflows: intake, validate, provision
- [ ] `.gitattributes` with `* text=auto eol=lf` — otherwise a developer with
      `core.autocrlf=true` fails the drift check on every PR
- [ ] `.github/ISSUE_TEMPLATE/provision-request.yml`
- [ ] `platform/environments.yaml` — Platform Operations-owned
- [ ] Branch protection applied by automation, not by hand

**Acceptance:** a new repo from the template, with no edits, accepts an issue and
produces a correctly routed PR.

---

## Phase 5 — Identity and access

Per environment, per lane. This is where the separation stops being a diagram.

- [ ] OIDC provider trusting `app.terraform.io`, audience per organisation
- [ ] Trust policy action is `sts:AssumeRole` — **not** `sts:AssumeRoleWithOIDC`.
      The latter yields `AuthenticationFail.NoPermission`, which reads like a
      permissions problem and is a policy-shape problem
- [ ] Condition on `oidc:aud`; add `oidc:sub` where the provider supports it
- [ ] `tfc-<env>-infra` — compute, storage, network. **No `ram:*`**
- [ ] `tfc-<env>-security` — `ram:*` only. No compute, no storage
- [ ] Both roles created by Terraform in a bootstrap stack, not by hand
- [ ] A recurring check asserting the two policy sets remain disjoint

**Acceptance:** assume the infra role and attempt `ram:CreateRole` — it must be denied.
Assume the security role and attempt `ecs:RunInstances` — it must be denied. Run both
as a scheduled job; permission creep is gradual and nobody notices it happening.

---

## Phase 6 — Terraform Cloud

- [ ] Confirm `stacks: true` entitlement before anything else
- [ ] Projects per BU and tier; both lanes share a project
- [ ] Team tokens, not user tokens
- [ ] VCS connection via a GitHub App, not a personal account
- [ ] Variable sets scoped to projects; AKSK marked sensitive; `store` block emitted
- [ ] No auto-approve `orchestrate` rules in regulated environments
- [ ] Drift detection enabled where the entitlement allows

**Acceptance:** a merge creates both stacks with the correct working directories, the
infra stack plans, and the security stack reports waiting on its upstream.

---

## Phase 7 — Observability and operations

Usually skipped, and the reason this looks fragile at month six.

- [ ] Every workflow writes a step summary a non-expert can read
- [ ] Failed intake always comments on the issue — never fails silently
- [ ] Alert on: intake failure rate, stacks stuck in `pending-operator`, config fetch
      failures, drift-check failures
- [ ] Runbooks for the top five failures in `02-workflows.md` §5
- [ ] A quarterly game day: break a template deliberately, confirm the guard fires

---

## Phase 8 — Rollout

1. **Pilot** — one non-critical app, one BU, nonprod only. Target: an issue reaching a
   green plan without platform intervention.
2. **Soak** — four weeks. Track how often a BU needs help. If that number is not
   falling, the catalog is not discoverable enough; fix `CATALOG.md` before onboarding
   more.
3. **Widen** — five apps across two BUs. Now exercise a sizing-map bump and confirm the
   fleet moves without touching a single manifest.
4. **Promote to prod** — after a catalog channel promotion has been rehearsed.
5. **Deprecate the ticket queue** — only once the pilot BU prefers the new path. If
   they do not, find out why rather than mandating it.

---

## The repeatable per-application procedure

Once the platform exists, onboarding is:

1. Create the app repository from the template.
2. Grant the four teams write access.
3. Set `TFE_TOKEN`, `INTAKE_APP_ID`, `INTAKE_APP_PRIVATE_KEY`, `TFC_ORG`,
   `TFC_OAUTH_TOKEN_ID`.
4. Create the `provision-request` label. **It is not created automatically.**
5. Apply branch protection.
6. BU raises an issue.
7. Platform Operations and Security Assurance approve their lanes.
8. Approve the plans in Terraform Cloud.

Steps 1–5 should be a single script. If they are still manual at the tenth application,
the platform has a bottleneck in exactly the place it was built to remove.

---

## Things that will go wrong, ranked by likelihood

1. **The label does not exist.** Nothing happens. No error anywhere.
2. **A CODEOWNERS team lacks write access.** Rule silently matches nothing.
3. **A variable set is assigned but the Stack has no `store` block.** Authentication
   fails and you go looking at RAM.
4. **A pipeline pipes into `tee` without `pipefail`.** Failures report success.
5. **Someone hand-edits generated HCL** because it was faster. The guard catches it —
   provided the workflow's path filter includes the generated paths.
6. **Both lanes end up sharing one RAM role** because one role worked and nothing
   failed. The separation quietly stops existing.
7. **A module version pin is bumped without re-rendering.** The drift check catches it
   on the next PR, which may be weeks later.
8. **The OIDC audience does not match** between the trust policy and `identity_token`.
