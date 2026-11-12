# kubecore-ci-workflows

ClusterWorkflowTemplates for the platform CI: `ml-ci-build`, `ml-ci-reconcile`, the service-app templates and the cluster janitors.

## ci-sync: waiting for a build is not a failure

`ml-ci-reconcile` is the level-triggered CI backstop. The k8smlapp composition fires it with `force=true` as `{app}-ci-sync-{hash}` at app creation and on every platform-context change; the hourly CronWorkflow runs it with `force=false`. Its `check-drift` step decides whether a build is needed by comparing the app's HEAD and render inputs with what the last build recorded in `{app}-pipeline-images`. That record is only final once a running build has finished.

**Mechanism.** The run has two steps. `await-inputs` (force and dataset-event runs only, no lock) retries the inputs that are not builds. `decide` is a steps template (`decide-and-submit`) holding the same Argo mutex as every `ml-ci-build`, `{app}-build`, around `check-drift` and `submit-build`. While a build runs, `decide` is simply Pending (`Waiting for <ns>/Mutex/<app>-build lock`): no pod, no retry node, no failed node, no `cannot save parameter` error. When the build ends, Argo hands the lock over in queue order, `check-drift` decides once against the build's result, `submit-build` creates the build (which queues behind the lock) and the lock is released. Holding the lock across the submit is what makes two syncs submit one build: the second finds the first's queued build of HEAD.

| Property | How it holds |
|---|---|
| ordering kept | one mutex per app orders builds and syncs; a commit pushed during a build is a webhook build that queues behind it, and a sync that then finds HEAD unbuilt submits (or finds a queued build of HEAD and submits nothing) |
| no duplicate first build | after the wait the sync sees `last-built-sha == HEAD` with the current `context-sha` and the context's engine (`engine-version`, `engine-compose`), so it submits nothing |
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

**Dockerfile doctor.** Since rule set `1.2.0` (kaos-lib 0.4.0rc22) the same check also reads each step's `Dockerfile` (never builds or runs it) and reports the `L-D01` to `L-D08` findings: an error such as a `COPY` outside the build context or a missing `app/entry.py` turns `pipeline-lint` red, warnings and infos never do. A Dockerfile that does not use kaos-lib is not asked to declare `ARG KAOS_LIB_PACKAGE`. Since rule set `1.3.0` (kaos-lib 0.4.0rc25) `L-D08` also warns, never errors, when a `gpu=True` step's plain (non-CUDA) base image sets no NVIDIA driver path.

**GPU driver prelude.** The enhancer of the platform engine (hera-pipeline-template#100, chart 0.12.151) wraps the command of every `gpu=True` step that runs on a KAOS GPU node in a `sh -c` prelude: the NVIDIA driver folders (`/usr/local/nvidia/lib64`, `/usr/local/nvidia/lib`, `/usr/local/nvidia/bin`) are prepended to the image's own `LD_LIBRARY_PATH` and `PATH`, a ctypes `cuInit` check fails the step in its first second with a `KAOS: this GPU step cannot reach the NVIDIA driver (...)` line, and `exec "$@"` runs the original command. HPC (Slurm) steps are never wrapped; a step given 0 GPUs (cpu class) skips the check.

**Pin.** `pipelineLint.kaosLibWheelUrl` and `pipelineLint.kaosLibWheelSha256` name one exact kaos-lib wheel from the platform's package index; it is downloaded, verified and unzipped, never `pip install`ed (the toolbox image has Python and PyYAML but not `requests` or `packaging`, so the wheel's `kaos_lib/lint/standalone.py` runs the linter without importing the rest of kaos-lib). `pipelineLint.rulesetVersion` is the rule set of that release: the run refuses a different one, so the gate and `kaosctl lint` of the same release give the same JSON. Bump the three values together with each kaos-lib release.

**Without a context.** If the gitops context cannot be read the linter runs with its built-in defaults and the report says so (`catalogue.source`); the check that needs the project's classes (`L-E03`) is then listed as skipped, never as passed.

```bash
bash charts/custom/kubecore-ci-workflows/tests/pipeline-lint/run.sh /tmp/rendered.yaml                        # stand-in wheel, no network
KAOS_LIB_WHEEL=/path/kaos_lib-X-py3-none-any.whl bash .../tests/pipeline-lint/run.sh /tmp/rendered.yaml       # the real linter
```

## Rendered WorkflowTemplate size

A Hera app's rendered WorkflowTemplate used to carry the 19 KB checkpoint helper twice per GPU step; five parallel GPU steps pushed it past the 256 KiB `kubectl.kubernetes.io/last-applied-configuration` limit and Argo CD stopped applying it. Now:

- The helper source ships once per app as the ConfigMap `{app}-ckpt-helper` (`ckpt-helper.yaml`, committed beside `workflow-template.yaml`); steps mount it read-only. The file is only staged when the enhancer wrote it or it is already tracked, so an app with no checkpointed step builds without it.
- `wftSize.limitKiB` (900) is enforced by `hera-enhance-commit` and the PR gate `hera-enhance-gate`; the size is recorded as `wft-bytes` in `{app}-pipeline-images`.
- The ml ApplicationSet created by the kubecore-operator syncs with `ServerSideApply=true`.

```bash
bash charts/custom/kubecore-ci-workflows/tests/wft-size/run.sh /tmp/rendered.yaml
```

## ML build pacing and on-demand kaos-lib rebuilds

Why: on the HPC lab (2026-11-10) a kaos-lib pin move made every app rebuild every step at once; eight 3 CPU / 11Gi kaniko pods sat Pending behind a one-node CI pool and render-only runs queued behind them for about an hour.

**Cap on concurrent image builds.** `build-push` carries an Argo semaphore (`ci.buildSlots`, off by default) read from the ConfigMap `ci-build-slots`, key `slots`, in the workflow's own namespace (the project's `-ci`). The githubproject composition writes it as `max(1, ciPoolMaxNodes - 1)`, so one pool node always stays free for render pods. A template-level semaphore holds the node in Argo until a slot frees: no Pending pod, so no pending-reaper kill and no scale-up demand past the pool. It counts every app and run of the project.

**A render-only run holds no lock.** `ml-ci-build` probes (clone, detect-steps) with no lock. Steps to build: `ml-ci-run-locked` takes the per-app mutex `{app}-build` and runs `ml-ci-run`. Nothing to build: `ml-ci-run` runs without any lock, never builds or tags, and records `last-built-sha` only when it built nothing. `ml-ci-run` clones and detects again under the lock, so what a build records is what it was before (the previous build's last-built-sha and tags are committed first). ml-ci-reconcile treats a Running build with a node Pending on a lock as queued.

**On-demand kaos-lib rebuild, background trickle.** A pin move makes apps stale; it does not rebuild them. A push rebuilds a stale app (detect-steps, as ever). A reconcile-submitted build (re-render, dataset, context) leaves stale images alone and keeps recording the spec they have. The hourly poll rebuilds a stale app only by its use, read from its pipeline runs in the ML namespace: ran within `ci.kaosLibRebuild.hotSeconds` (24h) - rebuilt now; within `idleSeconds` (30d) - rebuilt in the background, one kaos-lib rebuild at a time per project; idle, never run or unreadable - only when used. The run that triggered it used the old images (compatible within a minor, which the operator enforces) and the next run gets the new ones. Stale is `pipeline-images.kaos-lib-package != pipeline-context kaosLib.spec`; no extra key is written (it would be a gitops commit per app at the pin move).

**Checkout reads (0.13.5).** `detect-steps` holds the git token, and `files/kaos-lib.py decide` reads two kinds of app file there: `.kaos/compat.yaml` and each step's `Dockerfile`. Both are read as bounded data, by the same rule as `engine.py`. A missing file keeps its meaning: no `compat.yaml` means no range, and a step without a `Dockerfile` is not managed. A file that is there but is a symlink, not a regular file, resolves outside the checkout, is over 64 KiB or is not UTF-8 is refused (exit 5, the reason in the log). So is a `compat.yaml` whose `kaos-lib` value is not a string or a number (a list, a mapping, a bool, a date): such a value is never turned into text, so an alias bomb is not expanded. detect-steps then takes its existing failure path: kaos-lib is left as it is, so no build-arg is passed and no record is written. Before 0.13.5 these reads followed symlinks with no bound, so a symlink to `/dev/zero` hung the step or OOM-killed it (kubecore-operator#1833). The chart's own compose Dockerfile (an absolute path under `/tmp`) is exempt only from the inside-the-checkout check.

Tests: `tests/build-pacing/run.sh` (render guards), `tests/build-pacing/kind/run.sh` (real Argo: cap, render-only, mutex), `tests/kaos-lib/run.sh` (detect gate, trickle classes).

## Platform pipeline engine (PRD-HPC-1461 D-80, chart 0.13.0, BREAKING)

The platform pipeline engine is the ONLY way this chart renders, enhances and composes an ML app. There is no legacy mode, no shadow mode, no kubeline DSL and no `platformEnhancer.ref`. An app is `pipeline.py`, `config/` and `steps/<name>/`; it carries no `kubecore/` and no `steps/compose_and_validate/`. The operator writes `engine: {version, image, wheel, wheelSha256}` into the app's gitops `pipeline-context.yaml` (a `mode` key is ignored); a context without a usable engine FAILS the build and the live WorkflowTemplate stays as it is.

| | what runs |
|---|---|
| render (`hera-render`, tokenless) | the context's engine image, `python -I -m kaos_engine.render pipeline.py --repo ... --profile <p>`. No `pip install -e .`: only the app pyproject dependencies the engine lacks are installed, under the engine's own versions as constraints. Profile (0.13.3): the schema of the app's vendored `kubecore/derive_tree.py`, parsed and never imported (`DataConfig.ref` + `.version` = `legacy-v1`, `ref` = `hera`, no `ref` = `yolo-v1` with `QuantizationConfig.output_prefix`, else `yolo`). A `derive_tree.py` (or `config/data.yaml`) that is a symlink, not a regular file, over 64 KiB or not parseable fails the build (exit 5, the reason in the log): it is never guessed around. Without that file: `yolo` when `config/` has a `quantization` section (`config/quantization.yaml` or `config/quantization/`) and `config/data.yaml` sets no `data.ref`, else `hera`. Before 0.13.3 only the fallback existed, and every yolo app of the template's `main` failed to render (kubecore-operator#1830). |
| enhance (`hera-enhance-commit`, `hera-enhance-gate`) | the engine wheel: download, sha256 check against `engine.wheelSha256`, unzip, no pip. A wheel that does not download or whose sha256 differs fails the step. The WorkflowTemplate is stamped with the engine version (annotation `platform.kubecore.io/engine-version`, label `platform.kubecore.io/engine` on its Workflows). |
| compose-and-validate image | built by CI from the chart's `files/compose.Dockerfile`, never from the app: `FROM` the engine image, `kaos-lib` from the same `KAOS_LIB_PACKAGE` build-arg the step images get (`--no-deps`, under constraints frozen from the engine image: it ships no constraints file), `KUBECORE_SCHEMA_PROFILE` / `KUBECORE_CONFIG_DIR=/work/config`, `COPY . /work/config/` with the app's `config/` as the ONLY build context, label `io.kaos.engine`. The rendered WorkflowTemplate carries the command (`python -I -m kaos_engine.compose`). |

The compose image is rebuilt when `config/` changed, when `engine-compose` in `{app}-pipeline-images` is not the context's `engine.version`, or when the kaos-lib package moved (its Dockerfile counts as one more step that declares the ARG).

`{app}-pipeline-images` records `engine-version` (the render), `engine-compose` (the compose image), and, after a failed run, `engine-last-error` and `engine-attempt` (`<engine version>@<epoch>`; `<engine version>@<epoch>@<commit>@<kaos-lib>` for an app refused as an old app, see below). The exit handler's `engine-record` step writes them to the gitops file (one line, at most 200 characters, from the failed pod's log: engine check (`probe-detect` or `detect-steps`), render, enhance or the compose image build). It clears them only after a run that Succeeded and rendered, enhanced or built the compose image; a run that failed outside the engine stages, or ran no engine stage, leaves them as they are. Only the last attempt of each engine step counts: these steps retry a lost pod, so Argo names each attempt's pod `<node>(N)`, and an attempt that was preempted and retried to success is not an error. Before 0.13.4 the record matched no retried pod, so a failed render or enhance recorded nothing and a successful run that only rendered cleared nothing (kubecore-operator#1832). The operator reads `engine-last-error` to show state `failed`.

**ENGINE DRIFT** (`ml-ci-reconcile`): a render or compose image whose recorded engine is not the context's `engine.version` submits one build. It re-renders and rebuilds the compose image only: `detect-steps` rebuilds no other image (except across kaos-lib 0.5, see "The step contract"). The records are read from gitops, so a render already pushed is not submitted again while ArgoCD has not synced it. **One attempt per hour:** while `engine-attempt` names the context's engine version and is younger than an hour, the poll submits nothing (a broken engine release does not loop builds; a new engine version has another name and is tried at once). A failed render never replaces the live WorkflowTemplate and builds no image: `hera-enhance-commit` only starts after `hera-render` succeeded and writes the file only after the enhance, the step table check, the gate and the size guard, and `build-push` is the step group after the render.

The PR check (`ml-ci-pr-render`) renders with the same template and the same engine. The step-folder gate does not look for a `compose-and-validate` folder.

```bash
python -m pytest charts/custom/kubecore-ci-workflows/tests/engine                      # files/engine.py
bash charts/custom/kubecore-ci-workflows/tests/engine-ci/run.sh /tmp/rendered.yaml     # render, detect-steps, compose Dockerfile, engine-record, executed
bash charts/custom/kubecore-ci-workflows/tests/engine-drift/run.sh /tmp/rendered.yaml  # ENGINE DRIFT and the hourly guard
```

The engine's `enhance.py` must understand every flag this chart passes (`--helper-configmap` since 0.12.149).

## The step contract (PRD novelcore/kaos#1911, chart 0.14.0, BREAKING)

This chart renders, builds and reports apps on the step contract only: `pipeline.py` declares `kind=`, `inputs=` and `produces=` (no `outputs=`, no `hpc_time_limit=`), a step runs with no arguments and reads one context, and kaos-lib is 0.5 or newer. There is no second path for older apps. It needs a pipeline engine on the step contract (kaos-hpc-operator `engine/`, the release that writes the step table) and a kaos-lib 0.5 delivered by the platform; with an older engine every render fails closed ("the rendered pipeline carries no step table").

**An app is never left half-moved (AC-01, T-05).** An app that has not moved fails before anything is recorded, and the pipeline it had keeps running:

| What is old | Where it fails | With |
|---|---|---|
| `pipeline.py`: a step without `kind=`, `outputs=`, `hpc_time_limit=` (every app from before the contract has at least the first) | `hera-render`, the engine's own refusal | the engine's message, which names the step and what to write |
| kaos-lib: the platform holds the app at a kaos-lib older than 0.5 because its `.kaos/compat.yaml` does not accept 0.5 (or declares nothing while an older one is delivered) | `detect-steps` (`kaos-lib.py contract`), before the render | what to write in `.kaos/compat.yaml` and the guide |
| the engine: the context pins an engine from before the contract | the enhance steps (`engine.py steps`, exit 5) | "not on the step contract" (a platform fault, reported as an engine error) |

In all three nothing is committed to gitops (no WorkflowTemplate, no `engine-version`, no `last-built-sha`, no image key) and no image is built: the render is a step group of its own **before** `build-push` (until 0.13 they shared a group, so a refused app had every step image built first). The one build let through with an older kaos-lib is the one whose commit already accepts 0.5: its record (`kaos-lib-compat`) is how the platform learns the new range and then delivers 0.5.

**What the app's engineer sees.** The step that refuses calls `not_migrated` (`_helpers.tpl`), which leaves `/workspace/not-migrated` (one line: what to change) and the "What to change" section of the report comment (`/workspace/report-extra.md`). The exit handler's `engine-record` then replaces the commit status `kubecore-ml-ci` with `Not built: this app must move to kaos-lib 0.5. Guide: <address>` (the check links the guide, `kaosLib.guideUrl` + `/migrate-to-0.5.html`) and records `engine-last-error` = `not migrated (<guide>): <what to change>`, which the operator shows on the app. The pull request check (`ml-ci-pr-render`, the same `hera-render`) posts the same description on `wft-render`. The kaos-lib check is not part of the pull request check: the pull request that changes the range is the one that must pass, and the platform only learns the new range from the build after its merge. None of these texts names the platform's internals.

How a refusal is told from any other failed render: the engine's migration messages end with its migration guide's address (`authoring-schema.json`, `migration_guide`); `hera-render` reads that address from the engine it runs and looks for it in the render's error. The message, without that address, is what the report shows; the address the engineer gets is the chart's (`kaosLib.guideUrl`).

**One attempt, no loop.** A refused build records `engine-attempt` as `<engine version>@<epoch>@<commit>@<kaos-lib>` (the kaos-lib is the first 12 hex of the sha256 of the spec the context delivered; `engine.py attempt` / `engine.py refused`). While HEAD is that commit and the gitops context still pins that engine and delivers that kaos-lib, `ml-ci-reconcile` submits nothing, in the hourly poll and in a forced run alike (NOT MIGRATED GUARD, ahead of COMMIT DRIFT): another build would read what the refused one read. A push to the app, a new engine or another kaos-lib is tried at once. Any other engine failure keeps the one-attempt-per-hour guard.

**kaos-lib across 0.5.** Images built with a kaos-lib from before the contract cannot run a pipeline of this engine, so a reconcile-submitted build does not leave them "stale, rebuilt on use" when the context delivers 0.5: it rebuilds them (after the render, which an app that has not moved fails first). The bump pull request (`files/kaos-lib.py bump`) whose range crosses 0.5 says that changing the range is not enough and links the guide; a new `.kaos/compat.yaml` points at the guide's `support-window.html`.

**The form.** Every name a step declares in `inputs=` is a form field that holds a dataset reference (`dataset-<name>@<version>`). `hera-enhance-commit` reads the names from the engine's step table (the compose step's `--steps` argument, `engine.py steps`) and gives each field the catalog's choices (`files/dataset-choices.py fill`); a field named `dataset` is no longer special. The default stays what the app's config says, `latest` included (it is resolved to a commit when the run starts); a default the catalog does not offer becomes the latest of the same dataset, or of the project's default dataset. `dataset-sha` is `none` when no step declares an input. The chart adds no form field and removes none, so it cannot collide with the keys the engine reserves (`plan`, `pipeline-version`).

**Not done here: refusing an ADVANCED override over about 60 KiB at submit.** The override is a workflow parameter the engine passes to the compose step as an argument; above that size the step cannot start. A check before it needs either an extra task in the pipeline's DAG with its own image, or an expression on the compose argument whose message compose prints: both are the engine's to write (it owns the DAG and compose), and a chart post-pass that rewrote the argument could only make compose fail with an unrelated parse error.

```bash
bash charts/custom/kubecore-ci-workflows/tests/step-contract/run.sh /tmp/rendered.yaml   # the wording, the PR check, where the step table is read
# with a real engine (a python that has the kaos-pipeline-engine wheel installed), and apps still on the old contract:
ENGINE_PYTHON=/path/venv/bin/python OLD_APPS="/path/app-a /path/app-b" bash .../tests/step-contract/run.sh /tmp/rendered.yaml
```

The fixtures of `tests/connections` are two chart-owned apps on the contract (`fixtures/apps/hera`, `fixtures/apps/yolo`) rendered by the engine pinned in `harness.py` (`ENGINE_REF`); `run.sh` there says how to regenerate them and the golden files after an engine change.

**Moving the pins (the cutover).** The chart, the operator's pin of it, the engine pin and the platform's kaos-lib value move together, in a freeze: kaos-lib 0.5 delivered first, then the operator release that pins this chart and the engine on the contract. `pipelineLint.*` must name a kaos-lib 0.5 wheel (rule set 2.0.0) from the same moment: the 0.4 linter reports the new keywords as errors.

## Tests

```bash
helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
bash charts/custom/kubecore-ci-workflows/tests/sync-wait/run.sh                  # render guards
bash charts/custom/kubecore-ci-workflows/tests/reconcile-trigger/run.sh          # check-drift script against stubs
bash charts/custom/kubecore-ci-workflows/tests/sync-wait/kind/run.sh [outdir]    # real Argo v4.0.6 in kind (needs docker, kind)
bash charts/custom/kubecore-ci-workflows/tests/build-pacing/run.sh               # pacing render guards
bash charts/custom/kubecore-ci-workflows/tests/build-pacing/kind/run.sh [outdir] # real Argo: cap, render-only, mutex
```
