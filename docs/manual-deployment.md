# Manual deployment

This walkthrough performs the same operations as `scripts/quickstart.sh` one step at a time. Use it to understand or customize the Kubernetes and Dapr resources.

## 1. Connect to AKS

```bash
az account set --subscription <SUBSCRIPTION_ID>

az aks get-credentials \
  --resource-group <AKS_RESOURCE_GROUP> \
  --name <AKS_CLUSTER_NAME> \
  --overwrite-existing
```

Confirm that the cluster is reachable and the Dapr extension is installed:

```bash
kubectl get nodes
kubectl get pods -n dapr-system
kubectl get customresourcedefinition components.dapr.io
```

## 2. Create an isolated namespace

```bash
kubectl create namespace dapr-quickstart
```

All remaining commands use this namespace.

```bash
export QUICKSTART_NAMESPACE=dapr-quickstart
```

## 3. Configure the state store

Deploy the Redis pod, private service, and Dapr component:

```bash
kubectl apply \
  --namespace "$QUICKSTART_NAMESPACE" \
  -f deploy/redis.yaml

kubectl rollout status deployment/redis \
  --namespace "$QUICKSTART_NAMESPACE"
```

Redis uses an `emptyDir` volume, so the quickstart data is temporary. The `Component` resource tells Dapr how to provide the `statestore` building block without adding Redis connection logic to the application.

Inspect the component:

```bash
kubectl get component statestore \
  --namespace "$QUICKSTART_NAMESPACE" \
  -o yaml
```

## 4. Deploy the Node.js application

```bash
kubectl apply \
  --namespace "$QUICKSTART_NAMESPACE" \
  -f deploy/node.yaml

kubectl rollout status deployment/nodeapp \
  --namespace "$QUICKSTART_NAMESPACE"
```

The deployment annotations demonstrate:

- `dapr.io/enabled: "true"`: inject the `daprd` sidecar.
- `dapr.io/app-id: "nodeapp"`: register the application with a Dapr app ID.
- `dapr.io/app-port: "3000"`: identify the application port.

Confirm that the pod contains the application and sidecar containers:

```bash
kubectl get pods --namespace "$QUICKSTART_NAMESPACE"
```

## 5. Verify private access and state

The `nodeapp` service is `ClusterIP`, so it isn't directly exposed to the internet.

```bash
kubectl get service nodeapp --namespace "$QUICKSTART_NAMESPACE"
```

In a separate terminal, create temporary local access:

```bash
kubectl port-forward \
  --namespace dapr-quickstart \
  service/nodeapp 8080:80
```

Verify the Dapr ports injected into the application:

```bash
curl http://localhost:8080/ports
```

Persist an order through the Node.js endpoint:

```bash
curl \
  --request POST \
  --data @sample.json \
  --header "Content-Type: application/json" \
  http://localhost:8080/neworder
```

Read the order back:

```bash
curl http://localhost:8080/order
```

Expected response:

```json
{"orderId":"42"}
```

The application calls its local Dapr sidecar, and the sidecar stores the value through the `statestore` component.

## 6. Deploy the Python publisher

```bash
kubectl apply \
  --namespace "$QUICKSTART_NAMESPACE" \
  -f deploy/python.yaml

kubectl rollout status deployment/pythonapp \
  --namespace "$QUICKSTART_NAMESPACE"
```

The Python process calls `localhost:3500` and sends the `dapr-app-id: nodeapp` header. Its sidecar resolves `nodeapp` and invokes the Node.js application without the Python code knowing a service address.

Watch incoming orders:

```bash
kubectl logs \
  --namespace "$QUICKSTART_NAMESPACE" \
  --selector app=node \
  --container node \
  --follow
```

Watch Dapr API calls:

```bash
kubectl logs \
  --namespace "$QUICKSTART_NAMESPACE" \
  --selector app=node \
  --container daprd \
  --follow
```

## 7. Clean up

Delete the isolated namespace and all quickstart resources inside it:

```bash
kubectl delete namespace "$QUICKSTART_NAMESPACE"
```

This doesn't delete the AKS cluster.
