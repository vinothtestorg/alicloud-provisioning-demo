# Documentation

| Document | What it covers |
|---|---|
| [01-concepts.md](01-concepts.md) | Claim schemas, the service catalog, sizing maps, pins, the two lanes, and how a business unit discovers what it may ask for |
| [02-workflows.md](02-workflows.md) | Every workflow and action step by step, what Terraform Cloud does after the merge, and the failure table |
| [03-enterprise-permissions.md](03-enterprise-permissions.md) | GitHub and Terraform Cloud permission caveats in a corporate org, including the AKSK + assume-role credential model |
| [04-build-checklist.md](04-build-checklist.md) | Phased, repeatable build for ack, ack-nodepool, oss and ram, hardened for enterprise use |
| [diagrams/provisioning-swimlane.drawio](diagrams/provisioning-swimlane.drawio) | Swimlane of the whole flow. Open with diagrams.net or the VS Code Draw.io extension |

`diagrams/gen_swimlane.py` regenerates the diagram. It is a generator rather than
hand-authored XML so lane heights and step positions stay consistent when a step is
inserted.
