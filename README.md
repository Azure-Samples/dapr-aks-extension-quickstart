# Dapr AKS Extension Quickstart

Deploy a Node.js application and Python publisher to an existing Azure Kubernetes Service (AKS) cluster with the Dapr extension.

![Architecture diagram](./img/Architecture_Diagram.png)

This quickstart demonstrates:

- Dapr sidecar injection.
- Service invocation using Dapr app IDs.
- State management backed by an in-cluster Redis pod.

## Prerequisites

- Bash on WSL, Linux, or macOS.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli).
- [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/) compatible with the AKS Kubernetes version.
- `curl`.
- An AKS cluster with the [Dapr extension](https://learn.microsoft.com/azure/aks/dapr-overview).

## Quickstart

### 1. Configure

```bash
git clone https://github.com/Azure-Samples/dapr-aks-extension-quickstart.git
cd dapr-aks-extension-quickstart
cp .env.example .env
```

Update `.env` with your existing Azure resources:

```dotenv
AZURE_SUBSCRIPTION_ID=<subscription-id>
AKS_RESOURCE_GROUP=<aks-resource-group>
AKS_CLUSTER_NAME=<aks-cluster-name>

K8S_NAMESPACE=dapr-quickstart
LOCAL_PORT=8080
```

### 2. Deploy

```bash
./scripts/quickstart.sh deploy --config .env
```

The script prints deployment progress and verification results directly to the console.
Steps, successful checks, warnings, and errors use distinct terminal colors. Set `NO_COLOR=1` to disable colors.

### 3. Explore

Use the namespace configured in `.env`:

```bash
export QUICKSTART_NAMESPACE=dapr-quickstart
```

Inspect the applications, services, and Dapr component:

```bash
kubectl get pods,services,components.dapr.io \
  -n "$QUICKSTART_NAMESPACE"
```

Watch orders received by the Node.js application:

```bash
kubectl logs -n "$QUICKSTART_NAMESPACE" \
  -l app=node -c node -f
```

Watch Dapr state API calls:

```bash
kubectl logs -n "$QUICKSTART_NAMESPACE" \
  -l app=node -c daprd -f
```

Run the verification again:

```bash
./scripts/quickstart.sh verify --config .env
```

### 4. Clean up

```bash
./scripts/quickstart.sh cleanup --config .env
```

Cleanup removes only the quickstart Kubernetes namespace. It doesn't delete AKS.

## How it works

| Step | Dapr concept |
|---|---|
| Configure `statestore` | Dapr connects to the in-cluster Redis service through a component. |
| Deploy `nodeapp` | Pod annotations inject a sidecar and register app ID `nodeapp`. |
| Save an order | Node.js calls the local Dapr state API. |
| Deploy `pythonapp` | Python invokes `nodeapp` through its local sidecar. |
| Access the app | The service stays private and is tested through port-forwarding. |

The sample uses the Dapr OSS Kubernetes quickstart images:

- `ghcr.io/dapr/samples/hello-k8s-node:latest`
- `ghcr.io/dapr/samples/hello-k8s-python:latest`

For an individual command walkthrough, see [Manual deployment](./docs/manual-deployment.md).

## Troubleshooting

Check Dapr:

```bash
kubectl get pods -n dapr-system
kubectl get customresourcedefinition components.dapr.io
```

Check application status and logs:

```bash
kubectl get pods -n dapr-quickstart
kubectl describe pods -n dapr-quickstart
kubectl logs -n dapr-quickstart -l app=node -c daprd
```

Azure Policy can warn that the sample images aren't on the cluster's approved-image list. If the policy blocks deployment, mirror the images to an approved registry and update the manifests.

If cleanup leaves the namespace in `Terminating`, inspect it:

```bash
kubectl describe namespace dapr-quickstart
```

Stale API discovery or third-party finalizers on the cluster can delay namespace deletion even after all quickstart resources are removed.

## Next steps

- [Dapr OSS quickstarts](https://github.com/dapr/quickstarts)
- [Dapr service invocation](https://docs.dapr.io/developing-applications/building-blocks/service-invocation/)
- [Dapr state management](https://docs.dapr.io/developing-applications/building-blocks/state-management/)
