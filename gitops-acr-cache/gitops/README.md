# 最小 GitOps 演示

Git 提交 → Flux 同步 → AKS 自动部署。只使用公开 podinfo 镜像，不需要 ACR 或 GitHub 写入凭据，也不会自动扫描镜像标签。

本目录不再区分 apps / clusters，只保留：

- [`kustomization.yaml`](./kustomization.yaml)：同步入口，统一配置命名空间、镜像和副本数。
- [`resources.yaml`](./resources.yaml)：合并 Namespace、Deployment 和 LoadBalancer 类型的 Service，将服务端口 80 转发到容器端口 9898。

以下命令使用 PowerShell，在 `D:\HandsOn\acr-cache` 中执行。需要已有 AKS、Azure CLI、kubectl、Git、GitHub CLI，并已完成 `az login` / `gh auth login`。先确认 Azure 订阅及集群正确。

## 1. 发布到 GitHub

将两个 YAML 放到仓库的独立 `acrcache-demo` 目录，避免影响已有应用。无推送权限时先 Fork，并替换后续仓库地址。

```powershell
kubectl kustomize .\gitops
gh repo clone oxcp/gitops .\gitops-demo-checkout
if ($LASTEXITCODE -ne 0) { throw 'Clone failed.' }
git -C .\gitops-demo-checkout switch main
if ($LASTEXITCODE -ne 0) { throw 'Switch branch failed.' }
$target = '.\gitops-demo-checkout\acrcache-demo'
if (Test-Path $target) { throw "路径已存在，请先检查内容：$target" }
New-Item -ItemType Directory $target | Out-Null
Copy-Item .\gitops\kustomization.yaml, .\gitops\resources.yaml $target
kubectl kustomize $target
git -C .\gitops-demo-checkout add -- acrcache-demo
git -C .\gitops-demo-checkout diff --cached
git -C .\gitops-demo-checkout commit -m "Add minimal GitOps demo"
git -C .\gitops-demo-checkout push origin main
```

每条命令成功后再继续；需要 PR 时先合并，再配置 Flux。

## 2. 配置 AKS 同步

```powershell
$rg = 'rg-acrcache'
$aks = 'fluxaks-<SN>' # 替换为已有 AKS 的实际名称
$repoUrl = 'https://github.com/oxcp/gitops'
az aks get-credentials --resource-group $rg --name $aks
kubectl config current-context

# 仅缺少 CLI 扩展时安装
az extension add --name k8s-extension
az extension add --name k8s-configuration

# 集群已有 microsoft.flux 扩展时跳过
az k8s-extension create --resource-group $rg --cluster-name $aks `
    --cluster-type managedClusters --name flux --extension-type microsoft.flux

az k8s-configuration flux create --resource-group $rg --cluster-name $aks `
    --cluster-type managedClusters --name acrcache-demo `
    --namespace flux-system --scope cluster `
    --url $repoUrl --branch main --sync-interval 1m `
    --kustomization name=demo path=./acrcache-demo `
        prune=true sync_interval=1m timeout=5m
```

公开仓库不需要 PAT；私有仓库需另配读取凭据，不要写入 YAML。若 CLI 扩展报 `rpds.rpds` 错误，运行 [`Repair-AzureCli.ps1`](../Repair-AzureCli.ps1)，再设置：

```powershell
$env:AZURE_EXTENSION_DIR = (Resolve-Path .\generated\azure-cli-extensions).Path
```

**已有旧版演示时：** 先发布新目录，再将已有 `acrcache-demo` Flux 配置的 `demo` 同步路径从 `./clusters/acrcache-demo` 改为 `./acrcache-demo`；确认同步成功后，才删除仓库旧的 `apps/acrcache-demo` 和 `clusters/acrcache-demo`。不要删除其他应用目录或同时保留两个同步配置管理本例资源。

## 3. 查看效果并演示更新

部署后运行 `kubectl -n gitops-demo get svc podinfo --watch`，等待 `EXTERNAL-IP` 分配完成后，通过 `http://<EXTERNAL-IP>` 访问。LoadBalancer 可能产生额外费用；也可使用以下端口转发方式访问。

```powershell
kubectl -n gitops-demo wait --for=create deployment/podinfo --timeout=300s
kubectl -n gitops-demo rollout status deployment/podinfo --timeout=300s
kubectl -n gitops-demo port-forward svc/podinfo 8080:80
```

打开 <http://localhost:8080>，看到 `Hello GitOps`；按 `Ctrl+C` 停止端口转发。

后续修改的是 **`gitops-demo-checkout\acrcache-demo` 中的仓库文件**：

1. 在 `kustomization.yaml` 中把 `count: 1` 改为 `count: 2`。
2. 在 `resources.yaml` 中把 `Hello GitOps` 改为 `Updated by Git`。
3. 提交并推送：

```powershell
git -C .\gitops-demo-checkout add -- acrcache-demo
git -C .\gitops-demo-checkout diff --cached
git -C .\gitops-demo-checkout commit -m "Demo GitOps update"
git -C .\gitops-demo-checkout push origin main
kubectl -n gitops-demo get deployment podinfo --watch
```

约 1–3 分钟后应有 2 个就绪副本。退出观察，重新端口转发并刷新页面，应看到新文字。无需执行 `kubectl apply`。

- **漂移恢复：** 执行 `kubectl -n gitops-demo scale deployment podinfo --replicas=3`，Flux 下次调谐会恢复为 Git 中的 2。
- **回滚：** 对应用变更执行 `git revert <commit-sha>` 并推送。
- **排查：** 查看 `kubectl -n flux-system get gitrepositories,kustomizations`；Pod 异常时用 `kubectl -n gitops-demo describe pod <pod-name>` 检查事件与 GHCR 访问。

## 4. 清理与可选 ACR

`prune=true` 会删除 Git 中已移除的受管资源；本例 Namespace 不要放其他应用。结束时先删除本例 Flux 配置，确认成功后再删命名空间，避免重建：

```powershell
az k8s-configuration flux delete --resource-group $rg --cluster-name $aks `
    --cluster-type managedClusters --name acrcache-demo --yes
kubectl delete namespace gitops-demo
```

之后可提交删除仓库的 `acrcache-demo`。不要删除共享 Flux 扩展或无关资源；保留的 Azure 资源仍会产生费用。

切换 ACR 时，在仓库 `kustomization.yaml` 中将 `newName` 改为实际下游 ACR 的镜像地址，`newTag` 改为已有标签，再提交。先确认缓存规则和 AKS 拉取权限就绪。

本例仍需手工修改标签并提交；完整的“扫描上游 → 自动提交 → 下游缓存拉取”使用上级 [`README.md`](../README.md) 和 [`Deploy.ps1`](../Deploy.ps1)，不要混用两套清单。
