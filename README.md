# flux-kc-1664-repro

Minimal reproducer for [fluxcd/kustomize-controller#1664](https://github.com/fluxcd/kustomize-controller/issues/1664):
resources are not pruned after a rapid series of commits in which an intermediate
`kustomize build` is broken, even though `prune: true` is set.

## What this exercises

The script walks through three commits on `main` against a `Kustomization` with
`prune: true` and a 30s reconcile interval:

| Stage | Commit | Build output | Expected on-cluster |
|---|---|---|---|
| A | `feat: initial layered overlay` | `app-1a`, `app-1b`, `app-1c`, `app-flat` | all four created |
| B | `chore: delete overlay leaves (mid-refactor)` | **build error** — `resources: [1a, 1b, 1c]` references missing dirs | reconcile fails, inventory should not advance |
| C | `feat: remove deprecated apps/` | `app-flat` only | `app-1a/1b/1c` should be pruned |

If after stage C the three per-AZ ConfigMaps still exist, the bug reproduces.

## Two variants

- **Variant 1 (`./repro.sh`)** — bare ConfigMaps, no finalizers. Tests whether the
  inventory-vs-build comparison alone leaves orphans.
- **Variant 2 (`./repro.sh --with-finalizer`)** — same flow, but the per-AZ
  ConfigMaps get a custom finalizer (`example.com/blocker`) applied via
  `kubectl patch` between stages A and B, simulating Karpenter's
  `karpenter.k8s.aws/termination` finalizer behaviour.

## Run

```
./repro.sh                     # variant 1
./repro.sh --with-finalizer    # variant 2
./repro.sh --cleanup           # tear everything down
```

Requires: `kind`, `flux` CLI, `kubectl`, `git`, Docker (or OrbStack).
