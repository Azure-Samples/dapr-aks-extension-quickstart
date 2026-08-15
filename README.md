---
page_type: sample
languages:
  - shell
  - javascript
  - python
  - dockerfile
products:
  - azure
  - azure-kubernetes-service
  - azure-managed-redis
urlFragment: dapr-aks-extension-quickstart
name: Dapr AKS Extension Quickstart
description: Deploy two applications with Dapr sidecars on AKS and persist state in Azure Managed Redis.
---

# Dapr AKS Extension Quickstart

Deploy a Node.js application and Python publisher to an existing Azure Kubernetes Service (AKS) cluster with the Dapr extension. The sample demonstrates sidecar injection, service invocation, and state management backed by Azure Managed Redis.

![Architecture diagram](./img/Architecture_Diagram.png)

> [!NOTE]
> This repository is a learning sample, not a production architecture. The automated flow keeps the application private and creates resources in an isolated Kubernetes namespace.

## What you will learn

- How Dapr sidecars are injected into Kubernetes pods.
- How applications invoke each other by Dapr app ID.
- How the Dapr state API separates application code from Redis connection logic.
- How to inspect application and `daprd` logs.
- How to access a private Kubernetes service with temporary port-forwarding.

## Prerequisites

You need:

- A Bash-compatible shell such as WSL, Linux, or macOS.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli).
- [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/).
- `curl`.
- An existing AKS cluster with the [Dapr extension](https://learn.microsoft.com/azure/aks/dapr-overview).
- An existing Azure Managed Redis instance with:
  - Network access from the AKS cluster.
  - Access-key authentication enabled for this learning scenario.

Confirm that the tools are available:

```bash
az version
kubectl version --client
curl --version
```

## Quickstart

### 1. Clone and configure

```bash
git clone https://github.com/Azure-Samples/dapr-aks-extension-quickstart.git
cd dapr-aks-extension-quickstart
cp .env.example .env
```

Edit `.env` with the names of your existing Azure resources:

```dotenv
AZURE_SUBSCRIPTION_ID=<subscription-id>
AKS_RESOURCE_GROUP=<aks-resource-group>
AKS_CLUSTER_NAME=<aks-cluster-name>
REDIS_RESOURCE_GROUP=<redis-resource-group>
REDIS_NAME=<redis-name>

K8S_NAMESPACE=dapr-quickstart
LOCAL_PORT=8080
```

The file contains resource identifiers only. The Redis key is retrieved at runtime and isn't written to `.env`.

### 2. Deploy and verify

```bash
./scripts/quickstart.sh deploy --config .env
```

The script prints and logs each phase:

1. Connect to the existing AKS cluster.
1. Verify that Dapr is installed.
1. Create an isolated namespace and Kubernetes Secret.
1. Configure the Dapr state-store component.
1. Deploy the Node.js application and its sidecar.
1. Verify private access and state persistence.
1. Deploy the Python publisher and its sidecar.
1. Verify Dapr service invocation and shared state.

Successful verification includes output similar to:

```text
[INFO] Service nodeapp is private: type=ClusterIP, externalIP=none.
[INFO] GET /order response: {"orderId":"42"}
[INFO] Python publisher updated the order through Dapr service invocation: {"orderId":19}
```

Logs are saved to:

```text
~/.local/state/dapr-aks-extension-quickstart/quickstart-<timestamp>.log
```

Set `DAPR_QUICKSTART_LOG_DIR` to use another directory. Redis credentials and Kubernetes Secret contents aren't logged.

### 3. Explore the Dapr concepts

Set this variable to the `K8S_NAMESPACE` value from `.env`:

```bash
export QUICKSTART_NAMESPACE=dapr-quickstart
```

List the application pods. Each pod should show two containers: the application and `daprd`.

```bash
kubectl get pods -n "$QUICKSTART_NAMESPACE"
```

Inspect the state-store component:

```bash
kubectl get component statestore -n "$QUICKSTART_NAMESPACE" -o yaml
```

Inspect the application service and Dapr-created headless services:

```bash
kubectl get services -n "$QUICKSTART_NAMESPACE"
```

Watch orders received by the Node.js application:

```bash
kubectl logs -n "$QUICKSTART_NAMESPACE" -l app=node -c node -f
```

Watch state API calls handled by the Node.js sidecar:

```bash
kubectl logs -n "$QUICKSTART_NAMESPACE" -l app=node -c daprd -f
```

Re-run the endpoint and service-invocation checks:

```bash
./scripts/quickstart.sh verify --config .env
```

### 4. Clean up

```bash
./scripts/quickstart.sh cleanup --config .env
```

Cleanup deletes only the configured Kubernetes namespace. It doesn't delete the AKS cluster or Azure Managed Redis instance.

## How the sample works

| Phase | Dapr concept | Kubernetes resource |
|---|---|---|
| Configure state | A component supplies the `statestore` building block | `Component/statestore` |
| Deploy Node.js | Pod annotations request sidecar injection and register app ID `nodeapp` | `Deployment/nodeapp` |
| Persist state | Node.js calls its local sidecar instead of connecting directly to Redis | `daprd` sidecar |
| Deploy Python | Python calls its local sidecar with target app ID `nodeapp` | `Deployment/pythonapp` |
| Invoke service | Dapr resolves the target app and forwards `/neworder` | `nodeapp-dapr` headless service |
| Access locally | The application remains private inside the cluster | `Service/nodeapp` (`ClusterIP`) |

The sample applications use the same public images as the Dapr OSS Kubernetes quickstart:

| Application | Image |
|---|---|
| Node.js | `ghcr.io/dapr/samples/hello-k8s-node:latest` |
| Python | `ghcr.io/dapr/samples/hello-k8s-python:latest` |

## Manual deployment

To perform every command individually and examine each resource as it is created, follow [the manual deployment guide](./docs/manual-deployment.md).

## Troubleshooting

### Dapr isn't installed

If the script reports that `components.dapr.io` is missing, verify the extension:

```bash
kubectl get pods -n dapr-system
az k8s-extension list \
  --cluster-type managedClusters \
  --cluster-name <aks-cluster-name> \
  --resource-group <aks-resource-group> \
  --output table
```

### Redis key retrieval fails

Enable access-key authentication on the default database:

```bash
az redisenterprise database update \
  --cluster-name <redis-name> \
  --resource-group <redis-resource-group> \
  --access-keys-auth Enabled
```

> [!IMPORTANT]
> Access-key authentication is used to keep this quickstart focused on Dapr concepts. Prefer Microsoft Entra authentication and managed identity for production workloads.

### Pods don't become ready

Inspect pod events and container logs:

```bash
kubectl describe pods -n dapr-quickstart
kubectl logs -n dapr-quickstart -l app=node -c node
kubectl logs -n dapr-quickstart -l app=node -c daprd
```

### An Azure Policy warning rejects the sample images

Some clusters restrict images to approved registries. Mirror the images into an approved registry, update `deploy/node.yaml` and `deploy/python.yaml`, and use immutable digests.

### Local port 8080 is already in use

Change `LOCAL_PORT` in `.env`, then run verification again:

```dotenv
LOCAL_PORT=18080
```

## Why this sample uses a script instead of `azd up`

The quickstart intentionally targets an existing AKS cluster and Azure Managed Redis instance. `azd up` normally provisions and owns the complete Azure environment. The script keeps infrastructure ownership explicit while providing the same configure, deploy, verify, log, and clean-up workflow expected from modern Azure samples.

## Build your own images

Each application directory contains a Dockerfile:

```bash
docker build -t <registry>/hello-k8s-node:<tag> ./node
docker build -t <registry>/hello-k8s-python:<tag> ./python
```

Push the images to your approved registry, update the deployment manifests, and prefer immutable image digests over mutable tags.

## Next steps

- Explore the [Dapr OSS quickstarts](https://github.com/dapr/quickstarts).
- Learn about [Dapr service invocation](https://docs.dapr.io/developing-applications/building-blocks/service-invocation/).
- Learn about [Dapr state management](https://docs.dapr.io/developing-applications/building-blocks/state-management/).
- Review [production guidance for Dapr on Kubernetes](https://docs.dapr.io/operations/hosting/kubernetes/kubernetes-production/).

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for contribution guidelines.
