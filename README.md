# voting-infra-local

The free, local stand-in for `voting-infra-{azure,aws,gcp}`: a [kind](https://kind.sigs.k8s.io/) cluster with
Argo CD and the same `root` Application the cloud stacks create. Argo CD then deploys everything from
[voting-gitops](https://github.com/anddr13/voting-gitops) as in the clouds: Traefik, KEDA, Strimzi,
CloudNativePG, Kafka, Redis, PostgreSQL and the [voting-app](https://github.com/anddr13/voting-app) services.

Use it to check a change to the charts end to end before paying for a cloud cluster. It is also the stand that
[ai-sre-agent](https://github.com/anddr13/ai-sre-agent) breaks and investigates, so on top of the clouds it gets
monitoring (kube-prometheus-stack, Loki, Alloy), three Kafka nodes and the alert rules.

| | Clouds | Here |
|---|---|---|
| Cluster | AKS / EKS / GKE via Terraform | kind, 1 node, in Docker |
| Argo CD install | `helm_release` in `infra/argocd.tf` | `helm upgrade --install`, same values (`argocd-values.yaml`) |
| GitOps branch | `main` | `lab`: `main` plus the chaos scenarios' commits and their reverts |
| GitOps overrides | `envs/<cloud>.yaml` | `envs/local.yaml`: Traefik on NodePort 30080 → `localhost:8090`, monitoring, 3 Kafka nodes, alerts |
| Cost | ~$0.09–0.23/h | $0 |

## Requirements

Docker with ≈10 GiB of memory for the stack (with monitoring and 3 Kafka nodes it uses about 7–9 GiB; on Windows set
`memory=12GB` in `%UserProfile%\.wslconfig`), `kind`, `helm`, `kubectl`, `bash` (Git Bash on Windows works).

## Usage

```bash
scripts/up.sh      # ~10-15 minutes on the first run; prints http://localhost:8090 when the app answers
scripts/down.sh    # deletes the cluster
```

kubectl access:

```bash
export KUBECONFIG=~/.kube/kind-voting-local.yaml
kubectl -n argocd get applications                     # waves: traefik/keda/strimzi → data → voting
kubectl -n voting get kafka,kafkatopic,pods
kubectl -n voting get scaledobject,hpa -w              # in another terminal run the k6 test (below)
kubectl -n argocd port-forward svc/argocd-server 8443:443
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

Grafana (metrics and Loki logs, no login on this local stand): http://grafana.localhost:8090

Load test, to watch KEDA scale the worker on Kafka consumer lag:

```bash
# straight to the node's NodePort on the kind docker network
docker run --rm -i --network kind -e BASE_URL=http://voting-local-control-plane:30080 \
  grafana/k6:2.3.0 run - < ../voting-app/loadtest/votes.js
```

## Results (measured 2026-10-26)

Laptop, Docker Desktop with 16 CPUs / 7.6 GiB, kind v0.33 (Kubernetes 1.37), worker `PROCESSING_DELAY_MS=20`.
Measured before the move to PostgreSQL, monitoring and three Kafka nodes, with one broker and MongoDB.

**Cold start:** `scripts/up.sh` from nothing to the app answering on `localhost:8090` took **5 min 23 s**
(kind cluster, Argo CD, then the waves: Traefik/KEDA/Strimzi → Kafka/Redis/MongoDB → app).
With monitoring, CloudNativePG and three Kafka nodes it takes about 10 minutes.

**Load:** k6 at 200 votes/s for 3 minutes, each request from a different client id.

| Time | Worker replicas | Consumer lag |
|---|---|---|
| start | 1 | 124 |
| +18 s | 4 | 2,759 |
| +37 s | **6** (max = partitions) | 3,215 |
| end of load | 6 | 9,251 (peak) |
| +1 min after the load | 6 | **0**, backlog drained |
| +5 min | **1** (default HPA scale-down stabilisation) | 0 |

- **35,578** requests, 100% answered `202`, 0 failed, p95 **12 ms**.
- **Exactly once:** MongoDB holds **35,581** votes = 35,578 from k6 + 3 manual ones; the tallies match the API
  (cat 17,861 + dog 17,720). DLQ: 0 messages.
- **Throughput ceiling ≈ 125 votes/s.** The worker cannot scale past the 6 partitions of `votes`, and with the
  artificial 20 ms delay each one handles ~45 ms per message, so the backlog grew during the test and drained right after it.
  Going higher means more partitions, batch processing (`eachBatch`) or several partitions in flight per worker.
- **Bug caught here, not in a paid cluster:** KEDA could not reach Kafka because the `ScaledObject` used the short
  service name, which does not resolve from KEDA's own namespace. Fixed in voting-gitops by qualifying it as
  `voting-kafka-bootstrap.voting.svc`.

## Safety

The cluster lives in its own kubeconfig file (`~/.kube/kind-voting-local.yaml`): the scripts never read or modify
`~/.kube/config` or switch its current context, and `up.sh` refuses to install anything unless kubectl points at
`kind-voting-local`.
