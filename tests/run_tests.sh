#!/usr/bin/env bash
# Local verification of everything that does not need cloud credentials.
set -uo pipefail
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

# In-place literal substitution that behaves the same on GNU and BSD userland.
# `sed -i` differs between the two and BSD sed does not expand \n in the
# replacement, so the guardrail tests below use this instead.
subst() { python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    text = fh.read()
assert old in text, f"pattern not found in {path}: {old!r}"
with open(path, "w") as fh:
    fh.write(text.replace(old, new, 1))
PY
}

echo "== 1. Claim schemas build from the modules =="
python3 tools/build_claim_schemas.py >/dev/null 2>&1 && ok "schemas published" || bad "schema publish"

echo "== 2. Valid claims pass validation =="
python3 stackforge/cli.py validate --app claims-app >/dev/null 2>&1 && ok "claims-app validates" || bad "claims-app validation"

echo "== 3. Render produces both lanes =="
python3 stackforge/cli.py render --app claims-app >/dev/null 2>&1 \
  && [ -f infra/apps/claims-app/stacks/components.tfcomponent.hcl ] \
  && [ -f security/apps/claims-app/stacks/components.tfcomponent.hcl ] \
  && ok "both lanes rendered" || bad "render"

echo "== 4. Render is idempotent =="
BEFORE=$(find infra/apps/claims-app/stacks security/apps/claims-app/stacks -type f -exec sha256sum {} \; | sort)
python3 stackforge/cli.py render --app claims-app >/dev/null 2>&1
AFTER=$(find infra/apps/claims-app/stacks security/apps/claims-app/stacks -type f -exec sha256sum {} \; | sort)
[ "$BEFORE" = "$AFTER" ] && ok "re-render byte-identical" || bad "not idempotent"

echo "== 5. Cross-stack dependency is wired end to end =="
# All four links are checked, because three of them can be present while the chain
# is still broken. publish_output cannot read component.* directly: the components
# file has to declare a stack output, the deployment file forwards that output under
# an environment-qualified name, and the security stack consumes that exact name.
I=infra/apps/claims-app/stacks
S=security/apps/claims-app/stacks
grep -q 'output "cluster_rrsa_issuer"'                       "$I/components.tfcomponent.hcl" \
  && grep -q 'value       = component\.'                     "$I/components.tfcomponent.hcl" \
  && grep -q 'publish_output "dev_cluster_rrsa_issuer"'      "$I/deployments.tfdeploy.hcl" \
  && grep -q 'value       = deployment\.dev\.'               "$I/deployments.tfdeploy.hcl" \
  && grep -q 'upstream_input "infra"'                        "$S/deployments.tfdeploy.hcl" \
  && grep -q 'upstream_input\.infra\.dev_cluster_rrsa_issuer' "$S/deployments.tfdeploy.hcl" \
  && ! grep -qE '^\s*value\s+= component\.' "$I/deployments.tfdeploy.hcl" \
  && ok "output -> publish_output -> upstream_input chain intact" || bad "dependency wiring"

echo "== 6. Guardrail: BU cannot set a raw instance type =="
cp infra/apps/claims-app/manifest.yaml /tmp/m.bak
subst infra/apps/claims-app/manifest.yaml \
  '    size: small' '    size: small
    worker_instance_type: ecs.g6.26xlarge'
OUT=$(python3 stackforge/cli.py validate --app claims-app 2>&1 || true)
grep -q "Additional properties" <<< "$OUT" && ok "raw module variable rejected" || bad "guardrail did not fire"
cp /tmp/m.bak infra/apps/claims-app/manifest.yaml

echo "== 7. Guardrail: cannot grant access to an undeclared resource =="
cp security/apps/claims-app/access.yaml /tmp/a.bak
subst security/apps/claims-app/access.yaml \
  '    resource: claims-documents' '    resource: some-other-bucket'
OUT=$(python3 stackforge/cli.py validate --app claims-app 2>&1 || true)
grep -q "not declared in manifest.yaml" <<< "$OUT" && ok "cross-manifest access check fired" || bad "access check did not fire"
cp /tmp/a.bak security/apps/claims-app/access.yaml

echo "== 8. Guardrail: unknown claim schema rejected =="
cp infra/apps/claims-app/manifest.yaml /tmp/m.bak
subst infra/apps/claims-app/manifest.yaml \
  'claimSchema: ack/v1' 'claimSchema: ack/v9'
OUT=$(python3 stackforge/cli.py validate --app claims-app 2>&1 || true)
grep -q "unknown claimSchema" <<< "$OUT" && ok "unpublished schema version rejected" || bad "schema version check did not fire"
cp /tmp/m.bak infra/apps/claims-app/manifest.yaml

echo "== 9. Issue parser produces both manifests =="
OUT=$(python3 tools/parse_issue.py tests/fixtures/issue-good.md claims-app 2>&1 || true)
grep -q "wrote infra/apps" <<< "$OUT" && ok "issue parsed" || bad "issue parse"

echo "== 10. Issue parser rejects a mismatched appId =="
OUT=$(python3 tools/parse_issue.py tests/fixtures/issue-bad-appid.md claims-app 2>&1 || true)
grep -q "must match" <<< "$OUT" && ok "appId mismatch rejected" || bad "appId check"

echo "== 11. Local module paths are canonical and resolve =="
# Two distinct failures are checked here. A path that does not resolve is the
# obvious one. The other is a path that resolves perfectly well on disk but is not
# in canonical form: HCP Terraform rejects a "./../" prefix outright during source
# bundling, with the stack failing before it ever reaches a plan.
BAD=0
FOUND=0
for f in infra/apps/claims-app/stacks/components.tfcomponent.hcl security/apps/claims-app/stacks/components.tfcomponent.hcl; do
  d=$(dirname "$f")
  while read -r src; do
    FOUND=$((FOUND+1))
    [ -d "$d/$src" ] || { echo "    unresolvable: $src (from $d)"; BAD=1; }
    case "$src" in
      ./*) echo "    not canonical: $src — HCP Terraform requires '../', not './../'"; BAD=1 ;;
    esac
  done < <(grep -oE 'source *= *"\.[^"]+"' "$f" | sed 's/.*"\(.*\)"/\1/')
done
# Guards against the check silently passing because the pattern matched nothing.
[ "$FOUND" -gt 0 ] || { echo "    no local module sources found — pattern is stale"; BAD=1; }
[ "$BAD" -eq 0 ] && ok "module sources canonical and resolvable ($FOUND checked)" || bad "module source problem"

echo "== 12. TFC stack plan is correct (dry run) =="
OUT=$(DRY_RUN=1 python3 platform/ensure_stacks.py claims-app 2>&1 || true)
grep -q "claims-app-security" <<< "$OUT" && ok "two stacks planned with dependency" || bad "stack plan"

echo "== 13. Published enums come from the sizing maps, not a second copy =="
# The drift this prevents: a size listed in the overlay but missing from the map
# validates and then fails at render; one in the map but missing from the overlay is
# silently unusable. Adding a size to the map must make it claimable and documented
# with no other edit anywhere.
cp catalog/sizing-maps/ack.yaml /tmp/s.bak
subst catalog/sizing-maps/ack.yaml \
  '  large:' '  xlarge: { worker_instance_type: ecs.g6.4xlarge, worker_count: 8 }
  large:'
python3 tools/build_claim_schemas.py >/dev/null 2>&1
grep -q '"xlarge"' catalog/claim-schemas/ack/v1.json \
  && grep -q 'ecs.g6.4xlarge' catalog/CATALOG.md \
  && ok "a new size became claimable and documented with no schema edit" \
  || bad "sizing map is not the single source of allowed values"
cp /tmp/s.bak catalog/sizing-maps/ack.yaml
python3 tools/build_claim_schemas.py >/dev/null 2>&1

python3 stackforge/cli.py render --app claims-app >/dev/null 2>&1
echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
