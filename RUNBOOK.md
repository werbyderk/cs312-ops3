# Minecraft Server Runbook & Operations Guide

This document provides instructions for deploying, operating, and maintaining the Minecraft server on k3s, along with architectural justifications and cost management.

---

## 1. Runbook

### Deployment Procedure
The infrastructure and application are deployed using a "one-touch" Terraform command that triggers Ansible for configuration.
1.  **Initialize Terraform:** `cd terraform && terraform init`
2.  **Deploy:** `terraform apply`
    *   This provisions the EC2 instance, VPC, Security Groups, ECR, and S3 bucket.
    *   It automatically triggers the Ansible playbook to install k3s, Helm, and deploy the Minecraft chart if `run_ansible_playbook = true` in `terraform/terraform.tfvars`
3.  **Verify:** Run `kubectl get pods -n minecraft` on the host to ensure the pod is `Running`.

### Service Exposure (Port 25565)
*   The server is exposed via a **LoadBalancer Service** on port `25565`.
*   In this k3s environment, the `ServiceLB` (Klipper) uses the host's public IP.
*   The Terraform Security Group is configured to allow inbound traffic on `25565/TCP` from `0.0.0.0/0`.
*   **Connection:** Use the public IP output by Terraform to connect in the Minecraft client.

### Rollout & Rollback
*   **Rollout:** To update the server (e.g., change image tag or MOTD), update `helm/minecraft/values.yaml` and re-run:
    ```bash
    ansible-playbook -i terraform/inventory.ini ansible/minecraft.yml
    ```
*   **Rollback:** If a deployment fails, you can roll back the Helm release:
    ```bash
    helm rollback minecraft -n minecraft
    ```

### Backup Procedure
*   **Automated:** A cron job runs `/usr/local/bin/mc_backup.sh` every 30 minutes, uploading a zipped `world` folder to the S3 bucket.
*   **Manual Trigger:**
    ```bash
    ansible-playbook -i terraform/inventory.ini ansible/backup_world.yml
    ```

### Restore Procedure
1.  Ensure you have a valid backup in the S3 bucket (`backups/world_backup_latest.zip`).
2.  Run the restore playbook:
    ```bash
    ansible-playbook -i terraform/inventory.ini ansible/restore_world.yml
    ```
    *   *This will automatically scale the server to 0, pull the data, extract it, and scale back up.*

---

## 2. Tradeoff Notes & Justifications

### Workload Controller: StatefulSet
*   **Decision:** Used `StatefulSet` with `replicas: 1`.
*   **Justification:** Minecraft is a stateful service that requires a stable identity and persistent storage. A `StatefulSet` ensures that the same PersistentVolume is re-attached to the pod even if it is rescheduled, and prevents multiple pods from writing to the same data simultaneously.

### Persistence Approach: Local-Path PVC
*   **Decision:** Used `PersistentVolumeClaim` with k3s `local-path` storage.
*   **Justification:** For a single-node cluster, `local-path` provides high performance and simplicity. Reliability is handled via the S3 backup/restore mechanism rather than complex networked storage (like EBS), which keeps costs lower and reduces latency.

### Service Exposure: LoadBalancer (ServiceLB)
*   **Decision:** Used `type: LoadBalancer`.
*   **Justification:** This follows standard Kubernetes patterns. In k3s, this leverages the built-in ServiceLB to map the host port 25565 directly to the container. It is more robust and easier to manage via manifests than hostPort or NodePort.

### Probes: Startup, Liveness, and Readiness
*   **Definition File:** `helm/minecraft/templates/statefulset.yaml`
*   **Values File:** `helm/minecraft/values.yaml`
*   **Configuration Details:**
    *   **Startup Probe:** Uses a `tcpSocket` check on port 25565. It is configured with a `failureThreshold` of **30** and a `periodSeconds` of **10**. This gives the server a maximum of **300 seconds (5 minutes)** to generate the world and start the Java process before Kubernetes considers it a failed start.
    *   **Liveness Probe:** Configured with an `initialDelaySeconds` of **60** and a `periodSeconds` of **30**. It ensures that if the Minecraft process deadlocks or hangs after the initial boot, Kubernetes will restart the container to restore service.
    *   **Readiness Probe:** Configured with an `initialDelaySeconds` of **30** and a `periodSeconds` of **15**. It ensures the `Service` doesn't route traffic to the pod until the Minecraft port is actually listening and ready for connections.
*   **Justification:** Minecraft takes significant time to load large worlds and initialize the JVM. The **Startup Probe** acts as a buffer; it prevents the **Liveness Probe** from prematurely killing the container during its 1-5 minute boot sequence. Once the Startup Probe succeeds, the Liveness and Readiness probes take over for long-term health monitoring.

### Resource Limits
*   **Decision:** Requests: 500m CPU / 1Gi RAM; Limits: 1 CPU / 2Gi RAM.
*   **Justification:** Java-based Minecraft 1.21+ is resource-intensive. 2Gi RAM is the "sweet spot" for a small server with 20 players to prevent Out-of-Memory (OOM) kills while fitting within a `t3.small` instance.

---

## 3. Teardown Checklist
To prevent runaway costs in AWS Academy, follow these steps:
1.  **Destroy Infrastructure:** `cd terraform && terraform destroy -auto-approve`
2.  **Verify S3 Deletion:** Ensure the backup bucket is removed (Terraform's `force_destroy = true` should handle this).
3.  **Verify ECR Deletion:** Ensure the repository is removed.
4.  **Confirm in Console:** Log into the AWS Console and verify no EC2 instances or EBS volumes remain in `us-east-1`.

## 4. Alert Runbooks

Each alert defined in `helm/monitoring/values.yaml` links to the corresponding runbook below.

---

### MinecraftPodDown

**Symptom:** Players cannot connect to the server. The Minecraft pod is not in a Ready state.

**Severity:** Critical

**First Response:**
1. Check the pod status:
   ```bash
   kubectl get pods -n minecraft -l app=minecraft
   ```
2. Describe the pod to find the root cause:
   ```bash
   kubectl describe pod -n minecraft -l app=minecraft
   ```
   Look for `Events:` at the bottom — common causes: OOMKill, image pull failure, probe failure.
3. Check the container logs:
   ```bash
   kubectl logs -n minecraft -l app=minecraft --tail=50
   ```
4. If the image is missing or broken, roll back:
   ```bash
   helm rollback minecraft -n minecraft
   ```

**Resolution:** Once the underlying issue is fixed, the pod will restart automatically via the StatefulSet controller. Run `kubectl wait --for=condition=Ready pod -n minecraft -l app=minecraft --timeout=300s` to confirm.

---

### MinecraftHighMemoryUsage

**Symptom:** Server lag, risk of OOM kill. Container memory exceeds 80% of its limit.

**Severity:** Warning

**First Response:**
1. Check current resource usage:
   ```bash
   kubectl top pod -n minecraft -l app=minecraft
   ```
2. Check if the container has been recently OOM-killed:
   ```bash
   kubectl describe pod -n minecraft -l app=minecraft | grep -A5 "Status:"
   ```
   `OOMKilled` in the last state indicates the limit is too low.
3. Consider increasing memory limits in `helm/minecraft/values.yaml`:
   ```yaml
   resources:
     limits:
       memory: 2Gi
   ```
4. Re-deploy after updating:
   ```bash
   ansible-playbook -i terraform/inventory.ini ansible/minecraft.yml
   ```

**Escalation:** If memory grows unbounded over time, investigate a plugin or world issue. Restore from S3 backup if corruption is suspected.

---

### MinecraftPodCrashLooping

**Symptom:** Server repeatedly crashes. Pod has restarted more than 2 times in 10 minutes.

**Severity:** Critical

**First Response:**
1. Check restart count:
   ```bash
   kubectl get pods -n minecraft -l app=minecraft
   ```
   The `RESTARTS` column shows the count.
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

---

### NodeDiskUsageHigh

**Symptom:** Risk of world save failure, pod eviction. Disk usage exceeds 80%.

**Severity:** Warning

**First Response:**
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

**Prevention:** The k3s install in the Ansible playbook enables aggressive eviction thresholds to prevent disk-full scenarios. Consider increasing the root volume in `terraform/main.tf` if this alert fires frequently.

---

# Minecraft Network Policy Documentation

## Overview

The `minecraft` NetworkPolicy restricts traffic to and from the Minecraft server pod within the Kubernetes cluster.

## Applied Policy

### Pod Selector
The policy applies to any pod with the following label:
- `app: <release-name>-minecraft`

### Ingress Rules (Inbound)
- **Allowed**: TCP traffic on port `25565` (or the configured `.Values.service.port`) from any IP (`0.0.0.0/0`).
- **Blocked**: All other inbound traffic from any source, including other pods in the cluster, unless specifically allowed by another policy.
- **Why**: Minecraft requires an open TCP port for players to join. By restricting ingress to only this port, we minimize the attack surface of the container.

### Egress Rules (Outbound)
- **Allowed**: Outbound traffic to any destination (`0.0.0.0/0`).
- **Why**: The Minecraft server needs outbound access for several reasons:
    - **ECR**: Pulling container images (if using a registry).
    - **S3**: The backup script runs inside or alongside the server and needs to push data to AWS S3.
    - **Updates/Plugins**: Downloading server updates or plugin data from external repositories.
- **Note**: In a strictly hardened production environment, egress would be restricted to specific CIDRs for S3/ECR endpoints, but for this k3s deployment, broad egress is required for general operational functionality.

## Limitations

- **Security Groups**: This NetworkPolicy does NOT replace AWS Security Groups. The Security Group must still allow inbound TCP 25565 for traffic to reach the node.
- **k3s Backend**: This policy assumes a CNI that supports NetworkPolicies (like Flannel in k3s) is correctly configured.
