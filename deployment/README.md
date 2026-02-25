# DisplayData Deployment

This folder contains the complete, versatile deployment codebase for DisplayData services across different environments. Every tenant receives a copy of this folder to deploy the services into their own Kubernetes cluster.

## Architecture

*   **Helm Chart (`/helm/dd-service`):** A generic, reusable Helm chart. It deploys *any* service. It handles Deployments, Services (ClusterIP/NodePort), ConfigMaps, Secrets, Ingress, HPA, and NetworkPolicies based purely on the values passed in.
*   **Environments (`/environments`):** Tenant-specific configuration. Each environment (e.g., `dev`, `prod`) contains one values file per service (e.g., `api-gateway.values.yaml`). This is the **only** place where configuration changes are made.
*   **Deployment Script (`deploy.sh`):** A bash script that orchestrates the Helm commands, mapping services to their respectful values files and deploying them into the correct environment namespace (`dd-<env>`).

## Namespace Strategy

Each environment gets its own isolated namespace:
*   `dd-dev` for the `dev` environment
*   `dd-prod` for the `prod` environment

This ensures that resources, RBAC, and network policies are isolated between environments on the same cluster.

## Usage

The `deploy.sh` script is the primary entrypoint.

### Prerequisites

*   `kubectl` configured with access to the target cluster.
*   `helm` (v3+) installed.

### Deploying a single service

Often during CI/CD (e.g., GitHub Actions), a single service is built and needs to be deployed.

```bash
# Deploy api-gateway to the dev environment
./deploy.sh --env dev --service api-gateway

# Deploy auth-service to the prod environment
./deploy.sh --env prod --service auth-service
```

### Deploying all services

Useful for initial bootstrapping or mass updates.

```bash
# Deploy all 4 services to dev
./deploy.sh --env dev --all
```

### Dry Run

Preview what Helm will generate without modifying the cluster.

```bash
./deploy.sh --env dev --service api-gateway --dry-run
```

## Adding a new service

1. Add the new service name to the `ALL_SERVICES` array in `deploy.sh`.
2. Create `<new-service>.values.yaml` in the relevant `environments/<env>/` directories.
3. Deploy it!

## Configuration (ConfigMaps and Secrets)

The generic Helm chart makes it incredibly easy to inject configuration:

*   **`configData`:** Any key-value pair added here in the `values.yaml` will be mounted as an environment variable in the pod via a ConfigMap.
*   **`secretData`:** Any key-value pair added here will be mounted as a secure environment variable via a Secret. **Note:** Values in `secretData` MUST be base64 encoded strings in the YAML file.
