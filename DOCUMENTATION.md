# Ops 5 — Observability & Incident Response Documentation

**Minecraft Server** — k3s on EC2 (t3.medium, us-east-1)

---

## 1. Architecture Diagram

```
                          Internet ──────────► Minecraft Client
                                                    │
                                                    │ TCP 25565
                                                    ▼
┌────────────────────────────────────────────────────────────────┐
│                    AWS EC2 (t3.medium)                         │
│                                                                │
│  ┌──────────────────┐      ┌──────────────────────────────┐   │
│  │  Namespace:       │      │  Namespace: monitoring       │   │
│  │  minecraft        │      │                              │   │
│  │                   │      │  ┌────────────────────────┐  │   │
│  │  ┌─────────────┐  │      │  │  kube-prometheus-stack │  │   │
│  │  │ StatefulSet │  │      │  │                        │  │   │
│  │  │ minecraft-0  │  │      │  │  ┌────┐  ┌──────────┐│  │   │
│  │  │  ┌─────────┐│  │      │  │  │Prom│  │ Grafana  ││  │   │
│  │  │  │Minecraft││  │      │  │  │    │  │(port 80) ││  │   │
│  │  │  │container││  │      │  │  └─┬──┘  └────┬─────┘│  │   │
│  │  │  │ port    ││  │      │  │    │  scrape    │      │  │   │
│  │  │  │ 25565   ││  │      │  └────┼───────────┼──────┘  │   │
│  │  │  └─────────┘│  │      │       │           │         │   │
│  │  │  ┌─────────┐│  │      │       │           │         │   │
│  │  │  │exporter ││  │      │       │  ┌────────┴──────┐  │   │
│  │  │  │mc-monitor││  │      │       │  │  Dashboard   │  │   │
│  │  │  │ port    ││  │      │       │  │  (ConfigMap)  │  │   │
│  │  │  │ 8080    ││  │      │       │  └───────────────┘  │   │
│  │  │  └─────────┘│  │      │       │                     │   │
│  │  └─────────────┘  │      └───────┼─────────────────────┘   │
│  │                   │              │                          │
│  │  ┌─────────────┐  │              │                          │
│  │  │ Service     │  │   ┌──────────▼──────────┐               │
│  │  │ LB :25565   │  │   │    Alertmanager     │               │
│  │  │ metrics:8080│  │   └─────────────────────┘               │
│  │  └─────────────┘  │                                         │
│  │                   │                                         │
│  │  ┌─────────────┐  │                                         │
│  │  │ ServiceMonitor│  │  Prometheus                            │
│  │  │ selects     │  │  ┌─ scapes every 15s                   │
│  │  │ app=minecraft│  │  ├─ retention: 1 day                   │
│  │  │ port=metrics │  │  └─ storage: 2Gi PVC                  │
│  │  └─────────────┘  │                                         │
│  └──────────────────┘                                          │
│                                                                │
│  ┌────────────────────────────────────────────────────────┐   │
│  │                    AWS Integration                      │   │
│  │  ┌──────────────┐          ┌──────────────────────────┐│   │
│  │  │  ECR          │          │  S3 Bucket                ││   │
│  │  │  minecraft-   │          │  ops-3-mc-backups-*      ││   │
│  │  │  server:v1.1.8│          │  └─ backups/             ││   │
│  │  │  (image pull) │          │     ├─ world_backup_latest│   │
│  │  └──────────────┘          │     └─ *_<timestamp>.zip  ││   │
│  │                            └──────────────────────────┘│   │
│  └────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────┘
```

### Components

| Component | Purpose |
|-----------|---------|
| **Minecraft container** | Runs itzg/minecraft-server (Java 25, Minecraft 26.1.2) on port 25565 |
| **mc-monitor exporter** | Sidecar container that queries RCON every 15s and exposes `minecraft_status_players_online_count` and `minecraft_status_healthy` on port 8080 |
| **Prometheus** | Scrapes the exporter via ServiceMonitor, stores 1 day of metrics on a 2Gi PVC |
| **Grafana** | Serves the "Minecraft Operator Dashboard" (UID `mc-op-dash`) via port-forward on `localhost:3000` |
| **Alertmanager** | Evaluates 4 PrometheusRule alerts against scraped metrics |
| **ECR** | Image source for the Minecraft server container |
| **S3** | Backup destination — cron job zips the world directory every 30 minutes |

---

## 2. On-Call Quickstart

### When paged (first 60 seconds)

1. **Check pod status:**
   ```bash
   kubectl get pods -n minecraft
   ```
   - `Running` with `READY 2/2` and `RESTARTS 0` → likely **not** a pod issue.
   - `CrashLoopBackOff` or `READY 0/2` → **pod-level failure**, go to step 2.

2. **Check if the port is reachable (user-visible problem):**
   ```bash
   nmap -sV -Pn -p T:25565 <public-ip>
   ```
   - `25565/tcp open` with MOTD displayed → service is reachable, problem may be upstream.
   - `filtered` or `closed` → problem **is** user-visible.

3. **Check the Grafana dashboard:**
   ```bash
   kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
   # open http://localhost:3000 → Dashboards → Minecraft Operator Dashboard
   ```
   Look at:
   - **Pod Restarts** — non-zero indicates recent crashes.
   - **Server Health** — `0` means the exporter cannot reach Minecraft via RCON.
   - **Players Online** — normally 0 when idle; if >0 and all panels green, the server is fine.
   - **Minecraft Memory Usage** — approaching the limit line signals imminent OOM.

4. **Check container logs:**
   ```bash
   kubectl logs -n minecraft -l app=minecraft --tail=30
   ```
   Last line shows either `Done` (clean startup), a Java exception, or nothing (container crashed before writing).

5. **Check pod events for the root cause:**
   ```bash
   kubectl describe pod -n minecraft -l app=minecraft
   ```
   Look at the `Events:` section and `Containers Status` — `OOMKilled`, `ImagePullBackOff`, or `CrashLoopBackOff` tell you what to fix.

### Telling if the problem is user-visible

| Symptom | User-visible? |
|---------|:---:|
| `nmap` shows port closed or filtered | **Yes** — players cannot connect |
| Pod is `Running` 2/2, `nmap` passes | **No** — server is healthy, investigate upstream (client, DNS, etc.) |
| Pod is crash-looping but `nmap` still shows open (old pod) | **Yes** — any new connections will fail when the old pod terminates |
| `NodeDiskUsageHigh` fires but pod is healthy | **No yet** — risk of future failure, investigate proactively |
| Only `MinecraftHighMemoryUsage` fires | **No yet** — warning threshold, pre-OOM buffer |

---

## 3. Alert Runbooks

### 3.1 `MinecraftPodDown`

**Symptom:** Players cannot connect. The Minecraft pod is not in a Ready state for >1 minute.

**Severity:** Critical

**Threshold justification:** `kube_pod_status_ready{condition="true", pod=~".*minecraft.*"} == 0` for 1m. A 1-minute `for` prevents flapping from brief probe failures while catching real outages promptly.

**First response:**
1. Check the pod status:
   ```bash
   kubectl get pods -n minecraft
   ```
2. Describe the pod to find the root cause:
   ```bash
   kubectl describe pod -n minecraft -l app=minecraft
   ```
   Look for `Events:` at the bottom — common causes: `OOMKilled`, `ImagePullBackOff`, probe failure.
3. Check the container logs:
   ```bash
   kubectl logs -n minecraft -l app=minecraft --tail=50
   ```
4. If the image is missing or broken, roll back:
   ```bash
   helm rollback minecraft -n minecraft
   ```

**Resolution:** Once the underlying issue is fixed, the StatefulSet controller restarts the pod automatically. Confirm with:
```bash
kubectl wait --for=condition=Ready pod -n minecraft -l app=minecraft --timeout=300s
```

---

### 3.2 `MinecraftHighMemoryUsage`

**Symptom:** Server lag, risk of OOM kill. Container memory exceeds 80% of its limit sustained for 5 minutes.

**Severity:** Warning

**Threshold justification:** `container_memory_usage_bytes / container_spec_memory_limit_bytes * 100 > 80` for 5m. The 80% threshold gives a ~300Mi buffer on a 1.5Gi limit before the kernel OOM-kills at 100%. The 5-minute `for` prevents flapping from garbage collection spikes.

**First response:**
1. Check current resource usage:
   ```bash
   kubectl top pod -n minecraft -l app=minecraft
   ```
2. Check if the container has been recently OOM-killed:
   ```bash
   kubectl describe pod -n minecraft -l app=minecraft | grep -A5 "Status:"
   ```
   `OOMKilled` in `lastState` means the limit is too low.
3. Increase memory limits in `helm/minecraft/values.yaml`:
   ```yaml
   resources:
     limits:
       memory: 2Gi
   ```
4. Re-deploy:
   ```bash
   scp -i ~/.ssh/cs312-key.pem helm/minecraft/values.yaml ubuntu@<host>:~/minecraft-chart/
   ssh -i ~/.ssh/cs312-key.pem ubuntu@<host>
   helm upgrade minecraft ~/minecraft-chart -n minecraft
   ```

**Escalation:** If memory grows unbounded over time, investigate a plugin or world corruption issue. Restore from S3 backup if suspected.

---

### 3.3 `MinecraftPodCrashLooping`

**Symptom:** Server repeatedly crashes. More than 2 restarts in 10 minutes.

**Severity:** Critical

**Threshold justification:** `increase(kube_pod_container_status_restarts_total[10m]) > 2`. Two restarts in 10 minutes distinguishes an occasional crash (e.g., a one-off OOM from a spike) from a systematic crash loop that requires operator intervention.

**First response:**
1. Check restart count:
   ```bash
   kubectl get pods -n minecraft
   ```
2. View the previous container's logs (before the crash):
   ```bash
   kubectl logs -n minecraft -l app=minecraft --previous --tail=50
   ```
3. Check events for the pod:
   ```bash
   kubectl get events -n minecraft --field-selector involvedObject.name=<pod-name>
   ```
4. Roll back to the last known-good version:
   ```bash
   helm history minecraft -n minecraft
   helm rollback minecraft <revision> -n minecraft
   ```

**Resolution:** After rollback or config fix, force-delete the stuck pod to trigger a fresh start:
```bash
kubectl delete pod -n minecraft minecraft-0 --force --grace-period=0
```

---

### 3.4 `NodeDiskUsageHigh`

**Symptom:** Risk of world save failure, pod eviction. Disk usage exceeds 80% for 5 minutes.

**Severity:** Warning

**Threshold justification:** `(1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes) * 100 > 80` for 5m. The 20GB root volume fills quickly with container images and logs; 80% leaves room for a world backup before eviction thresholds kick in.

**First response:**
1. SSH to the EC2 host and check disk usage:
   ```bash
   ssh -i ~/.ssh/cs312-key.pem ubuntu@<host-ip>
   df -h
   ```
2. Identify large directories:
   ```bash
   sudo du -sh /var/lib/rancher/k3s/storage/
   sudo du -sh /var/lib/rancher/k3s/agent/containerd/
   ```
3. Prune unused container images:
   ```bash
   k3s crictl rmi --prune
   ```
4. Check backup logs — old backups may accumulate in `/tmp`:
   ```bash
   ls -lah /tmp/world_backup*.zip
   ```

**Prevention:** The k3s install in the Ansible playbook enables aggressive eviction thresholds (`imagefs.available<1%,nodefs.available<1%`). Consider increasing the root volume in `terraform/main.tf` if this fires repeatedly.

---

## 4. Log Locations

| Source | How to Access | Search First For |
|--------|---------------|------------------|
| Minecraft container | `kubectl logs -n minecraft -l app=minecraft --tail=50` | `Done`, `OOM`, `Killed`, `Error`, `Exception` |
| Previous crashed container | `kubectl logs -n minecraft -l app=minecraft --previous --tail=50` | Last lines before crash — `OOMKilled`, `java.lang.OutOfMemoryError` |
| Exporter sidecar | `kubectl logs -n minecraft -l app=minecraft -c exporter` | Connection refused or RCON auth failure |
| Pod events | `kubectl describe pod -n minecraft -l app=minecraft` → `Events:` section | `OOMKilled`, `BackOff`, `FailedMount`, `ImagePullBackOff` |
| Kubernetes cluster events | `kubectl get events -n minecraft` | `Failed`, `Killing`, `Unhealthy` |
| Node system logs | `ssh ubuntu@<host>` → `journalctl -u k3s --no-pager -n 50` | `Out of memory`, `disk pressure` |
| Backup logs | `ssh ubuntu@<host>` → `cat /var/log/mc_backup.log` | `Backup completed` or error messages |

### During an incident, search in this order:

1. **Pod events** — fastest root cause for crashes (`kubectl describe pod`)
2. **Minecraft container logs** — last lines reveal the crash context (`kubectl logs --previous` for terminated containers)
3. **Kubernetes events** — broader cluster issues (`kubectl get events`)
4. **Node system logs** — kernel-level OOM or disk pressure (`journalctl -u k3s`)

---

## 5. Incident Drill Report — Resource Exhaustion

### Scenario

Set an artificially low memory limit (300Mi) on the Minecraft container to trigger an OOM kill, detect the failure via `kubectl describe`, and recover by restoring the limit to 1.5Gi.

### Failure Introduced

Changed `resources.limits.memory` from `1.5Gi` to `300Mi` in `helm/minecraft/values.yaml`, then deployed:
```bash
helm upgrade minecraft ~/minecraft-chart -n minecraft
```

### Detection Path

1. `kubectl get pods -n minecraft` showed `CrashLoopBackOff` with restart count climbing.
2. `kubectl describe pod -n minecraft minecraft-0` showed:
   ```
   Last State: Terminated
   Reason: OOMKilled
   Exit Code: 137
   ```
3. Container logs showed the JVM attempting to allocate a 1G heap (`Setting initial memory to 1G and max to 1G`), which exceeded the 300Mi cgroup limit.

### Recovery Steps

1. Restored `resources.limits.memory` to `1.5Gi` in `values.yaml`.
2. Deployed via `helm upgrade minecraft ~/minecraft-chart -n minecraft`.
3. Force-deleted the stuck pod:
   ```bash
   kubectl delete pod -n minecraft minecraft-0 --force --grace-period=0
   ```
4. Verified pod became `Ready`:
   ```bash
   kubectl wait --for=condition=Ready pod -n minecraft -l app=minecraft --timeout=300s
   ```
5. Confirmed service reachable:
   ```bash
   nmap -sV -Pn -p T:25565 <public-ip>
   ```

### Postmortem

| Item | Notes |
|------|-------|
| **What happened** | Container OOM-killed because JVM heap (1G) exceeded cgroup limit (300Mi) |
| **Detection time** | Immediate — CrashLoopBackOff visible seconds after deploy |
| **Recovery time** | ~2 minutes (redeploy + pod restart + server startup) |
| **Root cause** | Operator error: set memory limit below JVM minimum requirements |
| **Prevention** | Add a pre-commit hook or CI check that validates memory limit ≥ JVM `-Xmx` |
| **What went well** | Alert `MinecraftPodDown` would fire after 1m, `kubectl describe` immediately showed `OOMKilled` |
| **What could improve** | The itzg image auto-detects memory but falls back to 1G default when cgroup detection fails on this JDK — could set `MEMORY=300M` env var to match the limit explicitly |

---

## 6. Repository Link & File Map

**Repository:** `https://github.com/werbyderk/cs312-ops3.git`

```
ops-5/
├── DOCUMENTATION.md                         ← This file
├── RUNBOOK.md                               ← Alert runbooks + operations guide
├── VIDEO_CHECKLIST.md                       ← Step-by-step recording script
├── NETWORK_POLICY.md                        ← Network policy documentation
├── helm/
│   ├── minecraft/                           ← Minecraft Helm chart
│   │   ├── Chart.yaml                       ← Chart metadata (v0.1.0)
│   │   ├── values.yaml                      ← Default values (resources, probes, exporter, image)
│   │   └── templates/
│   │       ├── statefulset.yaml             ← Pod spec: minecraft + exporter sidecar, probes, resources
│   │       ├── service.yaml                 ← LB service: port 25565 + 8080 metrics
│   │       ├── servicemonitor.yaml          ← Prometheus ServiceMonitor (app=minecraft, port=metrics)
│   │       ├── configmap.yaml               ← Server properties ConfigMap
│   │       ├── networkpolicy.yaml           ← Ingress/egress policy
│   │       ├── pvc.yaml                     ← PersistentVolumeClaim (10Gi local-path)
│   │       └── _helpers.tpl                 ← Helm template helpers
│   └── monitoring/                          ← kube-prometheus-stack overrides
│       ├── values.yaml                      ← Prometheus/Grafana/Alertmanager config + 4 alert rules
│       └── dashboards/
│           └── minecraft-dashboard.json     ← Grafana dashboard JSON (6 panels, UID mc-op-dash)
├── ansible/
│   ├── minecraft.yml                        ← Main playbook: k3s install, monitoring, Helm deploy
│   ├── backup_world.yml                     ← Manual backup trigger
│   ├── restore_world.yml                    ← S3 restore (scale down, pull, extract, scale up)
│   ├── inventory.ini                        ← Generated by Terraform
│   └── vars/
│       └── main.yml                         ← Ansible vars (namespaces, region, ports)
├── terraform/
│   ├── main.tf                              ← VPC, SG, EC2, ECR, S3, Ansible trigger
│   ├── variables.tf                         ← Input variables
│   ├── outputs.tf                           ← Outputs (public IP, bucket name)
│   └── terraform.tfvars                     ← Variable values
└── assignment.md                            ← Assignment description
```

### Key Alert Definitions

File: `helm/monitoring/values.yaml` lines 69–131

| Alert | Expression | Severity | Runbook |
|-------|-----------|----------|---------|
| MinecraftPodDown | `kube_pod_status_ready{..., pod=~".*minecraft.*"} == 0` for 1m | critical | §3.1 |
| MinecraftHighMemoryUsage | `container_memory_usage_bytes{..., container="minecraft"} / container_spec_memory_limit_bytes * 100 > 80` for 5m | warning | §3.2 |
| MinecraftPodCrashLooping | `increase(kube_pod_container_status_restarts_total{..., container="minecraft"}[10m]) > 2` | critical | §3.3 |
| NodeDiskUsageHigh | `(1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes) * 100 > 80` for 5m | warning | §3.4 |

---

## 7. Cost Controls

### Tear Down

To stop all costs, run from the local machine:
```bash
cd terraform
terraform destroy -auto-approve
```

This deletes the EC2 instance (and its EBS root volume), the S3 bucket (`force_destroy = true`), and the ECR repository (`force_delete = true`).

To tear down **monitoring only** (keep Minecraft running):
```bash
kubectl delete namespace monitoring
```
This removes Prometheus, Grafana, Alertmanager, their PVCs, and all alert rules.

### Retention & Storage Limits

| Component | Guardrail | Rationale |
|-----------|-----------|-----------|
| Prometheus metrics | `retention: 1d`, `storage: 2Gi PVC` | Lab environment — 1 day is sufficient for drill review; 2Gi prevents disk from filling |
| Grafana | `persistence.size: 1Gi` | Dashboard JSON is tiny (~3KB); 1Gi is more than enough for a single dashboard |
| Prometheus resources | `limits: 512Mi memory`, `limits: 500m cpu` | Prevents monitoring from starving the Minecraft workload on t3.medium |
| Node disk | `eviction-hard=imagefs.available<1%,nodefs.available<1%` | k3s aggressively evicts before disk-full; unused images can be pruned via `k3s crictl rmi --prune` |
| Root volume | 20GB gp3 | Chosen to fit monitoring + Minecraft + container images; upgrade to 30GB if alerts fire frequently |

### Scheduling

- The EC2 instance runs 24/7 during the assignment period.
- To stop non-work hours:
  ```bash
  # Stop the instance (reduces cost to EBS-only ~$0.08/day)
  ssh -i ~/.ssh/cs312-key.pem ubuntu@<host> sudo shutdown -h now
  # Start via AWS Console when needed
  ```
- To pause monitoring only (keep Minecraft up):
  ```bash
  kubectl scale deployment -n monitoring prometheus-kube-prometheus-kube-state-metrics --replicas=0
  kubectl scale deployment -n monitoring prometheus-grafana --replicas=0
  kubectl scale statefulset -n monitoring prometheus-prometheus --replicas=0
  # Restart with --replicas=1 when needed
  ```
- The S3 backup cron job runs every 30 minutes; this costs pennies per month in PUT requests.
