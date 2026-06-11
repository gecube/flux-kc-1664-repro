#!/usr/bin/env bash
# Probe: can kustomize-controller pod restart at various points in the
# A → B → C transition produce orphans WITHOUT a blocking finalizer?
#
# This is the production-trigger hypothesis we couldn't repro with
# `--with-finalizer`: the orphan EC2NodeClass had deletionTimestamp: null
# and empty managedFields, suggesting prune never even fired.
set -euo pipefail
export PATH="$HOME/.orbstack/bin:$PATH"

REPO_URL="${REPO_URL:-https://github.com/gecube/flux-kc-1664-repro.git}"
KIND_CLUSTER="${KIND_CLUSTER:-flux-kc-1664}"
WORKDIR="${WORKDIR:-$HOME/flux-kc-1664-repro}"
INTERVAL="30s"

cd "$WORKDIR"
kubectl config use-context "kind-$KIND_CLUSTER" >/dev/null

log()  { printf '\n\033[1;34m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
note() { printf '  \033[2m· %s\033[0m\n' "$*"; }
pass() { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; }

# --- helpers reused from repro.sh -----------------------------------------

reset_cluster_state() {
  kubectl -n flux-system delete kustomization kc-1664 --ignore-not-found --wait=true 2>/dev/null || true
  kubectl -n flux-system delete gitrepository kc-1664 --ignore-not-found 2>/dev/null || true
  if kubectl get ns kc-1664 >/dev/null 2>&1; then
    for cm in $(kubectl -n kc-1664 get cm -o name 2>/dev/null | grep -E 'app(-1a|-1b|-1c|-flat)$'); do
      kubectl -n kc-1664 patch "$cm" --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
    done
    kubectl -n kc-1664 delete cm --all --wait=true 2>/dev/null || true
  fi
  kubectl create ns kc-1664 --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

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
  rm -rf manifests/apps/application-nodes/general/{1a,1b,1c}
}
write_stage_C() {
  rm -rf manifests/apps
  cat >manifests/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - consolidated
EOF
}

commit_and_push() {
  git add -A
  git diff --cached --quiet || { git commit -q -m "$1"; git push -q origin main; }
}

kill_kc_pod() {
  kubectl -n flux-system delete pod -l app=kustomize-controller --wait=false --grace-period=0 --force 2>/dev/null || true
}

orphan_count() {
  local n
  n=$(kubectl -n kc-1664 get cm -o name 2>/dev/null | grep -cE 'app-(1a|1b|1c)$' || true)
  [[ -z "$n" ]] && n=0
  echo "$n"
}

inventory_entries() {
  kubectl -n flux-system get kustomization kc-1664 -o jsonpath='{range .status.inventory.entries[*]}{.id}{"\n"}{end}' 2>/dev/null
}

orphan_details() {
  kubectl -n kc-1664 get cm -o jsonpath='{range .items[*]}{.metadata.name}{"  deletionTimestamp="}{.metadata.deletionTimestamp}{"  finalizers="}{.metadata.finalizers}{"  managedFields="}{range .metadata.managedFields[*]}{.manager}{","}{end}{"\n"}{end}' 2>/dev/null | grep -E '^app-' || true
}

# --- one scenario run ------------------------------------------------------
# usage: run_scenario <name> <kill-mode>
# kill-modes:
#   none                  no kill
#   before-c-push         kill right before pushing stage C
#   right-after-c-push    kill within 0.5s of pushing stage C
#   during-c-reconcile    kill once Kustomization status is Reconciling
#   after-c-apply         kill after stage C is Ready
#   spam                  kill repeatedly across A/B/C transitions

run_scenario() {
  local name="$1" kill_mode="$2"
  log "scenario: $name (kill-mode=$kill_mode)"
  reset_cluster_state

  # stage A
  git checkout main -q
  write_stage_A
  commit_and_push "feat: reset to stage A layout"

  flux create source git kc-1664 --url="$REPO_URL" --branch=main --interval="$INTERVAL" --namespace=flux-system >/dev/null
  flux create kustomization kc-1664 --source=GitRepository/kc-1664 --path=./manifests --prune=true \
    --interval="$INTERVAL" --target-namespace=kc-1664 --namespace=flux-system --wait=false >/dev/null

  # wait until 4 CMs applied
  for _ in $(seq 1 30); do
    [[ "$(kubectl -n kc-1664 get cm -o name | grep -cE 'app(-1a|-1b|-1c|-flat)$')" -eq 4 ]] && break
    sleep 2
  done
  note "stage A: $(kubectl -n kc-1664 get cm -o name | grep -cE 'app(-1a|-1b|-1c|-flat)$') CMs applied"

  # stage B
  write_stage_B
  commit_and_push "chore: broken intermediate build"
  flux reconcile kustomization kc-1664 -n flux-system --with-source --timeout=30s 2>/dev/null || true
  note "stage B: build error expected"

  # stage C with kill timing
  write_stage_C
  case "$kill_mode" in
    before-c-push)
      kill_kc_pod
      sleep 1
      commit_and_push "feat: consolidation (stage C)"
      ;;
    right-after-c-push)
      commit_and_push "feat: consolidation (stage C)"
      kill_kc_pod
      ;;
    during-c-reconcile)
      commit_and_push "feat: consolidation (stage C)"
      ( for i in $(seq 1 40); do
          if kubectl -n flux-system get kustomization kc-1664 -o jsonpath='{.status.conditions[?(@.type=="Reconciling")].status}' 2>/dev/null | grep -q True; then
            kill_kc_pod
            break
          fi
          sleep 0.25
        done ) &
      flux reconcile kustomization kc-1664 -n flux-system --with-source --timeout=30s 2>/dev/null || true
      wait
      ;;
    after-c-apply)
      commit_and_push "feat: consolidation (stage C)"
      flux reconcile kustomization kc-1664 -n flux-system --with-source --timeout=45s 2>/dev/null || true
      kill_kc_pod
      ;;
    spam)
      ( for _ in $(seq 1 12); do kill_kc_pod; sleep 1.5; done ) &
      commit_and_push "feat: consolidation (stage C)"
      wait
      ;;
    none)
      commit_and_push "feat: consolidation (stage C)"
      ;;
  esac

  kubectl -n flux-system rollout status deploy/kustomize-controller --timeout=60s >/dev/null
  # let things settle: trigger several reconciles
  for _ in 1 2 3; do
    flux reconcile kustomization kc-1664 -n flux-system --with-source --timeout=30s 2>/dev/null || true
    sleep 2
  done

  local orphans
  orphans=$(orphan_count)
  if [[ "$orphans" -gt 0 ]]; then
    fail "$orphans orphan(s) present"
    orphan_details
    echo "  inventory:"
    inventory_entries | sed 's/^/    /'
  else
    pass "no orphans"
  fi
  printf '\n'
}

# --- matrix ---------------------------------------------------------------
declare -a scenarios=(
  "none"
  "before-c-push"
  "right-after-c-push"
  "during-c-reconcile"
  "after-c-apply"
  "spam"
)

declare -a results=()
for s in "${scenarios[@]}"; do
  if run_scenario "$s" "$s" 2>&1 | tee "/tmp/scenario-$s.log"; then
    results+=("$s OK")
  fi
done

echo
echo "============= SUMMARY ============="
for s in "${scenarios[@]}"; do
  orphans_line=$(tail -50 "/tmp/scenario-$s.log" | grep -E "^  (PASS|FAIL)" | head -1)
  printf '%-22s %s\n' "$s" "$orphans_line"
done
