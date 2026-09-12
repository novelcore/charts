#!/usr/bin/env python3
"""Every workflow that borrows a template must declare the parameters that template reads.

Argo's `templateRef` borrows a template's BODY but not its parameter declarations, and
`{{workflow.parameters.X}}` always resolves against the SUBMITTED workflow. So a template
that reads workflow-level parameters imposes a contract on every workflow that borrows it,
and nothing in Argo or Helm checks that contract — it fails at submission, in production,
with a message that names the borrowed template rather than the borrower.

That is exactly how ci-rc-build shipped broken: its exit handler borrows ml-ci-build's
`report`, which reads `event_type`, which ci-rc-build did not declare. Every RC build on
every pool was rejected before a single pod ran, and because no pod ran, nothing ever posted
the kubecore-ci/rc commit status — so the failure looked like a hanging build rather than a
rejected one.

This turns that into a failed PR check. Run from the repo root.
"""
from __future__ import annotations

import pathlib
import re
import sys

TEMPLATES = pathlib.Path("charts/custom/kubecore-ci-workflows/templates")

# `{{`{{workflow.parameters.x}}`}}` in the Helm source; the backticks are Helm escaping.
WORKFLOW_PARAM = re.compile(r"\{\{`\{\{workflow\.parameters\.([a-zA-Z_][a-zA-Z0-9_]*)\}\}`\}\}")
TEMPLATE_HEAD = re.compile(r"^  - name: (\S+)\s*$")
DECLARED = re.compile(r"^\s*-\s*name:\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*$", re.M)


def templates_in(text: str) -> dict[str, str]:
    """Map each top-level template name to its body."""
    lines = text.split("\n")
    heads = [(i, m.group(1)) for i, line in enumerate(lines)
             if (m := TEMPLATE_HEAD.match(line))]
    bodies = {}
    for idx, (start, name) in enumerate(heads):
        end = heads[idx + 1][0] if idx + 1 < len(heads) else len(lines)
        bodies[name] = "\n".join(lines[start:end])
    return bodies


def declared_workflow_params(text: str) -> set[str]:
    """The workflow-level `arguments.parameters` of a chart file's own template."""
    head = text.split("\n  templates:")[0]
    return set(DECLARED.findall(head))


WORKFLOW_NAME = re.compile(r"^metadata:\s*\n(?:\s+\S.*\n)*?\s+name:\s*(\S+)\s*$", re.M)


def workflow_name(text: str) -> str:
    """The metadata.name of the (Cluster)WorkflowTemplate this file defines."""
    m = WORKFLOW_NAME.search(text)
    return m.group(1) if m else ""


def main() -> int:
    if not TEMPLATES.is_dir():
        print(f"{TEMPLATES} not found — run from the repo root", file=sys.stderr)
        return 2

    files = sorted(TEMPLATES.glob("*.yaml"))
    # Resolve a templateRef by the TARGET WORKFLOW's name, never by template name alone:
    # `build-push` is defined in three files, so matching on the template name would union
    # unrelated reads and invent failures that do not exist.
    by_workflow: dict[str, dict[str, set[str]]] = {}
    for path in files:
        text = path.read_text()
        name = workflow_name(text)
        if not name or "{{" in name:      # helper/templated names own no workflow templates
            continue
        by_workflow[name] = {
            tpl: set(WORKFLOW_PARAM.findall(body))
            for tpl, body in templates_in(text).items()
        }

    failures = []
    for path in files:
        text = path.read_text()
        declares = declared_workflow_params(text)
        # every `templateRef: {name: X, template: Y}` in this file
        for ref in re.finditer(
                r"templateRef:\s*\n\s*name:\s*(\S+)\s*\n\s*template:\s*(\S+)", text):
            target_wf, target_tpl = ref.group(1), ref.group(2)
            needed = (by_workflow.get(target_wf) or {}).get(target_tpl)
            if needed is None:
                continue                   # not a template this chart defines
            missing = sorted(needed - declares)
            if missing:
                failures.append(
                    f"  {path.name}: borrows {target_wf}/{target_tpl}, which reads "
                    f"workflow parameters it does not declare: {', '.join(missing)}")

    if failures:
        print("Borrowed-template parameter contract violated.\n", file=sys.stderr)
        print("\n".join(sorted(set(failures))), file=sys.stderr)
        print("\nA templateRef borrows the body, not the parameter declarations. Declare the "
              "missing parameters on the borrowing workflow (a default is fine when the value "
              "is unused on that path), or the workflow is rejected at submission.",
              file=sys.stderr)
        return 1

    borrowers = sum(len(t) for t in by_workflow.values())
    print(f"borrowed-template parameter contract OK "
          f"({len(by_workflow)} workflow template(s), {borrowers} template(s) checked)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
