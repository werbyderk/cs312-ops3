# Ops 5: Observability and Incident Response

{/* LOs:
- LO5: Describe how to plan major and minor tasks and time so that services are stable and effective, and meet a Service Level Agreement.
- LO6: Produce written documentation of system problems, solutions, processes, and procedures.
- LO7: Create programs and demonstrate facility in programs and tools that automate system administration tasks.
- LO8: Participate effectively in a team environment.
*/}

{/* ai-summary
type: assignment
slug: minecraft-5-observability
order: 5
prereq_assignment: minecraft-4-container-orchestration
prereq_lectures: monitoring-and-performance
prereq_labs: observability-workshop
new_scope: instrumentation, alerting, and operator-facing incident response for the existing Kubernetes-hosted Minecraft service
persistent_requirements: AWS Academy only; reuse the k3s baseline from Ops 4; images remain sourced from ECR; S3 backup and restoreability remain in place; cost controls documented; minimize public exposure
story_beat: leadership demands to know about outages before the CEO does
*/}

The Minecraft server went down at 2 AM on a Tuesday. Nobody noticed until the 9 AM standup, when the CEO asked why his nether portal was not loading. The incident retrospective was brief: "We did not know it was down." The CEO's only feedback, delivered without blinking: "How do we not know things?"

Your service runs on Kubernetes, but you have no visibility into its health. When something breaks, you find out from the CEO, not from your tools. This assignment adds the operational visibility and response practices that ensure you know about problems before leadership does.

## Learning Objectives

- Deploy and configure a monitoring stack (Prometheus + Grafana) on Kubernetes.
- Design actionable alerts tied to runbooks that reduce mean time to recovery.
- Execute a structured incident drill with detection, recovery, and postmortem.
- Demonstrate log access and interpretation for troubleshooting.

## Constraints (AWS Academy)

- You must use AWS Academy resources only.
- Start from your Ops 4 baseline: the existing k3s deployment on EC2. Single-node k3s is expected.
- Monitoring tools run alongside Minecraft on the same cluster; choose scrape intervals, retention, and storage settings that are defensible for a one-node lab environment.
- Images remain sourced from ECR. World backup and restoreability remain in S3.
- Use the IAM instance profile pattern from earlier assignments when AWS access is required. Do not place AWS access keys in manifests, dashboards, or ad hoc scripts.
- Minimize public exposure: restrict SSH to a known source, keep only required public ports open, and do not expose Prometheus or Grafana publicly without authentication and justification.
- Document cost controls: instance size, stop schedule, how to tear down the monitoring stack, and at least one retention or storage guardrail that limits monitoring growth.

## Requirements

### A. Monitoring Stack and Dashboard

- Deploy Prometheus and Grafana (or instructor-approved equivalent) on your k3s cluster.
- The monitoring deployment must be declarative and version-controlled: Helm values, Kubernetes manifests, or an equivalent reproducible path.
- Collect and visualize node health metrics: CPU, memory, and disk usage.
- Collect and visualize pod or workload health metrics for Minecraft: restarts, readiness, and resource consumption.
- Collect and visualize at least one Minecraft-specific signal such as player count, JVM memory, an RCON or status-exporter signal, or service response behavior. Document what the signal means and why it is useful.
- Build a dashboard that answers the operator question: "Is my service healthy right now?" Panels must be clearly labeled and useful to another operator under time pressure.

### B. Actionable Alerts

- Define at least **three** alerts.
- Each alert must be tied to a clear operator symptom, not just an unexplained raw threshold.
- Each alert must include a justified threshold or trigger condition.
- Each alert must link to a runbook section with first-response steps.
- At least one alert must reflect player-visible service impact or loss of availability, not only host saturation.

Examples: pod crash looping, sustained high memory usage approaching limits, disk usage above 80%, service probe failures.

### C. Incident Drill and Log Investigation

- Pick **one** failure scenario and execute it end-to-end:
  - **Bad deploy**: push a deployment with a broken image, detect via alerts/dashboard, recover via rollback
  - **Resource exhaustion**: set artificially low resource limits, detect via metrics, recover via adjustment
  - **Service misconfiguration**: introduce a bad ConfigMap change, detect via probes/logs, recover via config fix
- Your drill documentation must name the introduced failure, the specific detection path, the recovery steps, and a brief postmortem.
- During the drill, use at least one authoritative investigation step such as `kubectl describe`, `kubectl get events`, or `kubectl logs`. When relevant, `kubectl logs --previous` is acceptable.
- Demonstrate that you can locate and interpret a specific log line or event from the drill.
- Document where logs live for this cluster today and what an operator should search first during an incident.

### D. Documentation

Your PDF must be usable by another operator with no prior knowledge of your setup. Required sections:

- Updated architecture diagram showing the Minecraft workload, Prometheus, Grafana, any exporters, and the existing ECR and S3 integration points.
- On-call quickstart: what to check first when paged, where to look next, and how to tell whether the problem is user-visible.
- One runbook per alert (at least 3 runbooks).
- Link to your repository and a concise file map identifying the exact manifests, Helm values, dashboards, alert definitions, and supporting automation you used.
- Cost controls: how to tear down monitoring components, what retention or storage choices limit growth, and any scheduling considerations.

## Hints

These pointers cover Minecraft-specific integration points.

- Default dashboards are not enough. Build at least one focused dashboard that puts node saturation, pod health, and your Minecraft-specific signal on one screen.
- If you need a Minecraft-specific signal, an RCON exporter, JVM metric source, or a status utility such as [mc-monitor](https://github.com/itzg/mc-monitor) can be a defensible starting point. Whatever you choose, explain what "healthy" means for that signal.
- If you use a simpler Prometheus deployment, verify that you are actually collecting the Kubernetes metadata and workload metrics you plan to alert on. A dashboard cannot show pod restarts or readiness if nothing is scraping that layer.

You can use any Minecraft server software you like. You can choose the Linux distribution you prefer.

## What You'll Submit

1. **Observability and Incident Response Documentation (PDF)**: includes your incident drill report and brief postmortem, updated architecture diagram, on-call quickstart, alert runbooks, cost controls, and a repository link with a concise file map for the submitted manifests, Helm values, dashboards, alert definitions, and supporting automation. Another operator should be able to detect, investigate, and recover a failure from this document without asking you questions.
2. **Narrated screen recording (max 3 minutes)**. Your server MOTD must include your name or student ID. **Submit timestamps alongside the video** (e.g., "Checkpoint 1: 0:00, Checkpoint 2: 0:38, ..."):
1. Run `nmap -sV -Pn -p T:25565 <public-endpoint>` showing the service reachable with your custom MOTD, then show the Grafana dashboard with current node health, pod health, and one Minecraft-specific signal.
2. Show your alert definitions and one linked runbook. Explain why one alert threshold or trigger condition is defensible.
3. Use `kubectl logs` to locate a specific event relevant to your chosen drill or a recent failure. Make it clear what the log line means and where an operator would look next.
4. Execute your incident drill: introduce the failure, show detection in the dashboard, alerts, or logs, perform recovery, and confirm the service is healthy again.

## Rubric

<RubricTable tsv={rubricTsv} sourceLabel="canvas/assignments/assignment-5-rubrics.tsv" caption="Observability and Incident Response" />

## Extra Credit (up to +10)

- **Log Aggregation (+5)**: Deploy Loki, Promtail, or equivalent on the cluster. Show searchable, centralized logs in Grafana or a dedicated UI. Document the retention policy.
- **SLO and Alert Refinement (+5)**: Define a measurable SLO for your Minecraft service (for example, availability or responsiveness), add a corresponding dashboard view plus alert or recording rule, and document how you would measure and report on it over a week.

Extra credit must stay within this assignment's observability scope. Do not replace the assignment with a managed monitoring product or a full platform redesign.
