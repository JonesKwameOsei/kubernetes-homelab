# Kubernetes Homelab

A production-grade, bare-metal Kubernetes homelab cluster built on Debian 13. Deployed with shell scripts and Helm, managed declaratively through GitOps via Argo CD, and equipped with a full observability, security, and autoscaling stack.

---

## Table of Contents

- [Architecture](#architecture)
- [Stack Overview](#stack-overview)
- [Directory Structure](#directory-structure)
- [Prerequisites](#prerequisites)
- [Deployment Guide](#deployment-guide)
- [Service Access](#service-access)
- [GitOps with Argo CD](#gitops-with-argo-cd)
- [Retrieving Credentials](#retrieving-credentials)
- [Configuration Reference](#configuration-reference)

---

## Architecture

### Cluster Topology

| Role | Hostname | Notes |
|---|---|---|
| Control Plane | `<CONTROL_PLANE_HOST>` | kubeadm init, kubectl, Helm |
| Worker Node 1 | `<WORKER_NODE_1_HOST>` | Joined via kubeadm |
| Worker Node 2 | `<WORKER_NODE_2_HOST>` | Joined via kubeadm |

- **OS:** Debian 13 (Trixie) — bare-metal
- **Kubernetes:** v1.35.3
- **Container runtime:** containerd (systemd cgroup driver)
- **CNI:** Cilium v1.19.2 in kube-proxy replacement mode
- **Ingress:** Cilium Gateway API (Gateway API v1.2.1)
- **Load balancer:** MetalLB (L2 mode, LAN IP pool)
- **Storage:** Longhorn v1.11.1 (distributed block storage)
- **Pod CIDR:** `10.244.0.0/16`

### Network Flow

```
Client (LAN)
    │
    ▼
MetalLB LoadBalancer IP  ←── single external IP from the LAN pool
    │
    ▼
Cilium Gateway (homelab-gateway)
    │
    ├── HTTPRoute → Argo CD
    ├── HTTPRoute → Grafana
    ├── HTTPRoute → Prometheus
    ├── HTTPRoute → Alertmanager
    ├── HTTPRoute → Longhorn UI
    └── HTTPRoute → KubeView
```

---

## Stack Overview

### Networking

| Component | Namespace | Version | Purpose |
|---|---|---|---|
| Cilium | `kube-system` | 1.19.2 | CNI, kube-proxy replacement, Gateway API controller, Hubble observability |
| MetalLB | `metallb-system` | latest | Assigns LAN IPs to `LoadBalancer` services (L2 mode) |
| Gateway API CRDs | `kube-system` | v1.2.1 | Standard Gateway API resources consumed by Cilium |

### Storage

| Component | Namespace | Version | Purpose |
|---|---|---|---|
| Longhorn | `longhorn-system` | 1.11.1 | Distributed block storage with built-in replication and UI |

### TLS & Certificates

| Component | Namespace | Purpose |
|---|---|---|
| cert-manager | `cert-manager` | Automates TLS certificate provisioning and renewal |

### GitOps

| Component | Namespace | Purpose |
|---|---|---|
| Argo CD | `argocd` | Declarative GitOps continuous delivery (App-of-Apps pattern) |

### Monitoring & Observability

| Component | Namespace | Purpose |
|---|---|---|
| kube-prometheus-stack | `monitoring` | Prometheus + Alertmanager + Grafana — full metrics pipeline |
| Prometheus Adapter | `monitoring` | Bridges Prometheus → Kubernetes Metrics API; replaces `metrics-server` |

### Log Aggregation

| Component | Namespace | Purpose |
|---|---|---|
| Loki | `monitoring` | Log aggregation in SingleBinary mode (filesystem storage) |
| Promtail | `monitoring` | Log collector — ships node and pod logs to Loki |

### Security

| Component | Namespace | Purpose |
|---|---|---|
| Kyverno | `kyverno` | Policy engine and admission controller |
| Falco | `falco` | Runtime security — detects anomalous behaviour via `modern_ebpf` driver |
| Trivy Operator | `trivy-system` | Continuous vulnerability and configuration audit scanning |

### Autoscaling

| Component | Namespace | Purpose |
|---|---|---|
| KEDA | `keda` | Event-driven autoscaling on Prometheus metrics, queues, HTTP traffic, etc. |
| Prometheus Adapter | `monitoring` | Exposes custom + external metrics to the Kubernetes HPA |

### Visualisation

| Component | Namespace | Purpose |
|---|---|---|
| KubeView | `kubeview` | Real-time visual map of cluster resources |
| Hubble UI | `kube-system` | Cilium network flow visualisation (bundled with Cilium) |

---

## Directory Structure

```
kubernetes-homelab/
├── control-plane/
│   ├── 01-prepare-os.sh          # OS hardening, kernel params, containerd — run on ALL nodes
│   ├── 02-install-kubernetes.sh  # kubeadm, kubelet, kubectl install — run on ALL nodes
│   ├── control-plane.sh          # kubeadm init (kube-proxy skipped for Cilium)
│   ├── 04-install-cilium.sh      # Cilium CNI + Gateway API + Hubble
│   ├── 05-verify.sh              # Cluster health check — nodes, Cilium, system pods
│   ├── 06-gateway-setup.sh       # GatewayClass + Gateway resource (MetalLB-assigned IP)
│   ├── 07-argocd-gitops.sh       # Argo CD App-of-Apps bootstrap
│   ├── addons.sh                 # All Helm addons (MetalLB → KubeView)
│   └── homelab-gitops/           # GitOps repository (watched by Argo CD)
│       ├── apps/                 # Argo CD Application manifests (App-of-Apps root)
│       └── manifests/            # Application manifests synced by Argo CD
└── worker-node/
    ├── 01-prepare-os.sh          # Same OS prep as control-plane version
    ├── 02-install-kubernetes.sh  # Same k8s package install
    └── worker-nodes.sh           # kubeadm join — fill in token, hash, and IP before running
```

---

## Prerequisites

### All Nodes

- Debian 13 (Trixie) — bare-metal or VM
- Minimum: 2 vCPU, 4 GB RAM, 40 GB disk per node
- Static LAN IP addresses assigned to each node
- SSH access as a user with `sudo` privileges

### Control Plane Only

- A free IP range on your LAN **outside** your router's DHCP range (for MetalLB)
- A Git repository to serve as the GitOps source for Argo CD

### Longhorn Prerequisite (all nodes — before running `addons.sh`)

```bash
sudo apt-get install -y open-iscsi nfs-common
```

---

## Deployment Guide

### Step 1 — Prepare OS (all nodes)

Run on **every** node (control plane and workers):

```bash
sudo bash 01-prepare-os.sh [--node-name <hostname>]
sudo bash 02-install-kubernetes.sh
```

This script handles: swap disable, kernel modules (`overlay`, `br_netfilter`), sysctl tuning, time sync (chrony), and containerd installation with the systemd cgroup driver.

> **WSL2 note:** The script detects WSL2 automatically and prints the additional manual steps required (port forwarding, static IP, systemd enablement).

---

### Step 2 — Initialise the Control Plane

Run on the **control plane node only**:

```bash
sudo bash control-plane.sh
```

This runs `kubeadm init` with kube-proxy skipped (Cilium takes over), sets up kubeconfig, and prints the `kubeadm join` command. **Save that join command** — you will need it for Step 5.

---

### Step 3 — Install Cilium CNI

Run on the **control plane node**:

```bash
sudo bash 04-install-cilium.sh
```

Installs the Cilium CLI, applies Gateway API CRDs, then installs Cilium with:

- `kubeProxyReplacement=true`
- `gatewayAPI.enabled=true`
- `hubble.relay.enabled=true` + `hubble.ui.enabled=true`
- Prometheus metrics enabled

---

### Step 4 — Install All Addons

Edit `addons.sh` and set `METALLB_IP_RANGE` to a free IP range on your LAN:

```bash
METALLB_IP_RANGE="<LAN_IP_START>-<LAN_IP_END>"
```

Then run:

```bash
sudo bash control-plane/addons.sh
```

This installs (in order): MetalLB → Longhorn → cert-manager → Argo CD → kube-prometheus-stack → Loki → Promtail → Kyverno → Falco → Trivy Operator → Prometheus Adapter → KEDA → KubeView.

---

### Step 5 — Join Worker Nodes

On **each worker node**, edit `worker-node/worker-nodes.sh` and fill in the values from the `kubeadm join` output printed in Step 2:

```bash
CONTROL_PLANE_IP=""   # IP address of the control plane node
JOIN_TOKEN=""         # Token from kubeadm join output
CA_CERT_HASH=""       # sha256:... hash from kubeadm join output
```

> To regenerate the join command at any time, run on the control plane:
> ```bash
> kubeadm token create --print-join-command
> ```

Then run on each worker:

```bash
sudo bash worker-nodes.sh
```

---

### Step 6 — Verify Cluster Health

Run on the **control plane**:

```bash
bash 05-verify.sh
```

Expected output: all nodes `Ready`, Cilium status `OK`, GatewayClass `cilium` with `ACCEPTED=True`, no non-Running pods.

---

### Step 7 — Configure the Gateway

```bash
bash 06-gateway-setup.sh
```

Creates the `cilium` GatewayClass and a single cluster-wide `homelab-gateway` Gateway. MetalLB assigns it one external LAN IP. All services are routed through HTTPRoutes pointing at this Gateway.

---

### Step 8 — Bootstrap Argo CD GitOps

Edit `07-argocd-gitops.sh` and set your GitOps repo URL:

```bash
ARGOCD_REPO_URL="<YOUR_GITOPS_REPO_URL>"
```

Then run:

```bash
bash 07-argocd-gitops.sh
```

This exposes the Argo CD UI via an HTTPRoute, registers your Git repository, and creates the root App-of-Apps application with automated sync, auto-prune, and self-heal enabled.

---

## Service Access

All services are exposed through the Cilium Gateway. Add the Gateway's external IP (assigned by MetalLB) to your `/etc/hosts` or local DNS:

```
<GATEWAY_IP>  argocd.<YOUR_DOMAIN> grafana.<YOUR_DOMAIN> prometheus.<YOUR_DOMAIN> alertmanager.<YOUR_DOMAIN> longhorn.<YOUR_DOMAIN> kubeview.<YOUR_DOMAIN>
```

| Service | Default Hostname | Purpose |
|---|---|---|
| Argo CD | `argocd.<YOUR_DOMAIN>` | GitOps UI |
| Grafana | `grafana.<YOUR_DOMAIN>` | Metrics dashboards |
| Prometheus | `prometheus.<YOUR_DOMAIN>` | Metrics query UI |
| Alertmanager | `alertmanager.<YOUR_DOMAIN>` | Alert routing UI |
| Longhorn | `longhorn.<YOUR_DOMAIN>` | Storage management UI |
| KubeView | `kubeview.<YOUR_DOMAIN>` | Cluster visualisation |

### Argo CD

> **Screenshot:** *(place your Argo CD UI screenshot at `docs/images/argocd.png`)*

![Argo CD UI](docs/images/argocd.png)

---

### Grafana

> **Screenshot:** *(place your Grafana dashboard screenshot at `docs/images/grafana.png`)*

![Grafana Dashboard](docs/images/grafana.png)

---

### Prometheus

> **Screenshot:** *(place your Prometheus UI screenshot at `docs/images/prometheus.png`)*

![Prometheus UI](docs/images/prometheus.png)

---

### Longhorn

> **Screenshot:** *(place your Longhorn UI screenshot at `docs/images/longhorn.png`)*

![Longhorn Storage UI](docs/images/longhorn.png)

---

### KubeView

> **Screenshot:** *(place your KubeView screenshot at `docs/images/kubeview.png`)*

![KubeView Cluster Map](docs/images/kubeview.png)

---

## GitOps with Argo CD

The cluster follows the **App-of-Apps** pattern. Argo CD watches the `apps/` directory of your GitOps repository. Each file in `apps/` is an Argo CD `Application` manifest pointing at a subdirectory of `manifests/`.

```
homelab-gitops/
├── apps/
│   ├── app-one.yaml        # Argo CD Application manifest
│   └── app-two.yaml
└── manifests/
    ├── app-one/
    │   └── deployment.yaml
    └── app-two/
        └── deployment.yaml
```

**Example Application manifest** (`apps/my-app.yaml`):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: <YOUR_GITOPS_REPO_URL>
    targetRevision: HEAD
    path: manifests/my-app
  destination:
    server: https://kubernetes.default.svc
    namespace: my-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

**Example HTTPRoute** (to expose a GitOps-managed app):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: my-app
spec:
  parentRefs:
  - name: homelab-gateway
    namespace: kube-system
  hostnames:
  - "my-app.<YOUR_DOMAIN>"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: my-app-service
      port: 80
```

---

## Retrieving Credentials

**Argo CD admin password:**

```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

Change immediately after first login:

```bash
argocd account update-password
```

**Grafana admin password:**

```bash
kubectl get secret prometheus-grafana -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo
```

---

## Configuration Reference

| Variable | Script | Description |
|---|---|---|
| `METALLB_IP_RANGE` | `addons.sh` | Free LAN IP range for MetalLB LoadBalancer services |
| `ARGOCD_REPO_URL` | `07-argocd-gitops.sh` | Git repository URL for Argo CD to watch |
| `CONTROL_PLANE_IP` | `worker-nodes.sh` | IP address of the control plane node |
| `JOIN_TOKEN` | `worker-nodes.sh` | kubeadm bootstrap token |
| `CA_CERT_HASH` | `worker-nodes.sh` | kubeadm CA certificate hash (`sha256:...`) |
| `K8S_VERSION` | `control-plane.sh` | Kubernetes version to initialise with |
| `CILIUM_VERSION` | `04-install-cilium.sh` | Cilium release to install |
| `GATEWAY_API_VERSION` | `04-install-cilium.sh` | Gateway API CRD version |

### Key Design Decisions

- **Cilium replaces kube-proxy** — `kubeadm init` is run with `--skip-phases=addon/kube-proxy`; do not add a kube-proxy DaemonSet.
- **Falco uses `modern_ebpf` driver** — works on Debian 13 / Linux kernel 6.x without needing kernel headers.
- **Loki runs in `SingleBinary` mode** with filesystem storage — appropriate for a homelab; not highly available.
- **Prometheus Adapter replaces `metrics-server`** — bridges Prometheus → Kubernetes Metrics API, enabling HPA on any Prometheus metric.
- **Loki multi-tenancy is enabled** — all Loki API calls require the `X-Scope-OrgID` header.
- **Single Gateway for all services** — one MetalLB IP, all traffic routed via HTTPRoutes hanging off `homelab-gateway`.
