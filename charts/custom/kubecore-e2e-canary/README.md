# kubecore-e2e-canary

An **e2e-only** fault-injection target. It exists for one end-to-end check — kaos
`helm_release_self_heals` — which proves that a pool Helm Release that fails its `wait`
recovers by itself through provider-helm's `rollbackLimit` (kubecore-operator #1464).

It is one small Deployment (registry.k8s.io busybox, pinned by tag and digest, with
requests) whose readiness probe fails until the instant `readyAfter`:

| `readyAfter`            | readiness                          |
|-------------------------|------------------------------------|
| `""` (default)          | Ready immediately                  |
| an RFC3339 instant      | NotReady until then, Ready after   |
| anything else           | the render fails (never "ready now") |

So an upgrade that sets `readyAfter` beyond the Release's `waitTimeout` fails (the release
goes `failed`), and the first attempt after `readyAfter` succeeds.

## Who installs it

Nobody by hand. The kubecore-operator renders it as an extra `e2e-canary` Release in the
pool's clusteroperators composition **only** when all of these hold:

- the operator runs with `--enable-e2e-faults` (set on the dev hub only, never prod);
- the KubePool carries the e2e run label `kaos.io/e2e-run` and is named `e2e-<that run id>`;
- the KubePool annotation `e2e.kubecore.io/helm-canary` is `"on"`.

`readyAfter` comes from the KubePool annotation `e2e.kubecore.io/helm-canary-ready-after`.
The Release installs into its own namespace (`kubecore-e2e-canary`, created by the
composition) and never touches a platform release.

## Values

| key | default | meaning |
|-----|---------|---------|
| `readyAfter` | `""` | RFC3339 instant the probe starts passing |
| `replicas` | `1` | |
| `image.repository` / `tag` / `digest` | registry.k8s.io/e2e-test-images/busybox 1.36.1-1 | pinned |
| `resources` | 5m / 8Mi requests | |
| `probePeriodSeconds` | `5` | |
| `nodeSelector`, `tolerations` | `{}` / `[]` | the operator passes the pool's system scheduling |

## Tests

```bash
sh charts/custom/kubecore-e2e-canary/tests/render/run.sh
```

Renders the chart and executes the rendered probe command for a past, a future and an
empty `readyAfter`.
