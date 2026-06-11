# flux-kc-1664-repro

Stable minimal reproducer for
[fluxcd/kustomize-controller#1664](https://github.com/fluxcd/kustomize-controller/issues/1664):
resources are not pruned after a sequence of commits in which an intermediate
`kustomize build` is broken and the target resources carry a blocking finalizer.

## TL;DR

- Verified against `ghcr.io/fluxcd/kustomize-controller:v1.8.8` (Flux v2.8.8) on
  `kind v0.32` / Kubernetes v1.36.1.
- 3/3 consecutive runs reproduce: per-AZ resources survive past the
  consolidation commit with `deletionTimestamp` set and a blocking finalizer,
  while `status.inventory` on the Kustomization has already advanced past them.
- Without the finalizer, the same commit sequence prunes correctly — so the
  bug requires the combination of *(a) inventory transitions through a broken
  build* AND *(b) a delete request being blocked by a finalizer at the moment
  of prune*.

## Repro setup

| Stage | Commit message | `kustomize build` result | Expected on-cluster |
|---|---|---|---|
| A | `feat: initial layered overlay (stage A)` | 4 ConfigMaps: `app-1a`, `app-1b`, `app-1c`, `app-flat` | all four applied |
| B | `chore: delete overlay leaves mid-refactor (stage B - broken build)` | **error** — `accumulating resources: ... no such file or directory: 1a` | reconcile fails, no state change expected |
| C | `feat: remove deprecated apps/ subtree (stage C - consolidation)` | 1 ConfigMap: `app-flat` only | `app-1a/1b/1c` should be pruned |

Between stages A and B, the variant flag `--with-finalizer` attaches a
custom finalizer (`example.com/blocker`) to `app-1a/1b/1c` via `kubectl patch`.
This stands in for any controller-owned finalizer that holds deletes (in our
production trigger it was `karpenter.k8s.aws/termination`).

## How to run

```
brew install --cask orbstack          # if no Docker yet
brew install kind flux kustomize gh   # CLI prerequisites
./repro.sh                            # variant 1: baseline (no finalizer)   → exit 0
./repro.sh --with-finalizer           # variant 2: BUG REPRODUCES            → exit 42
./repro.sh --with-finalizer --with-restart   # variant 3: + kill kustomize-controller between B and C
./repro.sh --cleanup                  # tear the kind cluster down
```

Exit codes: `0` = expected behaviour (prune worked OR baseline pass without
finalizer); `42` = bug observed (orphans remain); `1` = unexpected (e.g.
orphans without finalizer, investigate).

## Observed result, variant 2 (3/3 runs)

```
== final cluster state ==
NAME               DATA   AGE
app-1a             1      ...
app-1b             1      ...
app-1c             1      ...
app-flat           1      ...

Kustomization inventory entries:
kc-1664_app-flat__ConfigMap         # <-- only app-flat is tracked

FAIL: BUG REPRODUCED (as expected with finalizer): 3 per-AZ ConfigMap(s) survived after stage C
app-1a  deletionTimestamp=2026-06-11T17:23:45Z  finalizers=["example.com/blocker"]
app-1b  deletionTimestamp=2026-06-11T17:23:45Z  finalizers=["example.com/blocker"]
app-1c  deletionTimestamp=2026-06-11T17:23:45Z  finalizers=["example.com/blocker"]
```

Key data points:

1. `deletionTimestamp` IS set — Flux did issue the delete request during the
   stage B→C transition.
2. The blocking finalizer prevented K8s from completing the delete.
3. The Kustomization's `status.inventory` advanced past the orphans regardless,
   so subsequent reconciles do not retry the prune.
4. Removing the finalizer manually (`kubectl patch -p '{"metadata":{"finalizers":null}}'`)
   completes the deletion immediately — proving the only thing standing
   between the orphan state and a clean cluster is a Flux retry that never happens.

## Production-equivalent orphan state — reproduced

The production case had orphans with `deletionTimestamp: null` (no delete in
flight). That state is reproduced exactly by `repro-restart-matrix.sh`, scenario
`webhook-deny-delete`:

```
app-1a  deletionTimestamp=  finalizers=  managedFields=kustomize-controller,
app-1b  deletionTimestamp=  finalizers=  managedFields=kustomize-controller,
app-1c  deletionTimestamp=  finalizers=  managedFields=kustomize-controller,
inventory:  kc-1664_app-flat__ConfigMap     # only app-flat tracked
```

Setup: a `ValidatingAdmissionPolicy` rejects `DELETE` for `app-1a/1b/1c` in the
target namespace. Flux issues the prune DELETE; the apiserver returns 4xx
*before* setting `deletionTimestamp`; Flux logs an error but advances
`status.inventory` past the orphans regardless.

3/3 consecutive runs reproduce. In real-world terms, this is what happens when
a controller's validating webhook (e.g. Karpenter's EC2NodeClass validation)
refuses the delete because a sibling resource still references the one being
pruned.

## Restart-only hypothesis: NOT confirmed

I ran six controller-restart timings (no finalizer, no webhook) — `none`,
`before-c-push`, `right-after-c-push`, `during-c-reconcile`, `after-c-apply`,
and a 12× rapid-kill `spam`. Every single one pruned cleanly. Killing the
kustomize-controller alone, in any timing relative to the A→B→C transition,
does not produce orphans. The restart hypothesis is ruled out as a sole cause.
