#!/usr/bin/env python3
"""Create or update the Terraform Cloud Stacks for an application, idempotently.

Creates two stacks per app, bound to the two CODEOWNERS-routed directories:

  <app>-infra     infra/apps/<app>/stacks
  <app>-security  security/apps/<app>/stacks

Both live in the same project, and that is a constraint rather than a choice:
publish_output and upstream_input only resolve between Stacks in one project, so
splitting the lanes across two projects would break the dependency that the whole
design rests on. Separation of duties is carried by CODEOWNERS routing and by the
two lanes assuming different RAM roles.

The ordering between them is declared in the generated tfdeploy.hcl via
upstream_input, so Terraform Cloud will not plan the security stack until the
infrastructure stack has applied. This script only ensures the stacks exist and
point at the right directory; it never approves or applies anything.

Environment:
  TFE_TOKEN         Terraform Cloud API token  (required)
  TFC_ORG           organisation name          (required)
  OAUTH_TOKEN_ID    VCS OAuth client token id  (required, ot-...)
  REPO              owner/repo identifier      (required)
  BRANCH            branch to track            (default: main)
  DRY_RUN           print intended calls and exit without contacting the API
"""
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://app.terraform.io/api/v2"


def env(name, default=None, required=False):
    val = os.environ.get(name, default)
    if required and not val:
        sys.exit(f"[ensure-stacks] {name} is not set")
    return val


def call(method, path, payload=None, token=None):
    req = urllib.request.Request(
        f"{API}{path}", method=method,
        data=json.dumps(payload).encode() if payload else None,
        headers={"Authorization": f"Bearer {token}",
                 "Content-Type": "application/vnd.api+json"})
    try:
        with urllib.request.urlopen(req) as r:
            body = r.read().decode()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode()
        raise SystemExit(f"[ensure-stacks] {method} {path} failed: {e.code}\n{detail}")


def find_project(org, name, token):
    data = call("GET", f"/organizations/{org}/projects?filter%5Bnames%5D={name}", token=token)
    for item in data.get("data", []):
        if item["attributes"]["name"] == name:
            return item["id"]
    sys.exit(f"[ensure-stacks] project '{name}' not found in organisation '{org}'. "
             f"Create it once in the Terraform Cloud UI, then re-run.")


def find_stack(org, project_id, name, token):
    """Locate a stack by name within a project.

    There is no `GET /projects/{id}/stacks` route — it 404s. The only list route
    is organisation-scoped, and its project filter is not dependable, so match on
    both name and project id here rather than trusting the server to narrow it.
    """
    data = call("GET", f"/organizations/{org}/stacks", token=token)
    for item in data.get("data", []):
        proj = (item.get("relationships", {}).get("project", {})
                    .get("data", {}).get("id"))
        if item["attributes"].get("name") == name and proj == project_id:
            return item["id"]
    return None


def ensure_stack(org, project_id, name, repo, directory, branch, oauth_token_id, token):
    existing = find_stack(org, project_id, name, token)
    # The subdirectory is a top-level `working-directory` attribute. Passing it as
    # `directory` inside vcs-repo is accepted and then silently dropped, which leaves
    # the stack pointed at the repository root with no components to find.
    attributes = {
        "name": name,
        "working-directory": directory,
        "vcs-repo": {"identifier": repo, "oauth-token-id": oauth_token_id,
                     "branch": branch}}
    if existing:
        call("PATCH", f"/stacks/{existing}",
             {"data": {"type": "stacks", "id": existing, "attributes": attributes}},
             token=token)
        return existing, "updated"
    # Create is org-level with the project passed as a relationship, not nested
    # under /projects/{id}.
    created = call("POST", "/stacks", {"data": {
        "type": "stacks",
        "attributes": attributes,
        "relationships": {
            "project": {"data": {"type": "projects", "id": project_id}}}}},
        token=token)
    return created["data"]["id"], "created"


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: ensure_stacks.py <app-id>")
    app = sys.argv[1]

    import yaml
    cfg = yaml.safe_load(open(os.path.join(os.path.dirname(__file__), "environments.yaml")))
    projects = cfg["projects"]

    # Repository-relative and with no leading slash: the API rejects a working
    # directory that starts or ends with one.
    plan = [
        {"name": f"{app}-infra", "project": projects["infra"],
         "directory": f"infra/apps/{app}/stacks", "depends_on": None},
        {"name": f"{app}-security", "project": projects["security"],
         "directory": f"security/apps/{app}/stacks", "depends_on": f"{app}-infra"},
    ]

    if env("DRY_RUN"):
        print("DRY RUN — stacks that would be ensured:")
        print(json.dumps(plan, indent=2))
        print("\nDependency is declared in the generated deployments.tfdeploy.hcl "
              "(upstream_input), not configured through this API call.")
        return

    token = env("TFE_TOKEN", required=True)
    org = env("TFC_ORG", required=True)
    oauth = env("OAUTH_TOKEN_ID", required=True)
    repo = env("REPO", required=True)
    branch = env("BRANCH", "main")

    for spec in plan:
        project_id = find_project(org, spec["project"], token)
        stack_id, action = ensure_stack(org, project_id, spec["name"], repo,
                                        spec["directory"], branch, oauth, token)
        dep = f" (waits on {spec['depends_on']})" if spec["depends_on"] else ""
        print(f"  {action}: {spec['name']} -> {spec['project']} :: {spec['directory']}{dep}")

    print("\nStacks are configured. Terraform Cloud will now fetch the configuration "
          "and plan. Approvals: Platform Operations on the infrastructure stack, Security Assurance on the "
          "security stack — both in the Terraform Cloud UI.")


if __name__ == "__main__":
    main()
