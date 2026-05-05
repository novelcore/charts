# Chart-CVE multi-agent system

Four specialized agents plus one orchestrator that scan every Helm chart in this
repo for CVEs, file GitHub issues per finding, post upgrade-risk analysis, and
(only on explicit user invocation) perform the bump and open a PR.

## Pipeline

```
chart-cve-scanner       (read-only)   →  study/chart-cve-runs/<run-id>/chart-cve-report.{json,md}
        ↓
                       APPROVAL GATE  (orchestrator-managed)
        ↓
chart-cve-issue-filer   (gh issue create)        →  one issue per (chart, target)
        ↓
chart-upgrade-advisor   (gh issue comment)       →  one comment per issue, label flips needs-advisor → ready-to-bump
        ↓
                  ───── USER DECISION ─────
        ↓
chart-upgrade-executor  (USER-FIRED ONLY: edits + PR)  →  one branch + PR per issue
```

## Agents

| Agent | Trigger | Mutates | Output |
|---|---|---|---|
| `chart-cve-scanner` | orchestrator or user | nothing (read-only) | report files under `study/chart-cve-runs/<run-id>/` |
| `chart-cve-issue-filer` | orchestrator or user | GitHub issues on `novelcore/charts` | one issue per (chart, target) group |
| `chart-upgrade-advisor` | orchestrator or user | one comment per issue + label swap | structured advisor comment with bump procedure |
| `chart-upgrade-executor` | **user only** — never auto-fired | working tree, branch, PR, issue comment | bump PR closing the issue on merge |
| `chart-cve-orchestrator` | user | dispatches the first three | end-to-end run with approval gate |

## How to use

### Full pipeline (scan + file + advise)

Tell the parent Claude session:

> Run the chart-CVE pipeline.

The orchestrator runs the scanner, prints the topline + top criticals, and **waits for your explicit approval** before any GitHub mutation. Reply `approved` to continue, `abort` to stop.

After the advisor phase finishes, the orchestrator hands control back to you with a
suggested order for executing bumps. The orchestrator never fires the executor.

### Just scan

> Run the chart-cve scanner.

Or via the orchestrator with `--scan-only`.

### Scan + file, no advisor

Pass `--skip-advisor` to the orchestrator (or reply `approved no advisor` at the gate).

### Bump a single issue (executor)

After reviewing an advisor comment on a `ready-to-bump` issue:

> Execute the bump for #1234.

The executor will:

1. Verify preconditions (issue open, labeled `chart-cve` + `ready-to-bump`, advisor comment present, working tree clean, `main` up-to-date).
2. Count comments on the issue (one of the hard preconditions: exactly one advisor comment must be present).
3. Create branch `chart-cve/bump-<chart>-<new>-issue-<N>`.
4. Apply the advisor's documented bump procedure exactly — no other edits.
5. Run `./scripts/validate-charts.sh`, `helm template`, `helm lint`.
6. Open a PR titled `chore(chart-cve): bump <chart> <old> → <new>` with `Closes #<N>`.
7. Post a follow-up `Executor Update` comment on the issue with comment counts and validation status.

Add `--mode dry-run` to inspect the diff before pushing.

## Label set

The filer bootstraps these on first run via `gh label create --force`:

- `chart-cve` — every issue from the pipeline
- `severity/{critical,high,medium,low}`
- `track/{custom,external}`
- `target/{image,chart-config}`
- `needs-advisor` — set by filer; cleared by advisor
- `ready-to-bump` — set by advisor on success
- `advisor-blocked` — set by advisor when upstream docs unreachable
- `executor-blocked` — set by executor when validation fails
- `executor-shipped` — set by executor when PR opens

## Repo conventions this system honors

- Charts are split into `charts/custom/` (in-repo) and `charts/external/` (synced from upstream via `scripts/synch-config.yaml`).
- External charts are bumped by editing `synch-config.yaml` and running `./scripts/sync-chart.sh`. The executor follows this convention; it does not hand-edit `charts/external/` content.
- Custom charts are bumped by editing `charts/custom/<chart>/Chart.yaml` directly.
- All chart changes go through PR review on `main`. The executor never pushes to `main`.

## Comment-counting contract

Every issue's full lifecycle has a predictable comment count:

- After filer: 0 comments
- After advisor: 1 comment (the advisor's structured analysis)
- After executor: 2 comments (advisor + executor's `Executor Update`)
- The executor's hard preconditions include a count check: exactly one advisor-signed comment must exist before it will run.

## Output artifacts

```
study/chart-cve-runs/cve-<UTC-timestamp>/
├── inventory.json                # every chart + every rendered image
├── chart-cve-report.json         # machine-readable findings
├── chart-cve-report.md           # human summary
└── raw/
    ├── <chart>-config.json       # one per chart (trivy config)
    └── images/
        └── <sanitized-ref>.json  # one per unique rendered image
```

## What this system does NOT do

- Does not scan or comment on charts that fail to render with default values (those land in `skipped[]`).
- Does not auto-merge or auto-close anything.
- Does not bypass branch protection on `main`.
- Does not push to upstream chart repos.
- Does not assume severity — every severity is the scanner's verbatim output.
