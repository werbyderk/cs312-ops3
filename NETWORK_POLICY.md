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
