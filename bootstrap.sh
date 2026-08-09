#!/usr/bin/env bash
# Push this demo into your GitHub organisation and wire it to Terraform Cloud.
# Run on your own machine — your credentials never leave it.
#
#   gh auth login
#   ./bootstrap.sh <github-org> <tfc-org> <repo-name>
set -euo pipefail

ORG=${1:?github org}
TFC_ORG=${2:?terraform cloud org}
REPO=${3:-alicloud-provisioning-demo}
VISIBILITY=${4:-public}

echo "==> Substituting organisation placeholders"
# `sed -i` takes a mandatory backup suffix on BSD and none on GNU, so it cannot be
# written once for both. Python does the substitution identically everywhere.
ORG="$ORG" TFC_ORG="$TFC_ORG" python3 - <<'PY'
import os, pathlib
# Built by concatenation so this script does not contain the placeholder strings
# literally. It used to, and it rewrote itself mid-run — bash reads a script by byte
# offset as it executes, so the file changing underneath it corrupted the parse.
org_tag = "__" + "ORG__"
tfc_tag = "__TFC_" + "ORG__"
subs = {org_tag: os.environ["ORG"], tfc_tag: os.environ["TFC_ORG"]}
skip = {"bootstrap.sh"}
for path in pathlib.Path(".").rglob("*"):
    if not path.is_file() or ".git" in path.parts or path.name in skip:
        continue
    try:
        text = path.read_text()
    except UnicodeDecodeError:
        continue
    new = text
    for old, val in subs.items():
        new = new.replace(old, val)
    if new != text:
        path.write_text(new)
        print(f"  substituted {path}")
PY

echo "==> Regenerating stacks so the committed output matches the substituted config"
python3 tools/build_claim_schemas.py
python3 stackforge/cli.py render --app claims-app

echo "==> Verifying before push"
bash tests/run_tests.sh

echo "==> Creating and pushing ${ORG}/${REPO}"
git init -q -b main
git add -A
git commit -qm "AliCloud schema-driven provisioning demo"
# Public on purpose: "Require review from Code Owners" is a paid-plan feature on
# private repos, so on a free org a private demo would route reviewers without
# ever blocking a merge — which is precisely the control being demonstrated.
gh repo create "${ORG}/${REPO}" --${VISIBILITY} --source . --push

cat <<'NEXT'

==================== REMAINING MANUAL SETUP ====================

GitHub — teams referenced by CODEOWNERS (create if they do not exist):
  @<org>/platform-operations  @<org>/security-assurance  @<org>/service-governance  @<org>/pipeline-engineering

GitHub — repository settings:
  Settings > Branches > add a rule for `main`:
      - Require a pull request before merging
      - Require review from Code Owners        <-- this is what enforces the split
  Settings > Secrets and variables > Actions:
      Secrets:    INTAKE_APP_PRIVATE_KEY  (GitHub App private key, PEM)
                  TFE_TOKEN               (Terraform Cloud API token)
      Variables:  INTAKE_APP_ID           the GitHub App's numeric id
                  TFC_ORG                 your Terraform Cloud organisation
                  TFC_OAUTH_TOKEN_ID      ot-xxxxxxxx, from the VCS provider below

  The intake pull request is opened by a GitHub App, for two reasons. Pull requests
  created with the default GITHUB_TOKEN do not trigger further workflow runs, so the
  validation workflow would silently never fire. And GitHub forbids approving your own
  pull request, so a human author could not approve their own lane — one person would
  end up covering both teams and the separation of duties would stop being real.

Terraform Cloud:
  1. Create ONE project: bu1-nonprod. Both stacks go in it — upstream_input
     does not resolve across projects, so a split would break the dependency.
  2. Settings > Providers > connect GitHub, then copy the OAuth token id (ot-...)
  3. Create two workspaces-level API tokens or one org token for TFE_TOKEN

AliCloud (only needed for a real apply):
  1. RAM > OIDC provider trusting app.terraform.io
  2. Role tfc-stacks-dev    — compute/storage permissions, NO ram:* actions
  3. Role tfc-sec-dev       — ram:* actions only, no compute or storage
  4. Update platform/environments.yaml with the real ARNs, VPC and vSwitch ids

Then run the demo:
  Open a new issue using the "Infrastructure provisioning request" template,
  paste the two YAML blocks, and submit.

NEXT
