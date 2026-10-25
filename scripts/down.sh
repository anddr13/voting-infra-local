#!/usr/bin/env bash
# Deletes the kind cluster and its kubeconfig file. Nothing outside that file is touched.
set -euo pipefail

CLUSTER=voting-local
kubeconfig="$HOME/.kube/kind-$CLUSTER.yaml"
if command -v cygpath > /dev/null; then kubeconfig=$(cygpath -m "$kubeconfig"); fi # Git Bash on Windows

kind delete cluster --name "$CLUSTER" --kubeconfig "$kubeconfig"
rm -f "$kubeconfig"
