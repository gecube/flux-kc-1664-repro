#!/usr/bin/env bash
# Reproducer for fluxcd/kustomize-controller#1664.
#
# Builds three manifest snapshots (stage A, B, C), commits/pushes each in turn,
# and observes whether resources that disappear from kustomize output between
# stages are correctly pruned.
set -euo pipefail

export PATH="$HOME/.orbstack/bin:$PATH"

REPO_URL="${REPO_URL:-https://github.com/gecube/flux-kc-1664-repro.git}"
KIND_CLUSTER="${KIND_CLUSTER:-flux-kc-1664}"
WORKDIR="${WORKDIR:-$HOME/flux-kc-1664-repro}"
INTERVAL="30s"
WITH_FINALIZER=0
WITH_RESTART=0
CLEANUP=0

for arg in "$@"; do
  case "$arg" in
    --with-finalizer) WITH_FINALIZER=1 ;;
    --with-restart) WITH_RESTART=1 ;;
    --cleanup) CLEANUP=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32mOK\033[0m: %s\n' "$*"; }
bad() { printf '\033[1;31mFAIL\033[0m: %s\n' "$*"; }

cd "$WORKDIR"

cleanup() {
  log "cleanup"
  kind delete cluster --name "$KIND_CLUSTER" || true
  rm -rf "$WORKDIR/manifests"
}

if [[ $CLEANUP -eq 1 ]]; then cleanup; exit 0; fi

write_stage_A() {
  rm -rf manifests
  mkdir -p manifests/apps/application-nodes/general/{base,1a,1b,1c}
  mkdir -p manifests/consolidated

  cat >manifests/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - apps
  - consolidated
EOF

  cat >manifests/apps/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - application-nodes
EOF

  cat >manifests/apps/application-nodes/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - general
EOF

  cat >manifests/apps/application-nodes/general/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - 1a
  - 1b
  - 1c
EOF

  cat >manifests/apps/application-nodes/general/base/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cm.yaml
EOF

  cat >manifests/apps/application-nodes/general/base/cm.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app
  namespace: kc-1664
data:
  origin: layered
EOF

  for az in 1a 1b 1c; do
    cat >"manifests/apps/application-nodes/general/${az}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../base
patches:
  - patch: |-
      - op: replace
        path: /metadata/name
        value: app-${az}
    target:
      kind: ConfigMap
EOF
  done

  cat >manifests/consolidated/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cm.yaml
EOF

  cat >manifests/consolidated/cm.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-flat
  namespace: kc-1664
data:
  origin: consolidated
EOF
}

write_stage_B() {
  # Mimics commit b33f69e0 — delete leaf overlays but keep parent resources: refs.
  rm -rf manifests/apps/application-nodes/general/1a
  rm -rf manifests/apps/application-nodes/general/1b
  rm -rf manifests/apps/application-nodes/general/1c
  # general/kustomization.yaml still lists [1a, 1b, 1c] — `kustomize build` will now fail.
}

write_stage_C() {
  # Final consolidated state — drop apps/ entirely.
  rm -rf manifests/apps
  cat >manifests/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - consolidated
EOF
}

commit_and_push() {
  local msg="$1"
  git add -A
  git commit -q -m "$msg"
  git push -q origin main
}

wait_for_reconcile_msg() {
  local timeout="${1:-90}" pattern="$2" deadline=$(( $(date +%s) + timeout ))
  while [[ $(date +%s) -lt $deadline ]]; do
    if flux get kustomization kc-1664 -n flux-system --status-selector ready 2>/dev/null | grep -qE "$pattern"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

log "stage 0: provision kind + flux + bootstrap source"

if ! kind get clusters | grep -qx "$KIND_CLUSTER"; then
  kind create cluster --name "$KIND_CLUSTER" --wait 90s
fi
kubectl config use-context "kind-$KIND_CLUSTER" >/dev/null

if ! kubectl get ns flux-system >/dev/null 2>&1; then
  flux install --components=source-controller,kustomize-controller
fi
# kindnet >=v0.32 enforces NetworkPolicies; flux's defaults block egress in kind. Drop them for the test.
kubectl -n flux-system delete netpol allow-egress allow-scraping allow-webhooks --ignore-not-found
kubectl -n flux-system rollout restart deploy/source-controller deploy/kustomize-controller >/dev/null 2>&1 || true
kubectl -n flux-system rollout status deploy/source-controller --timeout=90s
kubectl -n flux-system rollout status deploy/kustomize-controller --timeout=90s

# Patch CoreDNS to use public DNS (OrbStack's internal resolver isn't reachable from pod network).
kubectl -n kube-system get cm coredns -o json | python3 -c "
import json, sys
d=json.load(sys.stdin)
new=d['data']['Corefile'].replace('forward . /etc/resolv.conf','forward . 1.1.1.1 8.8.8.8')
if new!=d['data']['Corefile']:
    d['data']['Corefile']=new
    print(json.dumps(d))
" | { read -r line && [[ -n "$line" ]] && { echo "$line"; cat; } | kubectl apply -f - && kubectl -n kube-system rollout restart deploy/coredns; } || true

kubectl create ns kc-1664 --dry-run=client -o yaml | kubectl apply -f -

log "stage A: layered overlay produces app-1a, app-1b, app-1c, app-flat"
write_stage_A
git add -A
if ! git rev-parse HEAD >/dev/null 2>&1; then
  commit_and_push "feat: initial layered overlay (stage A)"
else
  git diff --cached --quiet || commit_and_push "feat: reset to stage A layout"
fi

# Reapply Flux source + kustomization fresh each run.
kubectl delete kustomization kc-1664 -n flux-system --ignore-not-found --wait=true
kubectl delete gitrepository kc-1664 -n flux-system --ignore-not-found
flux create source git kc-1664 \
  --url="$REPO_URL" --branch=main --interval="$INTERVAL" \
  --namespace=flux-system
flux create kustomization kc-1664 \
  --source=GitRepository/kc-1664 --path=./manifests --prune=true \
  --interval="$INTERVAL" --target-namespace=kc-1664 \
  --namespace=flux-system --wait=false

log "wait for stage A to apply"
sleep 5
flux reconcile kustomization kc-1664 -n flux-system --with-source

stage_a_cms=$(kubectl get cm -n kc-1664 -o name 2>/dev/null | grep -E 'app(-1a|-1b|-1c|-flat)$' | sort)
echo "$stage_a_cms"
[[ $(echo "$stage_a_cms" | wc -l | tr -d ' ') -eq 4 ]] && ok "stage A produced 4 ConfigMaps" || { bad "stage A incomplete"; exit 1; }

if [[ $WITH_FINALIZER -eq 1 ]]; then
  log "attach blocking finalizer to app-1a/1b/1c (variant 2)"
  for az in 1a 1b 1c; do
    kubectl patch cm "app-${az}" -n kc-1664 --type=json \
      -p='[{"op":"add","path":"/metadata/finalizers","value":["example.com/blocker"]}]'
  done
fi

log "stage B: delete overlay leaves but keep resources: refs (broken build)"
write_stage_B
commit_and_push "chore: delete overlay leaves mid-refactor (stage B - broken build)"
sleep 5
flux reconcile kustomization kc-1664 -n flux-system --with-source || true

log "stage B status (expect BuildFailed)"
flux get kustomization kc-1664 -n flux-system || true

if [[ $WITH_RESTART -eq 1 ]]; then
  log "kill kustomize-controller mid-transient (variant 3 hypothesis)"
  kubectl -n flux-system delete pod -l app=kustomize-controller --wait=false
  kubectl -n flux-system rollout status deploy/kustomize-controller --timeout=90s
fi

log "stage C: drop apps/ entirely, consolidated remains"
write_stage_C
commit_and_push "feat: remove deprecated apps/ subtree (stage C - consolidation)"
sleep 5
flux reconcile kustomization kc-1664 -n flux-system --with-source || true
sleep 8
flux reconcile kustomization kc-1664 -n flux-system --with-source || true

log "final cluster state"
kubectl get cm -n kc-1664 -o wide
echo "---"
echo "Kustomization inventory entries:"
kubectl get kustomization kc-1664 -n flux-system -o jsonpath='{range .status.inventory.entries[*]}{.id}{"\n"}{end}'
echo "---"
remaining=$(kubectl get cm -n kc-1664 -o name 2>/dev/null | grep -cE 'app-(1a|1b|1c)$' || true)
if [[ "$remaining" -gt 0 ]]; then
  bad "BUG REPRODUCED: $remaining per-AZ ConfigMap(s) survived after stage C consolidation"
  kubectl get cm -n kc-1664 -l kustomize.toolkit.fluxcd.io/name=kc-1664 -o jsonpath='{range .items[*]}{.metadata.name}{"  deletionTimestamp="}{.metadata.deletionTimestamp}{"  finalizers="}{.metadata.finalizers}{"\n"}{end}'
  exit 1
else
  ok "no orphans — Flux pruned the per-AZ ConfigMaps correctly"
fi
