#!/usr/bin/env bash
# Local stand-in for voting-infra-{azure,aws,gcp}: a kind cluster, Argo CD and the same "root"
# Application, pointed at envs/local.yaml. Everything else comes from voting-gitops, as in the clouds.
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=voting-local
ARGOCD_CHART_VERSION=10.10.5
ARGOCD_APPS_CHART_VERSION=2.0.7
URL=http://localhost:8090

# The cluster gets its own kubeconfig file; ~/.kube/config and its current context are never touched.
kubeconfig="$HOME/.kube/kind-$CLUSTER.yaml"
if command -v cygpath > /dev/null; then kubeconfig=$(cygpath -m "$kubeconfig"); fi # Git Bash on Windows
export KUBECONFIG="$kubeconfig"

if ! kind get clusters 2> /dev/null | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER" --config kind.yaml --kubeconfig "$KUBECONFIG"
fi
kind export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG"

context=$(kubectl config current-context)
if [ "$context" != "kind-$CLUSTER" ]; then
  echo "Refusing to continue: kubectl context is '$context', expected 'kind-$CLUSTER'." >&2
  exit 1
fi

helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm \
  --version "$ARGOCD_CHART_VERSION" --namespace argocd --create-namespace \
  --values argocd-values.yaml --wait --timeout 15m
helm upgrade --install root-app argocd-apps --repo https://argoproj.github.io/argo-helm \
  --version "$ARGOCD_APPS_CHART_VERSION" --namespace argocd --values root-app.yaml

echo "Argo CD is syncing voting-gitops: traefik/keda/strimzi -> data -> voting (~10 minutes)."
for i in $(seq 1 120); do
  if curl -fsS --max-time 5 "$URL/api/results" > /dev/null 2>&1; then
    echo
    echo "The app is up: $URL"
    echo "kubectl access: export KUBECONFIG=$KUBECONFIG"
    exit 0
  fi
  if ((i % 6 == 0)); then
    kubectl -n argocd get applications --no-headers 2> /dev/null | awk '{printf "  %-8s %-10s %s\n", $1, $2, $3}'
    echo
  fi
  sleep 10
done

echo "The app did not come up in 20 minutes." >&2
kubectl -n argocd get applications >&2 || true
kubectl -n voting get pods >&2 || true
exit 1
