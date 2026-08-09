#!/usr/bin/env python3
"""Parse a provisioning-request issue body into the two lane manifests.

The issue form renders each textarea as a fenced ```yaml block under its label
heading. This extracts them, checks they are parseable and that the appId matches,
and writes them to the Platform Operations and Security Assurance owned paths.

Usage: python tools/parse_issue.py <issue_body_file> <app_id>
Exits non-zero with a human-readable reason the workflow posts back to the issue.
"""
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]


def extract_blocks(body: str) -> list:
    """Return every fenced code block in order."""
    return [m.group(1).strip() for m in
            re.finditer(r"```(?:yaml|yml)?\s*\n(.*?)```", body, re.DOTALL)]


def main():
    body = pathlib.Path(sys.argv[1]).read_text()
    app = sys.argv[2].strip()

    if not re.fullmatch(r"[a-z][a-z0-9-]{2,40}", app):
        sys.exit(f"Application id '{app}' is not valid. Use lowercase letters, "
                 f"digits and hyphens, 3-41 characters.")

    blocks = extract_blocks(body)
    if len(blocks) < 2:
        sys.exit(f"Expected two YAML blocks in the issue (manifest and access), "
                 f"found {len(blocks)}. Use the issue form rather than a blank issue.")

    manifest_raw, access_raw = blocks[0], blocks[1]
    try:
        manifest = yaml.safe_load(manifest_raw)
        access = yaml.safe_load(access_raw)
    except yaml.YAMLError as e:
        sys.exit(f"Could not parse the submitted YAML: {e}")

    if not isinstance(manifest, dict) or not isinstance(access, dict):
        sys.exit("Both blocks must be YAML mappings.")

    for name, doc, kind in (("manifest", manifest, "AppClaim"), ("access", access, "AccessClaim")):
        if doc.get("kind") != kind:
            sys.exit(f"The {name} block declares kind '{doc.get('kind')}', expected '{kind}'. "
                     f"The two blocks may be in the wrong order.")
        declared = doc.get("metadata", {}).get("appId")
        if declared != app:
            sys.exit(f"The {name} block declares appId '{declared}' but the issue "
                     f"says '{app}'. These must match.")

    infra_dir = ROOT / "infra" / "apps" / app
    sec_dir = ROOT / "security" / "apps" / app
    infra_dir.mkdir(parents=True, exist_ok=True)
    sec_dir.mkdir(parents=True, exist_ok=True)
    (infra_dir / "manifest.yaml").write_text(manifest_raw + "\n")
    (sec_dir / "access.yaml").write_text(access_raw + "\n")

    print(f"wrote infra/apps/{app}/manifest.yaml and security/apps/{app}/access.yaml")


if __name__ == "__main__":
    main()
