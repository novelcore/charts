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

## Tests

```bash
helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
bash charts/custom/kubecore-ci-workflows/tests/sync-wait/run.sh                  # render guards
bash charts/custom/kubecore-ci-workflows/tests/reconcile-trigger/run.sh          # check-drift script against stubs
bash charts/custom/kubecore-ci-workflows/tests/sync-wait/kind/run.sh [outdir]    # real Argo v4.0.6 in kind (needs docker, kind)
```
