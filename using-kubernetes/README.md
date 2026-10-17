# E-commerce demo on local Kubernetes (kind + Helm)

The same polyglot shop as the Docker Compose version, rebuilt for Kubernetes.
This folder is self-contained: it has its own copy of the application code
and shares nothing with the Docker version.

| Layer | Tool |
|---|---|
| Cluster | kind — 1 control-plane + 2 workers (Kubernetes v1.35) |
| Front door | Traefik 3.7 (Helm chart 41.6.0) with the Kubernetes **Gateway API** v1.6.1 |
| Shop | Umbrella Helm chart `charts/ecommerce` (9 sub-charts + 1 library chart) — namespace `shop` |
| Middleware | Helm chart `charts/middleware`: Postgres, MongoDB, Redis, RabbitMQ — namespace `middleware` |
| Observability | Helm charts: kube-prometheus-stack, Loki + Alloy, Jaeger, OpenTelemetry Operator — *phase 4* |
| New Relic | OTel export (+ optional nri-bundle) — *phase 5* |

> ingress-nginx was retired in March 2026, so this project uses the Gateway API
> (Gateway + HTTPRoute objects) instead of the older Ingress API.

## Layout

```
docs/OBSERVABILITY.md                           observability (open source + New Relic) in detail
docs/K8s_Project_and_Observability_Guide.docx   walkthrough of every folder/file + observability settings explained
docs/NewRelic_APM_Kubernetes_Setup.docx         New Relic APM (option A) setup, operations, troubleshooting
cluster/kind-config.yaml               3-node cluster, Mac ports 80/443 -> control-plane node
platform/gateway-api-v1.6.1-standard.yaml   Gateway API CRDs (pinned copy)
platform/traefik-values.yaml           Traefik settings (hostPort 80/443, shared Gateway "main")
scripts/build-images.sh                build all images + `kind load` them into the cluster
charts/ecommerce/                      the shop as an umbrella Helm chart (see below)
services/                              application source (copied from the Docker version)
observability/grafana-dashboards/      dashboards carried over from the Docker version
```

## Phase 1 — cluster + front door

Prerequisites: Docker Desktop (10–12 GB memory recommended), `kind`, `kubectl`,
`helm` (`brew install kind kubectl helm k9s`). Stop the Docker Compose version
first — both use the same memory.

```bash
kind create cluster --config cluster/kind-config.yaml
kubectl wait --for=condition=Ready nodes --all --timeout=180s

kubectl apply --server-side -f platform/gateway-api-v1.6.1-standard.yaml
helm repo add traefik https://traefik.github.io/charts && helm repo update
helm upgrade --install traefik traefik/traefik --version 41.6.0 \
  -n traefik --create-namespace -f platform/traefik-values.yaml --wait

kubectl get gateway -n traefik          # main  traefik  PROGRAMMED=True
curl -i http://localhost/               # 404 from Traefik = front door works, no routes yet
```

Delete everything: `kind delete cluster --name ecommerce`

### Gotchas met while building this
- Traefik 3.7 needs Gateway API **v1.6.x** CRDs (it watches TLSRoute, which v1.4 lacks).
- The Traefik chart sets the Service type under `service.spec.type`; leaving it as
  LoadBalancer makes `helm --wait` hang forever on kind (no cloud load balancer).
- hostPort 80 fits one pod per node, so upgrades use `maxSurge: 0` (stop old, start new).

## Namespaces

| Namespace | Contents | Helm release |
|---|---|---|
| `shop` | 7 services, frontend, loadgen | `shop` (charts/ecommerce) |
| `middleware` | Postgres, MongoDB, Redis, RabbitMQ | `middleware` (charts/middleware) |
| `observability` | Prometheus, Grafana, Loki, Jaeger, OTel (phase 4) | one release per tool |
| `traefik` | Front door (Gateway API) | `traefik` |

A Helm release lives in one namespace, so each layer is its own release.
Services reach the middleware by full DNS name (`postgres.middleware.svc.cluster.local`),
set once in `global.hosts` (charts/ecommerce/values.yaml) and rendered into each
service's env with Helm's `tpl`. Secrets are per namespace, so both charts carry
the same credentials values.

## Phase 2 + 3 — the shop as Helm charts

```
charts/middleware/                Postgres, MongoDB, RabbitMQ (StatefulSets + volumes), Redis
                                  + its own credentials Secret   (release: middleware, ns: middleware)
charts/ecommerce/                 umbrella chart (release name: shop, namespace: shop)
├── Chart.yaml                    lists every sub-chart + `condition: <name>.enabled`
├── values.yaml                   global settings, shared credentials, on/off switches
├── values-kind.yaml              overrides for the local kind cluster
├── templates/secret.yaml         one Secret with DB / RabbitMQ credentials
├── templates/NOTES.txt           printed after install
└── charts/
    ├── ecommerce-common/         LIBRARY chart: the Deployment + Service template
    │                             (probes, wait-for init containers, OTEL_* env,
    │                              k8s pod attributes, resources) used by every service
    ├── api-gateway/  product-service/  cart-service/  order-service/
    ├── payment-service/  inventory-service/  notification-service/
    │                             each = Chart.yaml + values.yaml + 1-line template
    ├── frontend/                 nginx ConfigMap + HTTPRoute (shop.localhost)
    └── loadgen/                  fake shoppers (scale to 0 to pause)
```

Deploy:

```bash
scripts/build-images.sh                    # build 9 images, load into kind (~5 min first time)
helm upgrade --install middleware charts/middleware -n middleware --create-namespace --wait
helm upgrade --install shop charts/ecommerce -n shop --create-namespace \
  -f charts/ecommerce/values.yaml -f charts/ecommerce/values-kind.yaml --wait --timeout 10m
kubectl -n middleware get pods             # 4 data stores
kubectl -n shop get pods                   # 9 app pods
open http://shop.localhost
```

### Everyday Helm
| Goal | Command |
|---|---|
| See what would change | `helm template shop charts/ecommerce -n shop -f ... \| less` |
| Check the chart | `helm lint charts/ecommerce -f charts/ecommerce/values.yaml` |
| Release history / roll back | `helm history shop -n shop` · `helm rollback shop 1 -n shop` |
| Scale a service | `--set cart-service.replicas=3` |
| Pause fake orders | `--set loadgen.replicas=0` (or `kubectl -n shop scale deploy/loadgen --replicas=0`) |
| Switch a part off | `--set loadgen.enabled=false` |
| Rebuild one service after a code change | `scripts/build-images.sh cart-service-node` then `kubectl -n shop rollout restart deploy/cart-service` |
| Remove the shop | `helm uninstall shop -n shop` · `helm uninstall middleware -n middleware` (volumes stay: `kubectl -n middleware delete pvc --all`) |

### Kubernetes ideas used here
- **No depends_on** in Kubernetes → each service has `wait-for-*` init containers (`waitFor:` in values).
- **Probes** → startupProbe (slow JVM start), readinessProbe (in/out of the Service), livenessProbe (restart if stuck).
- **StatefulSets + volumeClaimTemplates** → each database keeps its data across pod restarts.
- **Headless Services** → `postgres.middleware.svc.cluster.local` resolves straight to the pod.
- **`tpl` in values** → `"{{ .Values.global.hosts.postgres }}"` inside a service's values is rendered by the library chart.
- **Secret + `$(VAR)` expansion** → `RABBITMQ_URL` is built from the secret's user/password.
- **Downward API** → pod, namespace and node names go into `OTEL_RESOURCE_ATTRIBUTES` (ready for phase 4).
- **ConfigMap checksum annotation** → editing the nginx config restarts the frontend automatically.

### Gotchas met in phase 2/3
- order-service's health endpoint is `/orders/health` (controller mapped under `/orders`).
- nginx resolving at request time (`resolver` + variables) needs full DNS names
  (`api-gateway.shop.svc.cluster.local`); short names only work for names fixed at startup.
- Keep sub-charts as folders: `helm dependency update` would also drop `.tgz` copies next to them.
- macOS ships bash 3.2 (no associative arrays) — scripts here avoid bash-4 features.

## Phase 5 — New Relic APM (option A: OpenTelemetry export)

The OTel gateway collector sends the same traces (and the services' own metrics)
to New Relic EU as well as to Jaeger/Prometheus. No app or image changes.

```bash
# 1. license key as a Secret (once; never put it in values files)
kubectl -n observability create secret generic newrelic-license \
  --from-literal=NEW_RELIC_LICENSE_KEY=<ingest license key>
# 2. switch is newrelic.enabled in charts/observability-config/values.yaml
helm upgrade obs-config charts/observability-config -n observability
```

What the collector does when `newrelic.enabled: true`:
- `traces/newrelic` pipeline: spans → `otlp_http/newrelic` (gzip, `api-key` header from the Secret)
- `metrics/newrelic` pipeline: app metrics → `cumulative_to_delta` → New Relic (span metrics stay Prometheus-only;
  New Relic derives its own RED metrics from spans)
- `resource/cluster`: adds `k8s.cluster.name=kind-ecommerce`; `k8s_attributes` adds pod / node / deployment

Check: collector counters `otelcol_exporter_sent_spans{exporter="otlp_http/newrelic"}` (port 8888);
New Relic → APM & Services → OpenTelemetry; NRQL `FROM Span SELECT count(*) FACET service.name, k8s.pod.name`.
Turn off: `newrelic.enabled: false` + the same helm upgrade.
