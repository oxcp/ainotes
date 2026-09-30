# Install Cilium on AKS with BYO CNI

This example creates an Azure Kubernetes Service (AKS) cluster without a preinstalled CNI, after which you install and manage Cilium yourself.

> [!IMPORTANT]
> `--network-plugin none` means that AKS does not manage pod networking. The nodes might remain `NotReady` until Cilium is installed; this is expected.
> With BYO CNI, you are responsible for pod IP allocation, routing, network policies, and troubleshooting CNI-related issues.

## Prerequisites

- A Bash environment (Linux, WSL, or Azure Cloud Shell)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) installed
- Signed in through `az login`, with permission to create resource groups and AKS clusters
- `curl`, `tar`, and `sha256sum` for installing the Cilium CLI
- Pod and service CIDRs that do not overlap with the VNet or any connected network

This guide uses the following defaults:

| Setting | Default |
|---|---|
| Resource group | `rg-aks-byocni` |
| AKS cluster name | `aksbyocni` |
| Region | `southeastasia` |
| Pod CIDR | `10.30.0.0/16` |
| Service CIDR | `172.168.0.0/16` |
| DNS service IP | `172.168.0.10` |

## 1. Run the Script to Create AKS

Change to this directory and run:

```bash
chmod +x createcluster-byocni.sh
./createcluster-byocni.sh
```

You can override every setting with environment variables. For example:

```bash
SUBSCRIPTION_ID="<subscription-id>" \
RESOURCE_GROUP="rg-my-aks-byocni" \
CLUSTER_NAME="aks-my-byocni" \
LOCATION="southeastasia" \
NODE_COUNT="2" \
NODE_VM_SIZE="Standard_D4s_v5" \
POD_CIDR="10.30.0.0/16" \
SERVICE_CIDR="172.168.0.0/16" \
DNS_SERVICE_IP="172.168.0.10"

./createcluster-byocni.sh
```

Optional environment variables:

- `KUBERNETES_VERSION`: Specifies an AKS-supported Kubernetes version. When empty, the AKS default version is used.
- `ACR_ID`: The full resource ID of an Azure Container Registry to attach. When empty, no registry is attached.
- `MAX_PODS`: The maximum number of pods that can be scheduled on each node. The default is `50`.

The script is safe to run repeatedly. If an AKS cluster with the same name already exists, the script verifies that its network plugin is `none` before reusing it. If the existing cluster uses another network plugin, the script exits with an error.

After creation, verify the AKS network configuration:

```bash
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-aks-byocni}"
CLUSTER_NAME="${CLUSTER_NAME:-aksbyocni}"

az aks show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --query "{networkPlugin:networkProfile.networkPlugin,podCidr:networkProfile.podCidr,serviceCidr:networkProfile.serviceCidr}" \
  --output table
```

The expected value of `networkPlugin` is `none`.
```text
NetworkPlugin    PodCidr       ServiceCidr
---------------  ------------  --------------
none             10.30.0.0/16  172.168.0.0/16
```

As described in the Microsoft Learn guidance for [deploying a CNI plugin on an AKS BYO CNI cluster](https://learn.microsoft.com/en-us/azure/aks/use-byo-cni?tabs=azure-cli#deploy-a-cni-plugin), AKS provisioning is complete and the cluster is online at this point, but the nodes remain `NotReady` until a CNI plugin is installed.

Check the node status:

```bash
kubectl get nodes

kubectl get node \
  --output custom-columns='NAME:.metadata.name,STATUS:.status.conditions[?(@.type=="Ready")].message'
```

Expected output before installing Cilium is similar to:

```text
NAME                                STATUS
aks-nodepool1-00000000-vmss000000   container runtime network not ready: NetworkReady=false reason:NetworkPluginNotReady message:Network plugin returns error: cni plugin not initialized
```

This `NotReady` state and the `cni plugin not initialized` message are expected. They indicate that kubelet is waiting for the BYO CNI plugin, not that AKS provisioning failed. The nodes transition to `Ready` after Cilium is installed and initialized successfully.

## 2. Install the Cilium CLI

The following commands retrieve the latest stable CLI version from the official Cilium repository and verify the downloaded archive. Both x86_64 and ARM64 Linux are supported:

```bash
CILIUM_CLI_VERSION="$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)"

case "$(uname -m)" in
  x86_64) CLI_ARCH="amd64" ;;
  aarch64|arm64) CLI_ARCH="arm64" ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

curl -L --fail --remote-name-all \
  "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz"{,.sha256sum}

sha256sum --check "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"
sudo tar xzvfC "cilium-linux-${CLI_ARCH}.tar.gz" /usr/local/bin
rm "cilium-linux-${CLI_ARCH}.tar.gz" "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"

cilium version --client
```

You will see output like below:
```text
cilium-cli: v0.20.1 compiled with go1.27.1 on linux/amd64
cilium image (default): v1.20.1
cilium image (stable): v1.20.2
```

## 3. Install Cilium

Set the same resource group and cluster name that you used to create AKS:

```bash
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-aks-byocni}"
CLUSTER_NAME="${CLUSTER_NAME:-aksbyocni}"
```

The `createcluster-byocni.sh` script already runs `az aks get-credentials --overwrite-existing`, so you do not need to run it again when the script completes successfully. You can confirm that the current kubeconfig points to the cluster:

```bash
kubectl config current-context
kubectl get nodes
```

The nodes can still show `NotReady` at this point because Cilium has not been installed yet.

If the script's credential step failed, or if you are continuing from a different machine, user account, or shell environment without the generated kubeconfig, retrieve the credentials manually:

```bash
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --overwrite-existing
```

Retrieve the current stable Cilium version and install it:

```bash
CILIUM_VERSION="$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium/main/stable.txt)"

cilium install \
  --version "${CILIUM_VERSION#v}" \
  --set aksbyocni.enabled=true \
  --set azure.resourceGroup="$RESOURCE_GROUP" \
  --set kubeProxyReplacement=true \
  --set hubble.enabled=true
```

You will see the output for cilium install as below:

```text
🔮 Auto-detected Kubernetes kind: AKS
ℹ️  Using Cilium version 1.16.4
🔮 Auto-detected cluster name: aksbyocni
✅ Derived Azure subscription ID <REDACTED> from subscription <REDACTED>
✅ Detected Azure AKS cluster in BYOCNI mode (no CNI plugin pre-installed)
🔮 Auto-detected kube-proxy has been installed
```

Wait for Cilium to become ready:

```bash
cilium status --wait --wait-duration 10m
```
You will see a successful cilium status as below:
```text
    /¯¯\
 /¯¯\__/¯¯\    Cilium:             OK
 \__/¯¯\__/    Operator:           OK
 /¯¯\__/¯¯\    Envoy DaemonSet:    OK
 \__/¯¯\__/    Hubble Relay:       disabled
    \__/       ClusterMesh:        disabled

DaemonSet              cilium                   Desired: 3, Ready: 3/3, Available: 3/3
DaemonSet              cilium-envoy             Desired: 3, Ready: 3/3, Available: 3/3
Deployment             cilium-operator          Desired: 1, Ready: 1/1, Available: 1/1
Containers:            cilium                   Running: 3
                       cilium-envoy             Running: 3
                       cilium-operator          Running: 1
                       clustermesh-apiserver
                       hubble-relay
Cluster Pods:          6/6 managed by Cilium
Helm chart version:    1.16.4
Image versions         cilium             quay.io/cilium/cilium:v1.16.4@sha256:d55ec38938854133e06739b1af237932b9c4dd4e75e9b7b2ca3acc72540a44bf: 3
                       cilium-envoy       quay.io/cilium/cilium-envoy:v1.30.7-1731393961-97edc2815e2c6a174d3d12e71731d54f5d32ea16@sha256:0287b36f70cfbdf54f894160082f4f94d1ee1fb10389f3a95baa6c8e448586ed: 3
                       cilium-operator    quay.io/cilium/operator-generic:v1.16.4@sha256:c55a7cbe19fe0b6b28903a085334edb586a3201add9db56d2122c8485f7a51c5: 1
```

## 4. Test the Installation

### 4.1 Check the Nodes and Cilium Pods

```bash
kubectl get nodes -o wide
kubectl get pods --namespace kube-system -l k8s-app=cilium -o wide
```

Expected results:

- All nodes have the `Ready` status.
- Each node has one Cilium pod with the `Running` status.

```text
NAME                                STATUS   ROLES    AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION             CONTAINER-RUNTIME
aks-nodepool1-22698053-vmss000000   Ready    <none>   84m   v1.36.3   10.224.0.4    <none>        Ubuntu 24.04.4 LTS   6.8.0-1067-azure (amd64)   containerd://2.3.3-2
aks-nodepool1-22698053-vmss000001   Ready    <none>   84m   v1.36.3   10.224.0.6    <none>        Ubuntu 24.04.4 LTS   6.8.0-1067-azure (amd64)   containerd://2.3.3-2
aks-nodepool1-22698053-vmss000002   Ready    <none>   84m   v1.36.3   10.224.0.5    <none>        Ubuntu 24.04.4 LTS   6.8.0-1067-azure (amd64)   containerd://2.3.3-2

NAME           READY   STATUS    RESTARTS      AGE   IP           NODE                                NOMINATED NODE   READINESS GATES
cilium-2tzw9   1/1     Running   1 (50m ago)   62m   10.224.0.4   aks-nodepool1-22698053-vmss000000   <none>           <none>
cilium-4skwd   1/1     Running   0             62m   10.224.0.6   aks-nodepool1-22698053-vmss000001   <none>           <none>
cilium-vws8p   1/1     Running   0             62m   10.224.0.5   aks-nodepool1-22698053-vmss000002   <none>           <none>
```

### 4.2 Validate Pod Networking and NetworkPolicy Enforcement

This test deploys an NGINX server and two client pods in a dedicated namespace. Both clients can initially reach the server. A Kubernetes `NetworkPolicy` is then applied so that only the client labeled `access: allowed` can connect.

Create the test namespace and workloads:

```bash
kubectl create namespace cilium-policy-demo \
  --dry-run=client \
  --output yaml | kubectl apply -f -

kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: cilium-policy-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - name: http
              containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: cilium-policy-demo
spec:
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: v1
kind: Pod
metadata:
  name: allowed-client
  namespace: cilium-policy-demo
  labels:
    access: allowed
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.12.1
      command: ["sleep", "3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: denied-client
  namespace: cilium-policy-demo
  labels:
    access: denied
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.12.1
      command: ["sleep", "3600"]
EOF

kubectl rollout status deployment/web \
  --namespace cilium-policy-demo \
  --timeout 2m
kubectl wait \
  --namespace cilium-policy-demo \
  --for=condition=Ready \
  pod/allowed-client \
  pod/denied-client \
  --timeout 2m
```

Before applying a policy, verify that both clients can reach the service:

```bash
kubectl exec --namespace cilium-policy-demo allowed-client -- \
  curl --fail --silent --show-error --max-time 5 http://web

kubectl exec --namespace cilium-policy-demo denied-client -- \
  curl --fail --silent --show-error --max-time 5 http://web
```

Both commands should return the NGINX welcome page.

<!-- Screenshot 5: Paste the Markdown image syntax for successful access from both clients here. -->

Apply a policy that selects the `app: web` server pods and permits ingress on TCP port 80 only from pods labeled `access: allowed` in the same namespace:

```bash
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-labeled-client
  namespace: cilium-policy-demo
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              access: allowed
      ports:
        - protocol: TCP
          port: 80
EOF
```

Confirm that the allowed client still receives the NGINX page:

```bash
kubectl exec --namespace cilium-policy-demo allowed-client -- \
  curl --fail --silent --show-error --max-time 5 http://web
```

Confirm that the denied client can no longer connect:

```bash
if kubectl exec --namespace cilium-policy-demo denied-client -- \
  curl --fail --silent --show-error --max-time 5 http://web; then
  echo "ERROR: denied-client unexpectedly reached the web service"
  exit 1
else
  echo "PASS: NetworkPolicy blocked denied-client as expected"
fi
```

The allowed request should succeed. The denied request should time out and print:

```text
PASS: NetworkPolicy blocked denied-client as expected
```

<!-- Screenshot 6: Paste the Markdown image syntax for the allowed and denied NetworkPolicy results here. -->

Optionally, delete the policy and verify that connectivity from the denied client is restored:

```bash
kubectl delete networkpolicy allow-labeled-client \
  --namespace cilium-policy-demo

kubectl exec --namespace cilium-policy-demo denied-client -- \
  curl --fail --silent --show-error --max-time 5 http://web
```

Remove all resources created by this manual test:

```bash
kubectl delete namespace cilium-policy-demo
```

### 4.3 Run the Cilium Connectivity Test

```bash
cilium connectivity test
```

This command creates test workloads and validates pod-to-pod communication, services, DNS, and network policies. The command should report that the tests passed when it completes. It runs many tests so it requires a long time to complete. Once it completes, you should see test result like below:

```text
ℹ️  Monitor aggregation detected, will skip some flow validation steps
✨ [aksbyocni] Creating namespace cilium-test-1 for connectivity check...
✨ [aksbyocni] Deploying echo-same-node service...
✨ [aksbyocni] Deploying DNS test server configmap...
✨ [aksbyocni] Deploying same-node deployment...
✨ [aksbyocni] Deploying client deployment...
✨ [aksbyocni] Deploying client2 deployment...
✨ [aksbyocni] Deploying client3 deployment...
✨ [aksbyocni] Deploying echo-other-node service...
✨ [aksbyocni] Deploying other-node deployment...
✨ [host-netns] Deploying aksbyocni daemonset...
...
...
...
...
[=] [cilium-test-1] Test [check-log-errors] [129/129]
.........................

✅ [cilium-test-1] All 64 tests (597 actions) successful, 65 tests skipped, 0 scenarios skipped.
```

To delete the test namespace:

```bash
kubectl delete namespace cilium-test
```

## Clean Up Resources

Delete the resource group when you no longer need the environment:

```bash
az group delete \
  --name "${RESOURCE_GROUP:-rg-aks-byocni}" \
  --yes \
  --no-wait
```

## References

- [Azure AKS: Bring Your Own CNI](https://learn.microsoft.com/azure/aks/use-byo-cni)
- [Cilium: Installation Using Helm](https://docs.cilium.io/en/stable/installation/k8s-install-helm/)
- [Install the Cilium CLI](https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/)
- [Cilium: Network Policy](https://docs.cilium.io/en/stable/security/policy/)
- [Reference article: Azure AKS - BYO CNI with Cilium](https://cloud-cod.com/index.php/2026/02/16/azure-aks-byo-cni-with-cilium/)
