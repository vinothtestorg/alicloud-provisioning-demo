# Concepts — claims, catalog, sizing maps and pins

This explains what each moving part is, why it exists, and what breaks without it.
Read it before `02-workflows.md`, which assumes these terms.

---

## 1. The problem being solved

A business unit wants a Kubernetes cluster, a bucket, and permission for their
application to read and write objects in that bucket. Three ways to give it to them:

| Approach | What goes wrong |
|---|---|
| BU raises a ticket, platform writes Terraform | Platform is the bottleneck. Every request is bespoke, nothing is comparable, and the queue is the product. |
| BU writes their own Terraform | Nothing constrains them. Someone sets `instance_type = ecs.g8.32xlarge`, someone else writes a RAM policy with `Action: "*"`, and review is the only control. Review does not scale and reviewers get tired. |
| **BU declares a claim; platform generates the Terraform** | The BU says *what*, the platform decides *how*. The set of expressible requests is bounded by a schema, so a dangerous request cannot be written, let alone reviewed. |

The third is what this repository implements. The central idea: **a business unit
never writes Terraform and never sees a module variable.** They write a short YAML
claim against a published schema, and automation produces the HCL.

---

## 2. Claim schema

### What it is

A claim schema is the contract for one resource type. It is a JSON Schema, published
into `catalog/claim-schemas/<type>/<version>.json`, that defines exactly which fields
a BU may set, what values are acceptable, and which are mandatory.

It is **not** the module's variable list. It is a deliberately smaller subset.

### Why it is smaller

A Terraform module has an internal surface — every `variable` it declares. Most of
those exist so the platform can wire the module into a landing zone: VPC ids, vSwitch
ids, tags, provider plumbing. A BU has no business setting them, and a few of them are
actively dangerous to expose.

The current numbers, printed by the build:

```
published ack/v1: 8 module variables -> 3 BU-settable fields
published oss/v1: 6 module variables -> 4 BU-settable fields
published ram/v1: 10 module variables -> 3 BU-settable fields
```

24 internal variables collapse to 10 BU-settable fields. The other 14 are platform
concerns and are not expressible in a claim at all.

### How it is structured

Two files per module, with different owners:

```
modules/module-ack/
  variables.tf         # Module author owns. The full internal surface.
  claim-schema.yaml    # Service Governance owns. Which of those a BU may set.
```

`claim-schema.yaml` is an **overlay**. It names fields and says how each maps down:

```yaml
module: ack
claim_version: v1
exposed:
  name:
    required: true
    type: string
    pattern: "^[a-z][a-z0-9-]{2,30}$"
    maps_to: cluster_name          # BU says "name", module wants "cluster_name"
    description: >-
      Cluster name. Lower-case letters, digits and hyphens, 3-31 characters.
  size:
    required: true
    type: string
    enum_from_sizing: sizes        # allowed values come from the sizing map
    virtual: true                  # no single module variable behind it
    description: >-
      T-shirt size. The platform resolves it to a worker instance type and node count.
  namespaces:
    required: false
    type: array
    default: []
    description: Kubernetes namespaces to create on the cluster.
```

Three field kinds:

- **Direct** — `maps_to` names a real module variable. `name` becomes `cluster_name`.
- **Virtual** — `virtual: true`, no single variable behind it. `size` becomes *two*
  variables (`worker_instance_type` and `worker_count`) via the sizing map.
- **Passthrough** — no `maps_to`, the names already agree (`namespaces`).

### The build refuses to publish a lie

`tools/build_claim_schemas.py` parses `variables.tf` with `python-hcl2` and cross-checks
every non-virtual exposed field:

```python
if not spec.get("virtual") and target not in variables:
    sys.exit(f"ERROR [{mod.name}]: exposed field '{field}' maps to "
             f"'{target}' which is not declared in variables.tf")
```

So a schema promising a field the module does not have cannot be published. Without
this check the failure surfaces much later, as a Terraform error in a BU's pipeline,
where it looks like the BU's fault.

### Why per-module, and why versioned

Per-module because ownership is per-module: whoever owns `module-ram` and the Security Assurance team
decide what a RAM claim may express, and that decision should not be entangled with
what an OSS claim may express.

Versioned (`ack/v1`) because a claim schema is a published API. Widening it is
backwards-compatible; narrowing it is not. A `v2` lets both exist while BUs migrate,
and a manifest naming an unpublished version is rejected up front:

```
components[0]: unknown claimSchema 'ack/v9' — not published in the catalog
```

---

## 3. The service catalog

`catalog/` is the published, BU-facing contract. Everything in it is **generated** —
regenerating must always be safe.

```
catalog/
  claim-schemas/<type>/<version>.json   JSON Schema, the machine-readable contract
  index.json                            every claim type and every field, with values
  CATALOG.md                            the same thing as a readable page
  sizing-maps/<type>.yaml               t-shirt size -> concrete settings
  template-matrix.yaml                  module source, version pin, template, lane
```

### Why a catalog rather than "read the modules"

Three different audiences need three different things from the same facts:

- **A BU** needs to know what they may ask for. They should never open a `.tf` file.
- **Validation** needs a machine-readable contract — hence JSON Schema.
- **The generator** needs to know which module and template to use for a claim type.

The catalog is the one place all three read from, so they cannot disagree.

### The split between schema and sizing map

Both are service-governance-owned but they change for different reasons and on different
cadences:

- **Claim schema** — changes when the *shape* of what a BU may ask for changes.
  Adding a field is an API change. Rare, and reviewed as an API change.
- **Sizing map** — changes when the *meaning* of an existing choice changes. Moving
  `small` from `ecs.g6.large` to `ecs.g7.large` is a fleet decision. Common, and it
  touches no BU manifest.

That second property is the point. Re-sizing every `small` cluster in the estate is a
one-line edit in `catalog/sizing-maps/ack.yaml` plus a re-render. No BU is asked to
change anything, and no BU can refuse.

```yaml
# catalog/sizing-maps/ack.yaml
sizes:
  small:  { worker_instance_type: ecs.g6.large,   worker_count: 2 }
  medium: { worker_instance_type: ecs.g6.xlarge,  worker_count: 3 }
  large:  { worker_instance_type: ecs.g6.2xlarge, worker_count: 5 }
```

The RAM map is the same mechanism applied to privilege, and it is the most important
one in the repository:

```yaml
# catalog/sizing-maps/ram.yaml — Security Assurance owns this file
levels:
  read:      { policy_actions: ["oss:GetObject", "oss:ListObjects"] }
  readwrite: { policy_actions: ["oss:GetObject", "oss:ListObjects",
                                "oss:PutObject", "oss:DeleteObject"] }
```

A BU asks for `level: readwrite`. They cannot enumerate API actions, so they cannot
ask for `ram:CreateUser` or `oss:*`. **Privilege escalation is not a thing the claim
language can express.** That is a stronger guarantee than "a reviewer would catch it".

---

## 4. Pins

"Pin" means a version deliberately fixed in a service-governance-owned file rather than
floating. There are four, and they pin different things.

| Pin | Where | What it fixes | Who bumps it |
|---|---|---|---|
| Module version | `catalog/template-matrix.yaml` → `module_version` | Which release of the module a claim type resolves to | Service Governance, via a bump PR |
| Module source | `catalog/template-matrix.yaml` → `module_source` | Where the module comes from — local path here, private registry in a real org | Service Governance |
| Claim schema version | the manifest's `claimSchema: ack/v1` | Which published contract this manifest is written against | The BU, when they migrate |
| Provider version | `.terraform.lock.hcl` + `required_providers` in the rendered HCL | Exact provider build, by hash | Platform, via a lock refresh |

```yaml
# catalog/template-matrix.yaml
modules:
  ack:
    module_source: "../../../../modules/module-ack"   # real org: app.terraform.io/<ORG>/ack/alicloud
    module_version: "1.0.0"
    template: ack/v1
    lane: infra
```

### Why pins are central rather than per-app

If each application pinned its own module version, the estate would fragment: sixty
apps on nine versions, and a security fix would mean sixty pull requests raised
against sixty teams with sixty different release schedules.

Pinning centrally inverts it. One bump PR to `template-matrix.yaml`, re-render, and
every application moves together. The blast radius is visible in one diff, and the
rollback is one revert.

`lane` decides which side of the CODEOWNERS split a claim type renders into. `ram` is
`lane: security`, so RAM output lands under `security/` and is routed to Security Assurance. It is
the single fact connecting the type system to the approval model.

---

## 5. How a BU knows what to write

Four routes, in decreasing order of how much you should rely on them:

1. **`catalog/CATALOG.md`** — generated from the schemas on every build. Every field,
   type, whether it is required, allowed values, and what each value resolves to.
   Generated on purpose: a hand-written catalogue that drifts is worse than none,
   because people trust it.
2. **The issue form** — `.github/ISSUE_TEMPLATE/provision-request.yml` carries a
   worked example in its placeholder. Most BUs copy it and edit.
3. **`catalog/index.json`** — the same content as CATALOG.md, machine-readable, for a
   future portal or IDE integration.
4. **Validation feedback** — get it wrong and automation comments on the issue with
   the exact violation. A slow teacher, but never silent.

A sample of the generated page:

| Field | Type | Required | Allowed values | Description |
|---|---|---|---|---|
| `name` | string | yes | pattern `^[a-z][a-z0-9-]{2,30}$` | Cluster name, 3-31 chars. |
| `size` | string | yes | `large`, `medium`, `small` | T-shirt size, resolved by the platform. |
| `namespaces` | array | no | — | Namespaces to create. Default `[]`. |

What `size` resolves to:

| Value | Resolves to |
|---|---|
| `small` | `{"worker_instance_type": "ecs.g6.large", "worker_count": 2}` |
| `medium` | `{"worker_instance_type": "ecs.g6.xlarge", "worker_count": 3}` |
| `large` | `{"worker_instance_type": "ecs.g6.2xlarge", "worker_count": 5}` |

### Acceptable values live in the schema, and are derived

Yes — and this was tightened rather than merely documented. Every constrained field
publishes its constraint in the schema itself: `enum` for closed sets, `pattern` for
names, `default` for optional fields, `description` for intent.

The part worth understanding is where an `enum` comes from. Virtual fields do **not**
restate their allowed values. They declare where the values live:

```yaml
size:
  enum_from_sizing: sizes    # keys of catalog/sizing-maps/ack.yaml -> sizes
```

The builder reads the sizing map, uses its keys as the enum, and attaches
`x-resolves-to` so the schema also publishes what each choice means.

This matters because restating drifts in both directions, and both are silent:

- A size in the overlay but missing from the map → validates, then fails at render.
- A size in the map but missing from the overlay → silently unusable; the BU is told
  their perfectly reasonable request is invalid.

Deriving makes both impossible. Adding `xlarge` to the sizing map makes it claimable
and documented with no other edit anywhere, and test 13 asserts exactly that.

---

## 6. The two lanes

The repository is split by *who approves*, not by resource type:

```
infra/apps/<app>/manifest.yaml      what the app needs      CODEOWNERS: @org/platform-operations
security/apps/<app>/access.yaml     who may reach it        CODEOWNERS: @org/security-assurance
```

Each renders into its own Terraform Cloud stack, and each stack assumes a different
RAM role. The infra role holds no `ram:*`; the security role holds nothing but
`ram:*`. Neither pipeline can complete the other's work even if someone wanted it to,
because the credential will not permit it.

### Cross-manifest validation

The two lanes are separately owned but not independent. A grant must refer to
something the app actually asked for:

```python
if resource and resource not in declared:
    errs.append(f"{kind} '{name}': grants access to '{resource}', "
                f"which is not declared in manifest.yaml (declared: {sorted(declared)})")
```

Without it, `security/` becomes a side door: a grant against a bucket in another
business unit's account would pass a schema check and read as a routine access
request in review.

---

## 7. Determinism

`stackforge/cli.py render` is a pure function of its inputs. The same manifest,
catalog and templates always produce byte-identical output. This is load-bearing, not
tidiness:

- **Review means something.** Reviewers see the actual HCL, not a manifest diff they
  have to imagine the output of.
- **Drift is detectable.** `02-validate-pr.yml` re-renders and fails on any diff, so a
  hand-edit of generated code cannot merge.
- **Re-running is free.** Idempotence means the pipeline can always re-render.

Every generated file carries its provenance:

```hcl
# GENERATED by stack-forge 0.2.0 — DO NOT HAND-EDIT.
# Source of record: infra/apps/policy-app/manifest.yaml
# source sha256: e34965232167da48
# Change the manifest and re-run the pipeline; edits here are overwritten.
```

The digest is of the source manifest, so any generated file can be traced to the exact
claim that produced it.
