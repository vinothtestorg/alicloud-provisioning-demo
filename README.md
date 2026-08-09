# AliCloud schema-driven provisioning — working demo

One repository demonstrating the full automation: a business unit raises an issue
containing two claim manifests, automation validates and generates the Terraform
Stacks code, opens a pull request routed to two different approvers by CODEOWNERS,
and on merge creates the Terraform Cloud stacks with their dependency declared.

Every deterministic part of this has been executed and verified locally
(`bash tests/run_tests.sh` — 13 checks).

## Documentation

| Document | What it covers |
|---|---|
| [docs/01-concepts.md](docs/01-concepts.md) | Claim schemas, service catalog, sizing maps, pins, and how a BU knows what to write |
| [docs/02-workflows.md](docs/02-workflows.md) | Every workflow and action step by step, plus the failure table |
| [docs/03-enterprise-permissions.md](docs/03-enterprise-permissions.md) | GitHub and Terraform Cloud permission caveats, including the AKSK + assume-role model |
| [docs/04-build-checklist.md](docs/04-build-checklist.md) | Phased corporate build for ack, ack-nodepool, oss and ram |
| [docs/diagrams/](docs/diagrams/provisioning-swimlane.drawio) | Swimlane of the whole flow (draw.io) |

## The flow

| Step | What happens | Who acts |
|---|---|---|
| 1 | BU opens an issue from the provisioning template with `manifest.yaml` and `access.yaml` | BU App Owner |
| 2 | `01-intake.yml` parses the issue, validates both claims against the published schemas, generates the stack files, opens a PR authored by a GitHub App | Automation |
| 3 | CODEOWNERS requests **Platform Operations** on `infra/` and **Security Assurance** on `security/`. `02-validate-pr.yml` re-validates and fails if generated files were hand-edited | Platform Operations + Security Assurance |
| 4 | Both code owners approve; the PR is merged | Platform Operations + Security Assurance |
| 5 | `03-provision.yml` ensures two Terraform Cloud stacks exist, bound to the two directories | Automation |
| 6 | `<app>-infra` plans. **Platform Operations** approves the apply | Platform Operations |
| 7 | `<app>-security` waits on the infra stack's `publish_output`, then plans. **Security Assurance** approves the apply | Security Assurance |

## Layout

```
modules/                 module-ack, module-oss, module-ram   (stand-ins for your org modules)
  */claim-schema.yaml    Service Governance overlay: which fields a BU may set
tools/
  build_claim_schemas.py modules -> catalog JSON Schemas + index      (module release CI)
  parse_issue.py         issue body -> the two lane manifests
catalog/
  claim-schemas/         published, BU-facing
  sizing-maps/           t-shirt size -> instance type; access level -> action list
  template-matrix.yaml   module version and template pins
platform/
  environments.yaml      VPC, vSwitch, RAM role ARNs per environment  (Platform Operations owned)
  ensure_stacks.py       idempotent Terraform Cloud stack creation
templates/               Jinja templates rendering Stacks HCL for both lanes
stackforge/cli.py        validate | render | plan-tfc
infra/apps/<app>/        manifest.yaml + generated stacks    CODEOWNERS: Platform Operations
security/apps/<app>/     access.yaml   + generated stacks    CODEOWNERS: Security Assurance
```

## What the guardrails actually stop

Verified by the test suite:

- A BU setting a raw module variable (`worker_instance_type`) — rejected, the field is not in the claim schema
- Granting access to a resource never declared in `manifest.yaml` — rejected by cross-manifest validation
- Referencing an unpublished schema version (`ack/v9`) — rejected
- Hand-editing generated stack files — the PR workflow regenerates and fails on any diff
- An issue whose two YAML blocks disagree on `appId` — rejected before a PR is raised

## Separation of duties

The two lanes use different AliCloud RAM roles: the infrastructure role holds no
`ram:*` permissions, and the security role holds only `ram:*`. Neither pipeline can
complete the other's work, and this is enforced by the cloud credentials rather than
by the review process. On top of that, CODEOWNERS routes `infra/` and `security/` to
two different approving teams, so neither team can merge the other's change.

Both stacks deliberately live in **one** Terraform Cloud project. That is a constraint,
not a preference: `publish_output` and `upstream_input` only resolve between Stacks in
the same project, so splitting the lanes across two projects would render valid HCL that
silently fails to resolve. `stackforge/cli.py` refuses to render if the two projects in
`platform/environments.yaml` differ, so the mistake cannot be reintroduced quietly. The
trade-off is that the Terraform Cloud project is no longer an RBAC boundary between the
teams — GitHub review and the RAM roles carry that weight instead.

## Getting it running

```bash
gh auth login
./bootstrap.sh <github-org> <tfc-org> alicloud-provisioning-demo
```

The script substitutes your organisation names, regenerates, runs the tests, pushes,
and then prints the remaining manual setup (branch protection, secrets, Terraform
Cloud projects and VCS connection, AliCloud RAM roles).

## Stacks details worth knowing

These are the things that are easy to get wrong and expensive to debug later.

- Component files must be named `*.tfcomponent.hcl`. The `*.tfstack.hcl` spelling is
  from the beta and is no longer what the documentation describes.
- `upstream_input.source` is `app.terraform.io/<org>/<project>/<stack>`. Dropping the
  project segment produces HCL that parses and then fails to resolve.
- `publish_output` cannot read `component.*`. A published value is deployment-scoped:
  the components file declares `output "x" { value = component.foo.bar }` and the
  deployment file forwards it as `value = deployment.dev.x`. Published names are
  environment-qualified here, because two deployments publishing the same bare name
  would collide.
- Local module sources must be in canonical form. `./../../modules/x` is rejected
  outright during source bundling even though it resolves perfectly well on disk;
  it has to be written `../../modules/x`.
- The stack's subdirectory is a top-level `working-directory` attribute on the API,
  with no leading slash. Passing it as `vcs-repo.directory` is accepted and then
  silently ignored, leaving the stack pointed at the repository root.
- A Stack fetches its configuration from the repository and never runs an init that
  could resolve providers for itself, so `.terraform-version` and `.terraform.lock.hcl`
  have to be committed inside each stack directory. They are held once in
  `platform/assets/` and copied into both lanes on every render, which keeps the two
  lanes on identical provider versions by construction.

## Known limits of this demo

- The modules are minimal stand-ins. Swap `catalog/template-matrix.yaml` to point at
  your real private-registry sources; the rest of the pipeline is unchanged. They are
  kept valid against the pinned provider version, and no further than that.
- **Nothing here has been applied.** Both stacks plan and then stop at the approval
  gate. The VPC and vSwitch ids in `platform/environments.yaml` are placeholders, so
  an apply would fail — deliberately, since this is a demo of the pipeline.
- The two RAM roles do exist and the OIDC trust chain is real: `tfc-stacks-dev` holds
  ECS, VPC, ACK and OSS access and no `ram:*`, `tfc-sec-dev` holds `ram:*` and nothing
  else. The infra plan authenticates as the first of them.
- No policy-as-code layer yet (Sentinel or OPA) — validation currently sits at the
  schema and the cross-manifest checks.
