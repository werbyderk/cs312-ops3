# Ops 4: Container Orchestration

{/* LOs:
- LO3: Demonstrate how to manage a server for the purposes of providing specific services to a collection of users and devices, including manipulation of user accounts, resource management, and security.
- LO5: Describe how to plan major and minor tasks and time so that services are stable and effective, and meet a Service Level Agreement.
- LO7: Create programs and demonstrate facility in programs and tools that automate system administration tasks.
- LO8: Participate effectively in a team environment.
*/}

{/* ai-summary
type: assignment
slug: minecraft-4-container-orchestration
order: 4
prereq_assignment: minecraft-3-infrastructure-automation
prereq_lectures: container-orchestration, network-services-and-application-delivery, incident-response-and-postmortems
prereq_labs: first-container-orchestration-deployment, cluster-operations
new_scope: migration of the existing Minecraft service from Docker Compose to Kubernetes with declarative operations and controlled recovery
persistent_requirements: AWS Academy only; reuse the pinned ECR artifact chain; S3 backup and restoreability; cost controls documented; minimize public exposure
story_beat: leadership mandates a Kubernetes migration for the already-running Minecraft service
*/}

The VP of Engineering attended KubeCon and came back a changed person. A company-wide Slack message confirmed that "all services will migrate to Kubernetes by Q3." When you pointed out that the Minecraft server is not a business-critical production service, you were told that "all means all." There was a follow-up message clarifying that this includes the Minecraft server specifically.

Your Docker Compose deployment from Ops 3 works, but it still assumes one host, one runtime, and an application-layer recovery story that lives mostly outside the orchestrator. You are not being asked to rebuild the service from scratch. You *are* being asked to migrate that existing Minecraft deployment onto Kubernetes in a controlled way: preserve the artifact chain, preserve the world data, and add the declarative rollout and recovery controls leadership now expects.
**Should You Choose Kubernetes for a Minecraft Server?:** Not if your main goal is horizontal scaling of one shared Minecraft world. A single Minecraft server is a stateful workload, and multiple interchangeable replicas are usually not meaningful the way they are for a stateless web service. In this assignment, Kubernetes is being used for declarative deployment, restart behavior, rollouts, rollback, and operational recovery, not because it is the simplest possible platform for Minecraft.

## Learning Objectives

- Deploy and operate a stateful workload in Kubernetes using k3s.
- Apply Kubernetes primitives correctly: Services, ConfigMaps/Secrets, health probes, and resource controls.
- Preserve and protect world state across pod restarts and node reboots.
- Demonstrate rollout, rollback, and failure recovery as operational procedures.

## Constraints (AWS Academy)

- You must use AWS Academy resources only.
- Start from your Ops 3 baseline: reuse or adapt your Terraform/OpenTofu project, pinned ECR image source, S3 backup location, and IAM instance profile pattern.
- Kubernetes must run on EC2; use k3s unless your instructor explicitly approves an alternative.
- Infrastructure must be provisioned via Terraform/OpenTofu.
- Use an IAM instance profile for S3 access; do not hardcode AWS credentials in manifests or environment variables.
- Minimize public exposure: restrict SSH access to a known source, and open only ports required for Minecraft.
- Document cost controls: instance size, stop schedule, and at least one additional guardrail.
- State handling must be explicit and defensible; for k3s single-node, simplicity is acceptable if well-justified.

## Requirements

### A. Provisioning

- Terraform/OpenTofu provisions an EC2 host that runs k3s.
- Start from your Ops 3 infrastructure code. You may refactor Docker/Compose-specific host setup into k3s bootstrap, but the deployment must remain rebuildable from code.
- You may reuse Ansible or cloud-init for node bootstrap and backup/restore plumbing, but workload configuration must live in Kubernetes manifests or Helm values rather than ad hoc shell commands.
- Security Group rules are minimal and justified: SSH restricted to a known source; TCP 25565 open for Minecraft; no unnecessary ports.

### B. Kubernetes Deployment

- Minecraft runs in Kubernetes using a workload controller appropriate for a single-replica stateful service. A Deployment with a PVC is acceptable on single-node k3s if you justify the tradeoff; a StatefulSet is also acceptable. Use the image you published in Assignment 2 or built via your CI/CD pipeline from Assignment 3. Reference a specific pinned tag, not `latest`.
- Required configuration is delivered via ConfigMap/Secret as appropriate.
- Expose Minecraft through a Kubernetes Service on TCP 25565. For the standard single-node k3s path, use a Service of type `LoadBalancer` so k3s ServiceLB binds 25565 on the host. Do not use NodePort or hostPort as the primary submission path.
- Liveness and readiness probes are defined and justified in your documentation.
- Probe choice must be defensible for a long-starting Java service. A `startupProbe` is recommended; if you omit it, explain how your timings avoid restart loops during startup.
- Resource requests and limits are set and justified in your documentation.

### C. Persistence and Safety

- World data is stored on a persistent volume that survives pod deletion.
- Your documentation must justify the persistence approach relative to single-node k3s tradeoffs.
- World data is backed up to S3; the backup trigger or schedule is documented.
- The restore procedure is step-by-step and verifiable by another operator.

### D. Operational Demonstrations

You must demonstrate all of the following:

- A rollout to a new image version.
- A rollback to the previous version.
- One failure drill (choose one):
  - **Node reboot**: reboot the EC2 host; brief downtime during the reboot is acceptable on single-node k3s, but k3s and Minecraft must recover automatically with world data intact.
  - **Bad deploy**: push a deployment with a broken or missing image tag; show rollout failure detection and the rollback process restoring service.
  - **Resource exhaustion**: simulate a resource constraint (e.g., set extremely low memory limits); show OOM or restart detection and recovery.
- During the drill, show at least one authoritative Kubernetes diagnostic view appropriate to the failure, such as `kubectl describe`, `kubectl get events`, `kubectl rollout status/history`, or `kubectl logs`.

### E. Documentation

Your PDF must be usable by another operator with no prior knowledge of your setup. Required sections:

- Architecture diagram showing EC2, k3s, all Kubernetes resources (Deployment or StatefulSet, Service, PVC, ConfigMap/Secret), ECR, and S3.
- Runbook covering: deployment procedure, service exposure on 25565, rollout/rollback steps, backup procedure, and step-by-step restore from S3.
- Tradeoff notes justifying your workload controller choice, persistence approach, service exposure choice, probe configuration, and resource limits.
- Link to your version control repository and a concise file map identifying the exact submission files. This must cover the Terraform/OpenTofu code, Kubernetes manifests or Helm values, and any supporting automation you used (for example: Ansible, cloud-init, scripts). You may also include selected code blocks in the PDF, but the grader must be able to locate the exact submitted configuration quickly.
- Teardown checklist to prevent runaway cost after the assignment ends.

## Hints

k3s is a lightweight Kubernetes distribution designed for single-node operation, but stateful workloads like Minecraft require careful configuration.

- You can and should reuse your Ops 3 Terraform, IAM instance profile pattern, S3 backup location, and image pipeline. The new work here is replacing Docker Compose with Kubernetes resources, not inventing a second artifact chain.
- k3s uses `containerd` as its container runtime. Your ECR images push and pull normally, but k3s must be configured to authenticate against ECR. One common approach: store your ECR credentials in a Kubernetes `imagePullSecret` and reference it in your Deployment spec.
- Minecraft does not expose a standard HTTP health endpoint. A TCP socket probe (`tcpSocket: { port: 25565 }`) is an acceptable baseline when your chosen server image exposes no stronger health signal, but document the limitation: an open port is weaker evidence than true application readiness.
- Minecraft startup can be slow, especially when loading a world. A `startupProbe`, or conservative liveness/readiness timing, can prevent Kubernetes from killing the server during JVM warmup.
- The default k3s storage class (`local-path`) provisions volumes on the node's local disk. This is sufficient for this assignment; document the tradeoff relative to a cloud-managed persistent volume.
- For public exposure in this assignment, prefer a `LoadBalancer` Service on port 25565. On single-node k3s, ServiceLB (`klipper-lb`) binds the service port directly on the host when that port is available.
- Ingress is primarily for HTTP and HTTPS routing. Minecraft does not need it for the primary exposure path in this assignment.

You may use any Minecraft server software you like. The key is that your documentation is clear and reproducible for another operator.

## What You'll Submit

1. **Architecture and Operations Documentation (PDF)**: covers your Kubernetes architecture, runbook, tradeoff decisions, repository link and file map for the submitted automation/configuration, and teardown checklist. Another operator must be able to deploy, operate, roll back, and restore the server from this document without asking you questions.
2. **Narrated screen recording (max 3 minutes)**. Your server MOTD must include your name or student ID. Submit timestamps alongside the video (e.g., "Checkpoint 1: 0:00, Checkpoint 2: 0:38, ..."):
1. `kubectl get nodes` and `kubectl get pods` showing the k3s node and Minecraft pod running, then `nmap -sV -Pn -p T:25565 <public-endpoint>` showing 25565/tcp open with your custom MOTD.
2. `kubectl delete pod <minecraft-pod>` followed by `kubectl get pods` showing the replacement pod come up, then evidence that the replacement pod mounts the same PVC and that the world directory still contains your data. If you need a concrete verification pattern, adapt the persistence-check approach from [Ops 2, section B](https://cs312.alexulbrich.com/assignments/minecraft-2-containerized-server/#b-state-boundary-and-persistence).
3. Roll out a new image version (e.g., `kubectl set image` or a manifest update), confirm it deploys, then roll back to the previous version and confirm the server is joinable after rollback.
4. Execute your chosen failure drill: introduce the failure, show authoritative diagnostic output (`kubectl describe`, events, rollout status/history, logs, or equivalent), execute recovery, and confirm the server is joinable with world data intact.

## Rubric

<RubricTable tsv={rubricTsv} sourceLabel="canvas/assignments/assignment-4-rubrics.tsv" caption="Container Orchestration" />

## Extra Credit (up to +10)

- **Helm Chart (+5)**: Package the Minecraft deployment as a Helm chart with configurable values (server properties, resource limits, image tag). Show that `helm install` and `helm upgrade` work correctly.
- **Network Policy (+5)**: Define a Kubernetes `NetworkPolicy` that restricts pod-level traffic for the Minecraft workload to only the required ports and peers. Document what it blocks, what it does not block, and why. Do not treat it as a replacement for Security Group or Service exposure controls.

Extra credit must stay within this assignment's Kubernetes scope (no additional cloud services or multi-node cluster setups).
