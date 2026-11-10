# kubecore-ci-workflows

ClusterWorkflowTemplates for the platform CI: `ml-ci-build`, `ml-ci-reconcile`, the service-app templates and the cluster janitors.

## ci-sync: waiting for a build is not a failure

`ml-ci-reconcile` is the level-triggered CI backstop. The k8smlapp composition fires it with `force=true` as `{app}-ci-sync-{hash}` at app creation and on every platform-context change; the hourly CronWorkflow runs it with `force=false`. Its `check-drift` step decides whether a build is needed by comparing the app's HEAD and render inputs with what the last build recorded in `{app}-pipeline-images`. That record is only final once a running build has finished.

**Mechanism.** The run has two steps. `await-inputs` (force and dataset-event runs only, no lock) retries the inputs that are not builds. `decide` is a steps template (`decide-and-submit`) holding the same Argo mutex as every `ml-ci-build`, `{app}-build`, around `check-drift` and `submit-build`. While a build runs, `decide` is simply Pending (`Waiting for <ns>/Mutex/<app>-build lock`): no pod, no retry node, no failed node, no `cannot save parameter` error. When the build ends, Argo hands the lock over in queue order, `check-drift` decides once against the build's result, `submit-build` creates the build (which queues behind the lock) and the lock is released. Holding the lock across the submit is what makes two syncs submit one build: the second finds the first's queued build of HEAD.

| Property | How it holds |
|---|---|
| ordering kept | one mutex per app orders builds and syncs; a commit pushed during a build is a webhook build that queues behind it, and a sync that then finds HEAD unbuilt submits (or finds a queued build of HEAD and submits nothing) |
| no duplicate first build | after the wait the sync sees `last-built-sha == HEAD` with the current `context-sha` and `enhancer-ref`, so it submits nothing |
| restarts | the queue is in the Workflow status; a controller restart loses nothing; a build that dies releases the lock |
| bounded | `activeDeadlineSeconds` of the run (`ci.reconcileDeadlineSeconds`, default 10800) includes the wait; a build that never ends fails the waiting run with a deadline message and the hourly CronWorkflow re-detects the drift |
| no polling pod | nothing runs while it waits |
| outputs | `needs_build` and `head_sha` default to `false` and empty and are written before any decision |
| two syncs | the second finds the first one's queued build of HEAD, or the finished build, and submits nothing (tested on Argo) |
| first build not delayed | the input wait takes no lock, so a build is never held up by an app repo or ArgoCD sync that is still arriving |

**Still retried (`await-inputs`, exit 3, once a minute for ~45 min):** inputs that are not builds and genuinely arrive late in force mode: the app repo, `{app}-pipeline-images` (ArgoCD sync) and the gitops `pipeline-context.yaml` the trigger is for. Those attempts do show as failed `await-inputs(n)` nodes; a build in flight no longer does. Exit 137 (killed pod) is retried in every mode.

**Hourly poll (`force=false`):** unchanged semantics. It now waits for the lock instead of skipping when a build runs (bounded by the same deadline), and still skips when builds are merely queued (no stacking, kubecore-operator#872).

**Lock holders.** A build that hangs holds its app's lock until the build ends (existing behaviour, unchanged); the sync behind it fails at its deadline with `Step exceeded its deadline` on the `decide` node.

## pipeline-lint: the pipeline linter on every PR of a Hera ML app

`ml-ci-pr-render` runs the kaos-lib pipeline linter (PRD novelcore/kaos#1682, F-02) next to the `wft-render` check, for apps with a `pipeline.py`. It posts a **`pipeline-lint`** commit status on the PR head (errors fail it, warnings and infos never do) and **one PR comment**, found by its marker `<!-- kubecore-ci-report:pipeline-lint -->` and updated in place on every push. It is **advisory**: the chart does not add it to any ruleset (PRD OQ-12 decides that), and a linter that cannot run never turns `wft-render` red.

| Step | Trust | What it does |
|---|---|---|
| `pipeline-lint-prepare` | holds the GitHub token | posts `pending`; downloads the pinned kaos-lib wheel and checks its sha256; turns the gitops `pipeline-context.yaml` into a **catalogue** (the project's compute classes, HPC (Slurm) limits and the platform's record of which steps resumed from a checkpoint, as step names, verdicts and reasons only: no endpoint, no secret name, no job details) |
| `pipeline-lint-run` | **tokenless**, reads the checkout | unzips the wheel and lints `/workspace/repo` as data: the linter parses `pipeline.py`, `config/` and `steps/`, it never imports or runs them. Writes `report.json`, `report.md`, `status.txt` |
| `pipeline-lint-report` | holds the token | posts the final status (`success`, `failure`, or `error` when the check could not run) and the one comment |

**Dockerfile doctor.** Since rule set `1.2.0` (kaos-lib 0.4.0rc22) the same check also reads each step's `Dockerfile` (never builds or runs it) and reports the `L-D01` to `L-D08` findings: an error such as a `COPY` outside the build context or a missing `app/entry.py` turns `pipeline-lint` red, warnings and infos never do. A Dockerfile that does not use kaos-lib is not asked to declare `ARG KAOS_LIB_PACKAGE`.

**Pin.** `pipelineLint.kaosLibWheelUrl` and `pipelineLint.kaosLibWheelSha256` name one exact kaos-lib wheel from the platform's package index; it is downloaded, verified and unzipped, never `pip install`ed (the toolbox image has Python and PyYAML but not `requests` or `packaging`, so the wheel's `kaos_lib/lint/standalone.py` runs the linter without importing the rest of kaos-lib). `pipelineLint.rulesetVersion` is the rule set of that release: the run refuses a different one, so the gate and `kaosctl lint` of the same release give the same JSON. Bump the three values together with each kaos-lib release.

**Without a context.** If the gitops context cannot be read the linter runs with its built-in defaults and the report says so (`catalogue.source`); the check that needs the project's classes (`L-E03`) is then listed as skipped, never as passed.

```bash
bash charts/custom/kubecore-ci-workflows/tests/pipeline-lint/run.sh /tmp/rendered.yaml                        # stand-in wheel, no network
KAOS_LIB_WHEEL=/path/kaos_lib-X-py3-none-any.whl bash .../tests/pipeline-lint/run.sh /tmp/rendered.yaml       # the real linter
```

## Rendered WorkflowTemplate size

A Hera app's rendered WorkflowTemplate used to carry the 19 KB checkpoint helper twice per GPU step; five parallel GPU steps pushed it past the 256 KiB `kubectl.kubernetes.io/last-applied-configuration` limit and Argo CD stopped applying it. Now:

- The helper source ships once per app as the ConfigMap `{app}-ckpt-helper` (`ckpt-helper.yaml`, committed beside `workflow-template.yaml`); steps mount it read-only.
- `wftSize.limitKiB` (900) is enforced by `hera-enhance-commit` and the PR gate `hera-enhance-gate`; the size is recorded as `wft-bytes` in `{app}-pipeline-images`.
- The ml ApplicationSet created by the kubecore-operator syncs with `ServerSideApply=true`.

```bash
bash charts/custom/kubecore-ci-workflows/tests/wft-size/run.sh /tmp/rendered.yaml
```

## Tests

```bash
helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
bash charts/custom/kubecore-ci-workflows/tests/sync-wait/run.sh                  # render guards
bash charts/custom/kubecore-ci-workflows/tests/reconcile-trigger/run.sh          # check-drift script against stubs
bash charts/custom/kubecore-ci-workflows/tests/sync-wait/kind/run.sh [outdir]    # real Argo v4.0.6 in kind (needs docker, kind)
```
