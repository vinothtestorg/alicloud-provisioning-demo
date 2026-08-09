#!/usr/bin/env python3
"""Generate the provisioning swimlane as a draw.io file.

Written as a generator rather than hand-authored XML so lane heights, step widths
and edge attachment points stay consistent when a step is inserted later.
"""
import pathlib
import xml.etree.ElementTree as ET

LANE_TITLE_W = 190
STEP_W, STEP_H = 200, 60
GAP_X = 60
COL0 = LANE_TITLE_W + 40
LANE_H = 120

LANES = [
    ("bu",    "BU App Owner",              "#dae8fc", "#6c8ebf"),
    ("gh",    "GitHub — issue & PR",       "#e1d5e7", "#9673a6"),
    ("auto",  "stack-forge (Actions)",     "#d5e8d4", "#82b366"),
    ("cops",  "Platform Operations (infra lane)",     "#ffe6cc", "#d79b00"),
    ("security-assurance",   "Security Assurance (security lane)",       "#f8cecc", "#b85450"),
    ("tfc",   "Terraform Cloud Stacks",    "#fff2cc", "#d6b656"),
    ("ali",   "AliCloud",                  "#f5f5f5", "#666666"),
]

# (id, lane, column, label, shape)
STEPS = [
    ("s1",  "bu",   0, "Raise issue from\nprovisioning template\n(manifest + access YAML)", "proc"),
    ("s2",  "gh",   1, "Issue labelled\nprovision-request", "proc"),
    ("s3",  "auto", 2, "01-intake\nparse issue into\ntwo lane manifests", "proc"),
    ("s4",  "auto", 3, "Validate claims against\npublished JSON Schemas", "dec"),
    ("s5",  "auto", 4, "Reject: comment on issue,\nno PR raised", "err"),
    ("s6",  "auto", 5, "Render both lanes\nfrom Jinja templates", "proc"),
    ("s7",  "gh",   6, "PR opened by\nGitHub App\n(not a human token)", "proc"),
    ("s8",  "auto", 7, "02-validate-pr\nre-render, fail on drift", "dec"),
    ("s9",  "cops", 8, "Approve infra/\n(CODEOWNERS)", "proc"),
    ("s10", "security-assurance",  8, "Approve security/\n(CODEOWNERS)", "proc"),
    ("s11", "gh",   9, "Squash merge to main", "proc"),
    ("s12", "auto", 10, "03-provision\nensure_stacks.py", "proc"),
    ("s13", "tfc",  11, "<app>-infra stack\ncreated, config fetched", "proc"),
    ("s14", "tfc",  12, "Infra plan\n(assumes infra RAM role)", "proc"),
    ("s15", "ali",  12, "STS AssumeRole\nvia OIDC / AKSK", "ext"),
    ("s16", "cops", 13, "Approve infra apply", "proc"),
    ("s17", "tfc",  14, "Apply publishes\noutputs", "proc"),
    ("s18", "tfc",  15, "<app>-security stack\nupstream_input resolves", "proc"),
    ("s19", "security-assurance",  16, "Approve security apply", "proc"),
    ("s20", "tfc",  17, "RAM roles and policies\nbound to RRSA", "proc"),
]

EDGES = [
    ("s1", "s2", ""), ("s2", "s3", ""), ("s3", "s4", ""),
    ("s4", "s5", "invalid"), ("s4", "s6", "valid"),
    ("s6", "s7", ""), ("s7", "s8", ""),
    ("s8", "s9", "green"), ("s8", "s10", "green"),
    ("s9", "s11", ""), ("s10", "s11", ""),
    ("s11", "s12", ""), ("s12", "s13", ""), ("s13", "s14", ""),
    ("s14", "s15", "credential"),
    ("s14", "s16", ""), ("s16", "s17", ""), ("s17", "s18", "publish_output"),
    ("s18", "s19", ""), ("s19", "s20", ""),
]

STYLES = {
    "proc": "rounded=1;whiteSpace=wrap;html=1;fillColor=#ffffff;strokeColor=#333333;",
    "dec":  "rhombus;whiteSpace=wrap;html=1;fillColor=#ffffff;strokeColor=#333333;",
    "err":  "rounded=1;whiteSpace=wrap;html=1;fillColor=#f8cecc;strokeColor=#b85450;dashed=1;",
    "ext":  "shape=cylinder3;whiteSpace=wrap;html=1;boundedLbl=1;fillColor=#f5f5f5;strokeColor=#666666;",
}

lane_index = {lid: i for i, (lid, *_rest) in enumerate(LANES)}
max_col = max(c for _, _, c, _, _ in STEPS)
pool_w = COL0 + (max_col + 1) * (STEP_W + GAP_X)
pool_h = len(LANES) * LANE_H


def cell(_parent, **attrs):
    return ET.SubElement(_parent, "mxCell", {k: str(v) for k, v in attrs.items()})


def geom(_parent, **attrs):
    a = {k: str(v) for k, v in attrs.items()}
    a["as"] = "geometry"
    ET.SubElement(_parent, "mxGeometry", a)


root_model = ET.Element("mxGraphModel", {
    "dx": "1400", "dy": "800", "grid": "0", "gridSize": "10", "guides": "1",
    "tooltips": "1", "connect": "1", "arrows": "1", "fold": "1", "page": "1",
    "pageScale": "1", "pageWidth": "1169", "pageHeight": "826", "math": "0", "shadow": "0",
})
root = ET.SubElement(root_model, "root")
cell(root, id="0")
cell(root, id="1", parent="0")

pool = cell(root, id="pool", value="Schema-driven AliCloud provisioning — issue to governed apply",
            style=("swimlane;html=1;childLayout=stackLayout;resizeParent=0;resizeParentMax=0;"
                   "horizontal=1;startSize=30;horizontalStack=0;fontSize=16;fontStyle=1;"
                   "fillColor=#ffffff;strokeColor=#333333;"),
            vertex="1", parent="1")
geom(pool, x=20, y=20, width=pool_w, height=pool_h + 30)

for i, (lid, title, fill, stroke) in enumerate(LANES):
    lane = cell(root, id=f"lane_{lid}", value=title,
                style=(f"swimlane;html=1;startSize={LANE_TITLE_W};horizontal=0;"
                       f"fillColor={fill};strokeColor={stroke};fontSize=13;fontStyle=1;"),
                vertex="1", parent="pool")
    geom(lane, x=0, y=30 + i * LANE_H, width=pool_w, height=LANE_H)

for sid, lid, col, label, shape in STEPS:
    node = cell(root, id=sid, value=label, style=STYLES[shape] + "fontSize=11;", vertex="1",
                parent=f"lane_{lid}")
    geom(node, x=COL0 + col * (STEP_W + GAP_X), y=(LANE_H - STEP_H) // 2,
         width=STEP_W, height=STEP_H)

for src, dst, label in EDGES:
    style = ("edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;exitX=1;exitY=0.5;"
             "entryX=0;entryY=0.5;fontSize=10;")
    if label in ("invalid",):
        style += "strokeColor=#b85450;dashed=1;"
    elif label == "credential":
        style += "strokeColor=#666666;dashed=1;"
    e = cell(root, id=f"e_{src}_{dst}", value=label, style=style, edge="1",
             parent="pool", source=src, target=dst)
    geom(e, relative="1")

# Literal markup here: ElementTree escapes it on write, which is exactly the form
# draw.io expects in a value attribute when html=1.
note = cell(root, id="note", value=(
    "<b>Gates, in order:</b> schema validation \u2022 drift check \u2022 "
    "two CODEOWNERS approvals \u2022 infra plan approval \u2022 security plan approval.<br>"
    "<b>Hard dependency:</b> the security stack cannot plan until the infra stack has "
    "applied and published its outputs, and both stacks must live in the same TFC project."),
    style="text;html=1;whiteSpace=wrap;fontSize=12;align=left;verticalAlign=top;",
    vertex="1", parent="1")
geom(note, x=20, y=pool_h + 70, width=pool_w, height=60)

diagram = ET.Element("mxfile", {"host": "app.diagrams.net", "type": "device"})
d = ET.SubElement(diagram, "diagram", {"name": "Provisioning workflow", "id": "provisioning"})
d.append(root_model)

out = pathlib.Path(__file__).resolve().parent / "provisioning-swimlane.drawio"
out.parent.mkdir(parents=True, exist_ok=True)
ET.indent(diagram, space="  ")
out.write_bytes(ET.tostring(diagram, encoding="utf-8", xml_declaration=True))
print(f"wrote {out} ({out.stat().st_size} bytes, {len(STEPS)} steps, {len(EDGES)} edges)")
