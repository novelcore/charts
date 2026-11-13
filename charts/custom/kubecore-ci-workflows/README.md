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

**Pin follows the platform's library (0.15.2).** The gate's lint pin is separate from the library the operator delivers to builds (`KAOS_LIB_PACKAGE`), so the two drift when the platform moves to a new kaos-lib and this chart is not bumped: the gate then refuses valid new keywords (for example `L-E06 RefusedArgument: step() has no argument 'matrix'`). The pin is 0.5.0rc11 (rule set 2.5.0). Move `pipelineLint.*` in the same change that moves the platform's kaos-lib value; `tests/pipeline-lint` takes a real wheel (`KAOS_LIB_WHEEL`) to prove the pinned release accepts the current keywords.

**Without a context.** If the gitops context cannot be read the linter runs with its built-in defaults and the report says so (`catalogue.source`); the check that needs the project's classes (`L-E03`) is then listed as skipped, never as passed.

```bash
bash charts/custom/kubecore-ci-workflows/tests/pipeline-lint/run.sh /tmp/rendered.yaml                        # stand-in wheel, no network
KAOS_LIB_WHEEL=/path/kaos_lib-X-py3-none-any.whl bash .../tests/pipeline-lint/run.sh /tmp/rendered.yaml       # the real linter
```

## Rendered WorkflowTemplate size

A Hera app's rendered WorkflowTemplate used to carry the 19 KB checkpoint helper twice per GPU step; five parallel GPU steps pushed it past the 256 KiB `kubectl.kubernetes.io/last-applied-configuration` limit and Argo CD stopped applying it. Now:

- The helper source ships once per app as the ConfigMap `{app}-ckpt-helper` (`ckpt-helper.yaml`, committed beside `workflow-template.yaml`); steps mount it read-only. The file is only staged when the enhancer wrote it or it is already tracked, so an app with no checkpointed step builds without it.
- **The render's setup copy no longer fails on a cluster** (0.14.4): 0.14.2 made the render run without root, and its setup container then ended 1 setting the times of the volume's root directory, which belongs to root, so every pull-request render and merge build failed. It now copies the entries of the interpreter's tree, not the directory itself.
- **The image record is read in two shapes** (0.14.4), so the pins of the CI chart and the engine can move in any order: `hera-enhance-commit` collects the `{app}-pipeline-images` keys the rendered template reads from the workflow's own `arguments.parameters` (an engine that gives each step an `image-<step>` argument) and from the `inputs.parameters` of its templates (an engine that reads the record in compose's template, `image-<step>` inputs with the same `valueFrom.configMapKeyRef`, and has no image argument). The PR gate (`hera-enhance-gate`) finds a step's folder from `container.image` being `{{workflow.parameters.image-<step>}}` or the template's input `image` of a template named after the step; compose, the final task and the HPC follower have no step folder.
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

**An app's own kaos-lib pin rebuilds now (0.16.1, PRD novelcore/kaos#1911).** Setting, changing or (see below) removing `spec.ml.kaosLib` used to reach the images only at the next hourly poll, and only if the app had been used lately. The operator now marks a pin in the gitops context (`kaosLib.pinned: true`, written for `spec.ml.kaosLib` and nothing else). The context change already fires the forced `ml-ci-reconcile` (the `{app}-ci-sync-*` run); it now also compares the pin with the `kaos-lib-package` the **gitops** `pipeline-images.yaml` records (the live ConfigMap trails gitops by an ArgoCD sync, which would submit the rebuild twice) and, when they differ, submits the kaos-lib rebuild (`kaos_lib_rebuild=true`, labelled with the spec's ref) at once, whether the app ran lately or never (the client just changed it). A platform-wide move carries no mark and stays with the hourly poll's pacing above: no rebuild storm. Guards: unreadable or unrecorded gitops is unknown and submits nothing; `none` has nothing to rebuild; the OLD APP GUARD runs first; a finished attempt at the same spec within the hour (a pin that cannot install) holds the retry back, as in the poll; a queued push build of HEAD (it rebuilds a stale step itself) or a queued reconcile build for the same spec is not duplicated; the run waits on the app's `{app}-build` mutex like any trigger, so a build in progress and the hourly run cannot overlap. A rebuild cannot re-trigger itself: it writes `pipeline-images.yaml` and the render to gitops, never the `pipeline-context.yaml` the trigger is named after. Removing a pin moves the app back to the platform value without a mark, so it follows the paced path. Tests: `tests/kaos-lib` (pin cases), `tests/reconcile-trigger`.

**Checkout reads (0.13.5).** `detect-steps` holds the git token, and `files/kaos-lib.py decide` reads two kinds of app file there: `.kaos/compat.yaml` and each step's `Dockerfile`. Both are read as bounded data. A missing file keeps its meaning: no `compat.yaml` means no range, and a step without a `Dockerfile` is not managed. A file that is there but is a symlink, not a regular file, resolves outside the checkout, is over 64 KiB or is not UTF-8 is refused (exit 5, the reason in the log). So is a `compat.yaml` whose `kaos-lib` value is not a string or a number (a list, a mapping, a bool, a date): such a value is never turned into text, so an alias bomb is not expanded. detect-steps then takes its existing failure path: kaos-lib is left as it is, so no build-arg is passed and no record is written. Before 0.13.5 these reads followed symlinks with no bound, so a symlink to `/dev/zero` hung the step or OOM-killed it (kubecore-operator#1833). The chart's own compose Dockerfile (an absolute path under `/tmp`) is exempt only from the inside-the-checkout check.

**What counts as use (0.15.1).** `check-drift` decides an app is in use from its newest pipeline run, in either shape: a run with the label `workflows.argoproj.io/workflow-template={app}-pipeline` (submitted from the template through the Argo server) or a Workflow object whose `spec.workflowTemplateRef.name` is `{app}-pipeline` (what the platform console, the gateway and the e2e create, with no such label). Before 0.15.1 only the labelled shape counted, so an app run only through the platform was "never used", printed `KAOS-LIB STALE ... not rebuilt in the background` every hour and stayed `building` until an unrelated push. The labelled list is a server-side selector and is read first; the namespace's full list (it can hold thousands of finished runs) is read only when the labelled list did not already show a run inside `ci.kaosLibRebuild.hotSeconds`, because a newer unlabelled run cannot change a hot answer. No other decision in `ml-ci-reconcile`, `ml-ci-build` or `ml-ci-pr-render` reads that label.

Tests: `tests/build-pacing/run.sh` (render guards), `tests/build-pacing/kind/run.sh` (real Argo: cap, render-only, mutex), `tests/kaos-lib/run.sh` (detect gate, trickle classes, labelled and unlabelled runs).

## Platform pipeline engine (PRD-HPC-1461 D-80, chart 0.13.0, BREAKING)

The platform pipeline engine is the ONLY way this chart renders, enhances and composes an ML app. There is no legacy mode, no shadow mode, no kubeline DSL and no `platformEnhancer.ref`. An app is `pipeline.py`, `config/` and `steps/<name>/`; it carries no `kubecore/` and no `steps/compose_and_validate/`. The operator writes `engine: {version, image, wheel, wheelSha256}` into the app's gitops `pipeline-context.yaml` (a `mode` key is ignored); a context without a usable engine FAILS the build and the live WorkflowTemplate stays as it is.

| | what runs |
|---|---|
| render (`hera-render`, tokenless) | the context's engine image, `python -I -m kaos_engine.render pipeline.py --repo ... --profile <p>`. No `pip install -e .`: only the app pyproject dependencies the engine lacks are installed, under the engine's own versions as constraints. Profile: `yolo` when `config/` has a `quantization` section (`config/quantization.yaml` or `config/quantization/`), else `hera`; nothing else of the app is read to pick it. An app that carries a `kubecore/` folder of its own (a copy of an old engine) is not read either: the engine refuses it as an old app (see below), so it is told to create the app again and nothing is recorded. |
| enhance (`hera-enhance-commit`, `hera-enhance-gate`) | the engine wheel: download, sha256 check against `engine.wheelSha256`, unzip, no pip. A wheel that does not download or whose sha256 differs fails the step. The WorkflowTemplate is stamped with the engine version (annotation `platform.kubecore.io/engine-version`, label `platform.kubecore.io/engine` on its Workflows). |
| compose-and-validate image | built by CI from the chart's `files/compose.Dockerfile`, never from the app: `FROM` the engine image, `kaos-lib` from the same `KAOS_LIB_PACKAGE` build-arg the step images get (`--no-deps`, under constraints frozen from the engine image: it ships no constraints file), `KUBECORE_SCHEMA_PROFILE` / `KUBECORE_CONFIG_DIR=/work/config`, `COPY . /work/config/` with the app's `config/` as the ONLY build context, label `io.kaos.engine`. The rendered WorkflowTemplate carries the command (`python -I -m kaos_engine.compose`). |

The compose image is rebuilt when `config/` changed, when `engine-compose` in `{app}-pipeline-images` is not the context's `engine.version`, or when the kaos-lib package moved (its Dockerfile counts as one more step that declares the ARG).

`{app}-pipeline-images` records `engine-version` (the render), `engine-compose` (the compose image), and, after a failed run, `engine-last-error` and `engine-attempt` (`<engine version>@<epoch>`; `<engine version>@<epoch>@<commit>@<kaos-lib>` for an app refused as an old app, see below). The exit handler's `engine-record` step writes them to the gitops file (one line, at most 200 characters, from the failed pod's log: engine check (`probe-detect` or `detect-steps`), render, enhance or the compose image build). It clears them only after a run that Succeeded and rendered, enhanced or built the compose image; a run that failed outside the engine stages, or ran no engine stage, leaves them as they are. Only the last attempt of each engine step counts: these steps retry a lost pod, so Argo names each attempt's pod `<node>(N)`, and an attempt that was preempted and retried to success is not an error. Before 0.13.4 the record matched no retried pod, so a failed render or enhance recorded nothing and a successful run that only rendered cleared nothing (kubecore-operator#1832). The line is the step's error: Argo's executor lines that close a failed step's log (`Error: exit status 1`, `argo=true`) are skipped, an engine refusal (`kaos-engine: <reason>`) counts as an error line, kaniko's closing `error building image:` counts only when there is no other, and a Python traceback's last line loses its module path (`SomeError: what`) (0.15.3; before it, every failed render was recorded as `render: Error: exit status 1`, kubecore-operator#1864). The operator reads `engine-last-error` to show state `failed`.

**ENGINE DRIFT** (`ml-ci-reconcile`): a render or compose image whose recorded engine is not the context's `engine.version` submits one build. It re-renders and rebuilds the compose image only: `detect-steps` rebuilds no other image (except across kaos-lib 0.5, see "The step contract"). The records are read from gitops, so a render already pushed is not submitted again while ArgoCD has not synced it. **One attempt per hour:** while `engine-attempt` names the context's engine version and is younger than an hour, the poll submits nothing (a broken engine release does not loop builds; a new engine version has another name and is tried at once). A failed render never replaces the live WorkflowTemplate and builds no image: `hera-enhance-commit` only starts after `hera-render` succeeded and writes the file only after the enhance, the step table check, the gate and the size guard, and `build-push` is the step group after the render.

The PR check (`ml-ci-pr-render`) renders with the same template and the same engine. The step-folder gate does not look for a `compose-and-validate` folder.

```bash
python -m pytest charts/custom/kubecore-ci-workflows/tests/engine                      # files/engine.py
bash charts/custom/kubecore-ci-workflows/tests/engine-ci/run.sh /tmp/rendered.yaml     # render, detect-steps, compose Dockerfile, engine-record, executed
bash charts/custom/kubecore-ci-workflows/tests/engine-drift/run.sh /tmp/rendered.yaml  # ENGINE DRIFT and the hourly guard
```

The engine's `enhance.py` must understand every flag this chart passes (`--helper-configmap` since 0.12.149).

## The step contract (PRD novelcore/kaos#1911, chart 0.14.0, BREAKING)

This chart renders, builds and reports apps on the step contract only: `pipeline.py` declares `kind=`, `inputs=` and `produces=` (no `outputs=`, no `hpc_time_limit=`), a step runs with no arguments and reads one context, and kaos-lib is 0.5 or newer. There is no second path for older apps, and no app is moved: an app made before the contract is created again from the template. It needs a pipeline engine on the step contract (kaos-hpc-operator `engine/`, the release that writes the step table) and a kaos-lib 0.5 delivered by the platform; with an older engine every render fails closed ("the rendered pipeline carries no step table").

**An old app is refused before anything is recorded (AC-01, T-05).** An app made before the current pipelines fails before anything is recorded, and the pipeline it had keeps running:

| What is old | Where it fails | With |
|---|---|---|
| `pipeline.py`: a step without `kind=`, `outputs=`, `hpc_time_limit=` (every app from before the contract has at least the first) | `hera-render`, the engine's own refusal | the engine's message: one sentence that names the step and what is wrong, ending "Create it again from the template." |
| kaos-lib: the platform holds the app at a kaos-lib older than 0.5 because its `.kaos/compat.yaml` does not accept 0.5 (or declares nothing while an older one is delivered) | `detect-steps` (`kaos-lib.py contract`), before the render | the same words: it is built with kaos-lib N, the current pipelines need 0.5 or newer, then the same closing sentence |
| the engine: the context pins an engine from before the contract | the enhance steps (`engine.py steps`, exit 6) | "not on the step contract" (a platform fault, reported as an engine error) |

In all three nothing is committed to gitops (no WorkflowTemplate, no `engine-version`, no `last-built-sha`, no image key) and no image is built: the render is a step group of its own **before** `build-push` (until 0.13 they shared a group, so a refused app had every step image built first). The one build let through with an older kaos-lib is the one whose commit already accepts 0.5: its record (`kaos-lib-compat`) is how the platform learns the new range and then delivers 0.5.

**What the app's engineer sees.** The step that refuses calls `old_app` (`_helpers.tpl`), which leaves `/workspace/old-app` (one line: the engine's reason, without its closing sentence), the "What to change" section of the report comment (`/workspace/report-extra.md`) and one `kaos-ci: OLD APP:` line in the step log. The exit handler's `engine-record` then replaces the commit status `kubecore-ml-ci` with `Not built: this app was made before the current pipelines. Create it again from the template.`, followed by the engine's reason when the whole of it fits GitHub's 140 characters; the check's `target_url` is the run report, as for any failure. It records `engine-last-error` = that sentence and the reason (at most 200 characters), which the operator shows on the app. The pull request check (`ml-ci-pr-render`, the same `hera-render`) posts the sentence alone on `wft-render` (nothing the render wrote goes into that request). There is no guide to link: no app is moved. None of these texts names the platform's internals.

How a refusal is told from any other failed render: the engine ends its refusals of an app from before the contract with a fixed sentence, published as `old_app_marker` in its `authoring-schema.json`; `hera-render` reads that sentence from the engine it runs and looks for it in the render's error. A render that fails without it is an ordinary failure (the engine's own error in the log, the generic failure status). The kaos-lib check words its refusal the same way (`OLD_APP_NOTICE` in `files/kaos-lib.py`).

**One attempt, no loop.** A refused build records `engine-attempt` as `<engine version>@<epoch>@<commit>@<kaos-lib>` (the kaos-lib is the first 12 hex of the sha256 of the spec the context delivered; `engine.py attempt` / `engine.py refused`). While HEAD is that commit and the gitops context still pins that engine and delivers that kaos-lib, `ml-ci-reconcile` submits nothing, in the hourly poll and in a forced run alike (OLD APP GUARD, ahead of COMMIT DRIFT): another build would read what the refused one read. A push to the app, a new engine or another kaos-lib is tried at once. Any other engine failure keeps the one-attempt-per-hour guard.

**kaos-lib across 0.5.** Images built with a kaos-lib from before the contract cannot run a pipeline of this engine, so a reconcile-submitted build does not leave them "stale, rebuilt on use" when the context delivers 0.5: it rebuilds them (after the render, which an old app fails first). The bump pull request (`files/kaos-lib.py bump`) is the same whatever the range it crosses; a new `.kaos/compat.yaml` points at the guide's `support-window.html` (`kaosLib.guideUrl`).

**The form.** Every name a step declares in `inputs=` is a form field that holds a dataset reference (`dataset-<name>@<version>`). `hera-enhance-commit` reads the names from the engine's step table (the compose step's `--steps` argument, `engine.py steps`) and gives each field the catalog's choices (`files/dataset-choices.py fill`); a field named `dataset` is no longer special. The default stays what the app's config says, `latest` included (it is resolved to a commit when the run starts); a default the catalog does not offer becomes the latest of the same dataset, or of the project's default dataset. `dataset-sha` is `none` when no step declares an input. The form has no `<step>-cpu`, `<step>-mem` or `<step>-disk` field: a step gets the machine of its class. `ml-ci-reconcile`'s context drift check therefore compares the context's default cpu class memory with the `mem` input default of the `compose-and-validate` template (the compose step runs on that class), where it used to read a `*-mem` form field. The chart adds no form field and removes none, so it cannot collide with the keys the engine reserves (`plan`, `pipeline-version`).

**Shared datasets** (PRD novelcore/kaos#1533 F-23). The catalog lists datasets shared with the project after its own, as `<owner>/dataset-<n>` (kaos-lake already qualifies the name; a bare name with an owner is qualified by the picker, never twice). The enum and dropdown list the project's own datasets first (default first), then the shared ones grouped by owner in catalog order. A shared dataset is kept when the config names it and is never the fallback; a project with no dataset of its own leaves an unoffered value as it is. The `dataset-sha` digest covers the shared refs, so a share or unshare re-renders. Known flap: a peer outage over 10 minutes drops the shared refs from the catalog and moves the digest twice (out and back).

**The datasets a pipeline produces.** Every build that records images (`patch-images`) writes `produced-datasets` into `{app}-pipeline-images`: the short names of the datasets the rendered pipeline produces (the string inside `dataset("...")`, not the repository name `dataset-<app>-<name>`), sorted, comma separated, no spaces (`clean,features`), and the empty string when it produces none. It is read from the step table of the committed WorkflowTemplate (`engine.py produced`: the entries of `produces` whose type is `dataset`), never from `pipeline.py`, and it is never omitted; the operator reads it to tell the lake which datasets the app may write. A committed render without a step table fails the step (exit 6) and writes nothing; so does an old app, which never reaches `patch-images`. The keys of the record that are not images, and so not pinned by digest nor pruned: `last-built-sha`, `context-sha`, `engine-version`, `engine-compose`, `engine-last-error`, `engine-attempt`, `dataset-sha`, `wft-bytes`, `kaos-lib-package`, `kaos-lib-compat`, `produced-datasets`.

**Not done here: refusing an ADVANCED override over about 60 KiB at submit.** The override is a workflow parameter the engine passes to the compose step as an argument; above that size the step cannot start. A check before it needs either an extra task in the pipeline's DAG with its own image, or an expression on the compose argument whose message compose prints: both are the engine's to write (it owns the DAG and compose), and a chart post-pass that rewrote the argument could only make compose fail with an unrelated parse error.

```bash
bash charts/custom/kubecore-ci-workflows/tests/step-contract/run.sh /tmp/rendered.yaml   # the wording, the PR check, where the step table is read
# with a real engine (a python that has the kaos-pipeline-engine wheel installed), and apps still on the old contract:
ENGINE_PYTHON=/path/venv/bin/python OLD_APPS="/path/app-a /path/app-b" bash .../tests/step-contract/run.sh /tmp/rendered.yaml
```

The fixtures of `tests/connections` are two chart-owned apps on the contract (`fixtures/apps/hera`, `fixtures/apps/yolo`) rendered by the engine pinned in `harness.py` (`ENGINE_REF`); `run.sh` there says how to regenerate them and the golden files after an engine change.

**Moving the pins (the cutover).** The chart, the operator's pin of it, the engine pin and the platform's kaos-lib value move together, in a freeze: kaos-lib 0.5 delivered first, then the operator release that pins this chart and the engine on the contract. `pipelineLint.*` must name a kaos-lib 0.5 wheel (rule set 2.0.0 or later; the pin is kaos-lib 0.5.0rc11, rule set 2.5.0) from the same moment: the 0.4 linter reports the new keywords as errors.

## What a Dockerfile can read while its image builds (PRD novelcore/kaos#1911, chart 0.14.1)

`build-push` runs the developer's Dockerfile in kaniko, in the pod's main container, so everything that container mounts and every credential the pod can reach is readable by tenant `RUN` steps. How the pod authenticates to the registry:

| Registry | How kaniko pushes | What a `RUN` step can read |
|---|---|---|
| Artifact Registry (every GCP pool) | the pod runs as `ci-build-sa`, bound by Workload Identity to the organisation's CI Google account; kaniko's `gcr` credential helper (`DOCKER_CONFIG=/kaniko/.docker-gar`) exchanges that identity at the metadata endpoint | the same token, from the metadata endpoint: it can push to the organisation's repository under any app's name, for about an hour |
| in-cluster Zot | basic auth written by the `docker-config` init container into `/kaniko/.docker/config.json` | that file (kaniko keeps `/kaniko` out of the image filesystem it builds on, so it is readable) |

Fixed in this chart: the main container no longer mounts `registry-auth` (the password was only ever read by the init container; the mount gave `RUN` steps a second copy). `tests/build-isolation/run.sh` asserts the container mounts the workspace and the docker config only, and no token.

**Not fixed in the chart, and why.** A pod cannot hold a credential its Dockerfile steps cannot read: kaniko and the `RUN` steps share the pod's network namespace and identity. The options, checked against the cluster:

- *A NetworkPolicy denying `169.254.169.254` to build pods* is enforced (the pools run GKE Dataplane V2, which enforces egress policies on the metadata address), and it stops the push: the `gcr` helper reads the same endpoint. It only works together with a credential that is not ambient.
- *`--no-push --tar-path`, then a push step that runs no developer code* closes the hole, and needs a build pod with no Google identity (a service account without the Workload Identity binding, plus the policy above), a second pod that holds the identity and pushes, and a way to carry the tarball between them (a multi-GiB image: a volume or an object-store artifact). kaniko's layer cache is pushed and pulled with the same credential, so it must move to the push side or be given up; giving it up turns the cached seconds into the ~50 minute cold builds the cache exists to avoid.
- *A short-lived push credential handed to kaniko as a file* limits the window, not the reach: Artifact Registry has one repository per organisation, and a downscoped token cannot be narrowed to one app's package names.

The proposal that closes it, which needs the pool's identity setup (outside this chart): one Artifact Registry repository per app (or an IAM condition on the package path, to be verified), one Google account per app with writer on that repository only, and `ci-build-sa` replaced for builds by that account. Then the ambient token reaches only the app's own images, which the app may write anyway, and the policy above is unnecessary.

## The render pod runs the developer's pipeline.py (PRD novelcore/kaos#1911, chart 0.14.2)

`hera-render` (the merge build and the pull-request check run the same template) imports the app's `pipeline.py` and may pip-install the app's own dependencies, so it is treated as hostile code:

| | |
|---|---|
| user | `65532`, `runAsNonRoot`, `fsGroup 65532` (the workspace volume was cloned by an earlier root step; the fsGroup makes it writable), seccomp `RuntimeDefault` |
| container | read-only root filesystem, `allowPrivilegeEscalation: false`, every capability dropped |
| writable | the workspace volume, `/tmp` (an `emptyDir`), and `/usr/local` |
| `/usr/local` | an `emptyDir` filled by the `python-overlay` init container (same engine image, same restrictions) with a copy of the interpreter's tree, so `pip install` of the app's missing dependencies lands in it while the image's root stays read-only |
| credentials | no service-account token (the executor has its own, `hera-render-exec`, workflowtaskresults only), no GitHub token, no registry secret, no lake token |
| network | `ci-render-egress` (below) |

**Network policy.** `renderPods.networkPolicy.enabled` renders `ci-render-egress`, selecting pods labelled `platform.kubecore.io/ci-pod: render`: egress to cluster DNS (kube-dns and the node-local cache), to the Kubernetes API at `renderPods.networkPolicy.kubeApiCIDRs` (the Argo executor in the pod reports the result there; the chart refuses to render the policy without it, since a render that cannot report fails), and to TCP 443 on any address outside `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` and `169.254.0.0/16`. So the render reaches the public package index and nothing inside the cluster, no node address and not the metadata endpoint. A standard NetworkPolicy cannot name hosts (no FQDN policy is installed on the pools), so the index itself is not the only thing reachable on 443: restricting to the index needs an FQDN policy or an in-cluster mirror. It is off by default because the control plane's address belongs to the cluster; whoever installs the chart for a cluster sets it.

Enforcement: the pools and the hubs run GKE Dataplane V2 (`anetd`, datapath `ADVANCED_DATAPATH`), which enforces `networking.k8s.io/v1` NetworkPolicy including egress. That was read from the clusters and their cluster description; no test pod was run against a policy there.

```bash
bash charts/custom/kubecore-ci-workflows/tests/render-isolation/run.sh   # the pod, the policy, and (podman) a read-only pip install
```

## The run form is sealed at render (PRD novelcore/kaos#1533, F-21/F-22, chart 0.17.0)

After the engine has enhanced the WorkflowTemplate and the dataset pickers are filled, `hera-enhance-commit` (the merge build) and `hera-enhance-gate` (the pull-request check) run the seal, `python3 -I /tmp/kaos-run-form/run_form.py seal ...`. The seal is chart code (`files/run_form.py`, stdlib plus PyYAML, written to `/tmp/kaos-run-form/` by the helper `kubecore-ci-workflows.runFormScript`); it imports nothing from the engine and nothing from the checkout. It builds the run form from data the trusted enhance wrote (`/tmp/form-data.json`, which `kubecore.enhance --form-data` exports), the step table, the pipeline context and the app's optional `config/_form.yaml`, stamps it (engine version, source commit, params digest) and writes it to the template's annotations once, atomically. It is the only writer of `ui.kubecore.io/run-form`: every `ui.kubecore.io/*` key, every `platform.kubecore.io/*` key outside the platform's own, and every such key under `spec.workflowMetadata.labelsFrom` is deleted first. It runs before the structural GATE, the size guard and the copy to gitops, so a refusal commits nothing.

- **Release note: a bad `_form.yaml`, an option file that fails to compose, or a form over 128 KiB fails the build (fail-closed).** The step prints the seal's `GATE FAIL: run form: ...` text, which names the field or key and the fix. The pull-request check fails the same way, so the author sees it before merging. A `showIf` problem never fails a build: the `showIf` is dropped and the field always shows.
- **Needs an engine that writes `--form-data`** (kaos-hpc-operator, the H1 to H5 hooks). With an older engine `kubecore.enhance` rejects the flag and the build fails before anything is committed; the next build after the engine pin moves passes. There is no skip branch: the seal always runs.
- **The commit** is the `COMMIT_SHA` env var of the step (the workflow's `commit_sha`; the PR head SHA in the PR check), never spliced into the script, and is checked to be 40 lowercase hex characters before use.
- **`--previous`** (merge build only) is the live `workflow-template.yaml` in gitops, passed only when it exists, so an unchanged render keeps its commit and a no-op push makes no gitops commit. The PR check passes none (and seals before the dataset fill).
- **An app is sealed once it is rebuilt.** Until then the console shows the fallback form (`form_absent`) and refuses console submits; `kubectl` and the Argo UI are unaffected.

```bash
bash charts/custom/kubecore-ci-workflows/tests/run-form-seal/run.sh   # the wiring (order, env-only commit, arguments, no skip) and the seal's own unit, golden and fail-closed tests
RUN_FORM_OSR_DIR=<kaos-osr-edge-operator checkout> bash charts/custom/kubecore-ci-workflows/tests/run-form-seal/run.sh   # also runs the merged OSR consumer (needs go)
```


## Platform templates by prefix (PRD novelcore/kaos#1911, chart 0.15.4)

The engine reserves the prefix `kaos-` for its own templates and refuses a developer step that starts with it, so the pull-request gate and its report treat every template named `kaos-*` as the platform's, not as a step with a folder. Two kinds, told apart by name:

- `kaos-matrix-<step>` is the fan of a step declared with `matrix=`: it runs the image of `<step>` and has no container of its own. It needs no folder and no image-record key; the folder `steps/<step>/` is already required by the step's own template. The report says "runs the image of step `<step>`".
- `kaos-gather-<step>`, `kaos-promote` and any other `kaos-*` template run the platform's compose image (record key `compose-and-validate`). No folder is asked for and no key is seeded; the report says "built by the platform". Before 0.15.3 only `kaos-promote` was known, so a pipeline with a matrix step failed the gate with `step 'kaos-gather-<step>': expected steps/kaos_gather_<step>/Dockerfile`.

The merge build already derived its image keys from the template inputs that read the record, so it never saw these names; `tests/matrix-pipeline` runs the gate, the record writer (seed, prune, a second pass that changes nothing) and the size guard on a real engine render of a pipeline with a matrix step.
## Strict templateReferencing conformance (PRD novelcore/kaos#1533, F-26, chart 0.16.0)

Argo's `workflowRestrictions.templateReferencing: Strict` marks a Workflow Error unless it has `workflowTemplateRef` and its own spec sets only allowlisted fields (`arguments`, `entrypoint`, `shutdown`, `suspend`, `activeDeadlineSeconds`, `priority`, `ttlStrategy`, `podGC`, `volumeClaimGC`, `archiveLogs`, `workflowMetadata`, `workflowTemplateRef`, `metrics`, `artifactGC`). A CronWorkflow's `workflowSpec` is copied into each Workflow, so it follows the same rule. This release makes the chart's own objects conform. Nothing turns Strict on here; the operator does that.

- **pending-reaper (C1).** The CronWorkflow's `workflowSpec` is now only `workflowTemplateRef: {name: pending-reaper}`. The ServiceAccount, entrypoint, deadline, ttl and the reap script (unchanged) moved into a namespaced `WorkflowTemplate pending-reaper`, not a ClusterWorkflowTemplate, so a tenant namespace cannot reference it.
- **Reconcile templates (C2a).** `ci-reconcile`, `ml-ci-reconcile` and `kaos-lib-bump-pr` own their ServiceAccount (`reconciler.serviceAccountName`, default `operate-workflow-sa`) and mount the token Secret named by `github.tokenSecretName` (fixed in the template, deliberately not a parameter, so a submitter cannot choose the mounted Secret). A caller that still passes its own `serviceAccountName` and `volumes` keeps working: the Workflow's fields win.
- **ml-autoscaler-healer (C2b).** Owns its ServiceAccount (`autoscalerHealer.serviceAccountName`, default `ml-compute-probe-sa`).
- **ml-ci-dataset-release (C2c).** The per-app Workflow is built from only the CronWorkflow's `workflowTemplateRef` and `arguments` (`dataset_event=true`) plus a `ttlStrategy`. The copied `serviceAccountName` and `volumes` and the `{app}-dataset-rerender` mutex are gone: concurrent runs for one app serialise on ml-ci-reconcile's `{app}-build` mutex in `decide-and-submit`.

Compatibility: today's operator renders (callers passing `serviceAccountName` and `volumes`) work unchanged against 0.16.0. Test: `tests/strict-references/run.sh`.

### Changelog

- 0.16.0: the changes above; new suite `tests/strict-references`.
- 0.16.2: `check-drift` is capped by a per-cluster semaphore (6) and lists narrowly; its request is 96Mi (`tooling.checkDriftResources`); the pending-reaper lists unfinished workflows only, request 64Mi (`tooling.reaperResources`); new suite `tests/check-drift-cap`.
- 0.17.1: `patch-images` records each step image with its digest on Artifact Registry too (it only knew the in-cluster registry's user and password, so on Artifact Registry it was skipped and the record kept tags; a run that starts from a later step compares images by digest and was refused). The token is the build service account's, from the metadata server; without one the build still passes and the log says what stops working. New suite `tests/digest-pin` (the block executed against a stub registry). PRD novelcore/kaos#1911, D-52.
- 0.17.2: the digest step of `patch-images` no longer takes the `context-sha` record key for an image (every build on Artifact Registry printed a warning that no digest was resolvable for it; found by running the 0.17.1 block against the real registry on dev). PRD novelcore/kaos#1911, D-52.

## A fan-out of reconcile runs queues instead of starving the node (PRD novelcore/kaos#1911, chart 0.16.2)

Why: on a dev e2e, about 20 `check-drift` pods of `ml-ci-reconcile` ran at once (a dataset release re-checks every app; the hourly polls add more). They run on the small system node pool, requested 208Mi each and used 375-590Mi: the node starved and the workflow controller, gateway and policy engine on it stalled.

- **Cap.** `check-drift` takes a slot of an Argo semaphore: `ci.checkDrift.slots` (default 6) in the ConfigMap `ci-check-drift-slots` (key `slots`), which this chart renders into the chart's namespace. The semaphore names that namespace, so the count is **per cluster**, across every project's CI namespace (the pods share one system pool). A run over the cap waits in Argo: no pod, so nothing for the pending-reaper to kill and nothing for the autoscaler to count; it is not lost, and it ends at the run's `activeDeadlineSeconds`. Argo takes the slot on the retry node, so the slot is kept across the "not yet" retries (exit 3) and a killed pod (137) retries without queueing again: a forced re-render is never dropped. The semaphore sits on `check-drift` only; `decide-and-submit` keeps the app's `{app}-build` mutex and takes no slot of its own, and a slot holder never waits for a mutex, so there is no lock cycle. A run waiting for a slot holds its app's build mutex (the build of that app queues behind a decision that takes seconds). What bounds the number is `slots` x the request on the system pool (6 x 96Mi = 576Mi); a slot is also held for up to about 45 minutes by a new app whose repository is slow to appear, so a low cap throttles a mass creation. Needs the workflow controller to read ConfigMaps in the chart's namespace (the cluster-wide install does). **Symptom when it cannot** (or when the ConfigMap is missing): every `ml-ci-reconcile` run ends in Error on the `check-drift` node with `failed to initialize semaphore <namespace>/ConfigMap/ci-check-drift-slots/slots with limit`. Check that the ConfigMap exists in the chart's namespace (`workflow.namespace`, else the release namespace), that its `slots` is a number, and that the controller's ClusterRole lets it `get` configmaps there (a namespaced controller install does not).
- **Cheap lists.** The in-flight guard lists only unfinished workflows (`-l workflows.argoproj.io/completed!=true`, server side; a workflow the controller has not labelled yet still matches). The hourly attempt guard (`kl_last_try`) asks for the finished attempts of one app and spec by label. The "was the app used" read of the ML namespace goes through the API in pages of 10 and keeps the newest match. Before, each poll downloaded and parsed every finished workflow of the namespace (150 of ~370 KB: 804 MiB peak in the measurement below).
- **pending-reaper.** It listed `kubectl get wf -A -o json` (every workflow of the cluster) every few minutes and kept only phase Running. It now lists `-l workflows.argoproj.io/completed!=true`: the same set. Its request is `tooling.reaperResources` (64Mi, no limit): peak 16 MiB, from 900 MiB. `tests/check-drift-cap` runs the old and the new script against the same cluster state and compares what they reap.
- **Request.** `tooling.checkDriftResources` (check-drift only; `clusterResources` stays for the non-ML reconciler): 96Mi request, **no limit** (an OOMKill drops a forced re-render). Measured peak in a pod with the same image: 804 MiB before, 40 MiB after for the in-flight list, 75 MiB with a 0.9 MB WorkflowTemplate read on top.

Tests: `tests/check-drift-cap/run.sh` (render guards; the script executed against a stub that refuses an unselected list), `tests/check-drift-cap/kind/run.sh` (real Argo v4.0.6: cap, queue, the reaper, forced runs, mutex).

## Tests

```bash
helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
bash charts/custom/kubecore-ci-workflows/tests/sync-wait/run.sh                  # render guards
bash charts/custom/kubecore-ci-workflows/tests/reconcile-trigger/run.sh          # check-drift script against stubs
bash charts/custom/kubecore-ci-workflows/tests/check-drift-cap/run.sh             # the check-drift cap and its narrow lists
bash charts/custom/kubecore-ci-workflows/tests/check-drift-cap/kind/run.sh [outdir] # real Argo v4.0.6 in kind: cap, queue, reaper, forced runs
bash charts/custom/kubecore-ci-workflows/tests/sync-wait/kind/run.sh [outdir]    # real Argo v4.0.6 in kind (needs docker, kind)
bash charts/custom/kubecore-ci-workflows/tests/build-pacing/run.sh               # pacing render guards
bash charts/custom/kubecore-ci-workflows/tests/build-pacing/kind/run.sh [outdir] # real Argo: cap, render-only, mutex
bash charts/custom/kubecore-ci-workflows/tests/build-isolation/run.sh            # what the build container mounts
bash charts/custom/kubecore-ci-workflows/tests/render-isolation/run.sh           # the render pod and its network policy
bash charts/custom/kubecore-ci-workflows/tests/run-form-seal/run.sh              # the run-form seal: wiring and module
bash charts/custom/kubecore-ci-workflows/tests/matrix-pipeline/run.sh /tmp/rendered.yaml # a matrix pipeline: gate, record, size
bash charts/custom/kubecore-ci-workflows/tests/strict-references/run.sh          # Strict templateReferencing conformance (F-26)
```
