#Requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('Render', 'Infrastructure', 'GitOps')]
    [string] $Phase = 'Render',
    [ValidatePattern('^[0-9]{8}$')]
    [string] $SN,
    [string] $SubscriptionId,
    [ValidatePattern('^[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$')]
    [string] $ImageRepository = 'demo/podinfo',
    [string] $SeedImage = 'ghcr.io/stefanprodan/podinfo:6.9.2',
    [switch] $SkipSeedImage,
    [string] $GitHubUser = $env:FLUX_GITHUB_USER,
    [string] $AzureExtensionDirectory = (Join-Path $PSScriptRoot 'generated\azure-cli-extensions'),
    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'generated')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Checked {
    param([string] $Command, [string[]] $Arguments)
    $previousExtensionDirectory = $env:AZURE_EXTENSION_DIR
    try {
        if ($Command -eq 'az' -and (Test-Path $AzureExtensionDirectory)) {
            $env:AZURE_EXTENSION_DIR = [IO.Path]::GetFullPath($AzureExtensionDirectory)
        }
        $result = & $Command @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "$Command failed with exit code $LASTEXITCODE. See the preceding diagnostic."
        }
        return $result
    }
    finally {
        $env:AZURE_EXTENSION_DIR = $previousExtensionDirectory
    }
}

function Invoke-Az {
    param([string[]] $Arguments)
    Invoke-Checked 'az' ($Arguments + @('--subscription', $SubscriptionId, '--only-show-errors'))
}

$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$statePath = Join-Path $OutputDirectory 'environment.json'
if ($Phase -eq 'GitOps' -and -not (Test-Path $statePath)) {
    throw 'Render and provision the environment first; GitOps requires the saved environment.json.'
}
if (Test-Path $statePath) {
    $previous = Get-Content $statePath -Raw | ConvertFrom-Json
    if ($SN -and $SN -ne $previous.sn) {
        throw 'SN differs from the saved environment. Use a different OutputDirectory for another environment.'
    }
    if ($ImageRepository -ne $previous.imageRepository) {
        throw 'ImageRepository differs from the saved environment. Supply the original value.'
    }
    if ($SubscriptionId -and $previous.subscriptionId -and $SubscriptionId -ne $previous.subscriptionId) {
        throw 'SubscriptionId differs from the saved environment.'
    }
    $SN = $previous.sn
    if (-not $SubscriptionId) { $SubscriptionId = $previous.subscriptionId }
}
if (-not $SN) { $SN = [string](Get-Random -Minimum 10000000 -Maximum 100000000) }
if ($Phase -ne 'Render' -and -not $SubscriptionId) {
    throw 'Supply -SubscriptionId explicitly before provisioning or configuring Azure resources.'
}
if ($SubscriptionId -and $SubscriptionId -notmatch '^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
    throw 'SubscriptionId must be a subscription GUID, not a display name.'
}

$rg = 'rg-acrcache'
$location = 'westus2'
$aks = "fluxaks-$SN"
$up = "acrup$SN"
$down = "acrdown$SN"
$cacheIdentity = "acrcache-identity-$SN"
$configuration = "acrcache-$SN"
$namespace = "acrcache-$SN"
$policy = "podinfo-$SN"
$writer = "acrcache-writer-$SN"
$gitOpsPath = "clusters/acrcache-$SN"
$gitUrl = 'https://github.com/oxcp/gitops'
$branch = 'main'
$secret = "gitops-auth-$SN"
$clusterDirectory = Join-Path $OutputDirectory "manifests\clusters\acrcache-$SN"
$state = [ordered]@{
    sn = $SN
    subscriptionId = $SubscriptionId
    resourceGroup = $rg
    location = $location
    aks = $aks
    upstreamAcr = $up
    downstreamAcr = $down
    cacheIdentity = $cacheIdentity
    imageRepository = $ImageRepository
    upstreamLoginServer = "$up.azurecr.io"
    downstreamLoginServer = "$down.azurecr.io"
    gitUrl = $gitUrl
    branch = $branch
    gitOpsPath = $gitOpsPath
    configuration = $configuration
    namespace = $namespace
    imagePolicy = $policy
    writer = $writer
    gitSecret = $secret
}
if (Test-Path $statePath) {
    $state.upstreamLoginServer = $previous.upstreamLoginServer
    $state.downstreamLoginServer = $previous.downstreamLoginServer
}

function Write-Templates {
    New-Item -ItemType Directory -Force $clusterDirectory | Out-Null
    $files = @{
        'kustomization.yaml' = @'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - automation
  - apps
'@
        'automation\kustomization.yaml' = @'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gitrepository.yaml
  - images.yaml
'@
        'automation\gitrepository.yaml' = @"
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: $writer
  namespace: flux-system
spec:
  interval: 1m
  timeout: 2m
  url: $gitUrl
  ref:
    branch: $branch
  secretRef:
    name: $secret
"@
        'automation\images.yaml' = @"
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageRepository
metadata:
  name: $policy
  namespace: flux-system
spec:
  interval: 1m
  image: $($state.upstreamLoginServer)/$ImageRepository
  provider: azure
---
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImagePolicy
metadata:
  name: $policy
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: $policy
  policy:
    semver:
      range: '>=1.0.0 <2.0.0'
---
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageUpdateAutomation
metadata:
  name: $policy
  namespace: flux-system
spec:
  interval: 1m
  sourceRef:
    kind: GitRepository
    name: $writer
  git:
    checkout:
      ref:
        branch: $branch
    commit:
      author:
        name: fluxcdbot
        email: fluxcdbot@users.noreply.github.com
      messageTemplate: 'chore(images): update cached podinfo tag'
    push:
      branch: $branch
  update:
    path: ./$gitOpsPath/apps
    strategy: Setters
"@
        'apps\kustomization.yaml' = @"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - deployment.yaml
  - service.yaml
images:
  - name: podinfo
    newName: $($state.downstreamLoginServer)/$ImageRepository
    newTag: '1.0.0' # {`"`$imagepolicy`": `"flux-system:${policy}:tag`"}
"@
        'apps\namespace.yaml' = @"
apiVersion: v1
kind: Namespace
metadata:
  name: $namespace
"@
        'apps\deployment.yaml' = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo
  namespace: $namespace
spec:
  replicas: 1
  selector:
    matchLabels:
      app: podinfo
  template:
    metadata:
      labels:
        app: podinfo
    spec:
      containers:
        - name: podinfo
          image: podinfo
          imagePullPolicy: Always
          ports:
            - name: http
              containerPort: 9898
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 128Mi
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ['ALL']
"@
        'apps\service.yaml' = @"
apiVersion: v1
kind: Service
metadata:
  name: podinfo
  namespace: $namespace
spec:
  type: ClusterIP
  selector:
    app: podinfo
  ports:
    - name: http
      port: 9898
      targetPort: http
"@
    }
    foreach ($entry in $files.GetEnumerator()) {
        $path = Join-Path $clusterDirectory $entry.Key
        New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
        [IO.File]::WriteAllText($path, ($entry.Value.Replace("`r`n", "`n") + "`n"))
    }
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json) + "`n")
}

if ($Phase -eq 'Render') {
    Write-Templates
    Write-Host "Rendered $clusterDirectory"
    Write-Host "Environment: $statePath"
    return
}

Get-Command az -ErrorAction Stop | Out-Null
$version = Invoke-Checked 'az' @('version', '-o', 'json') | ConvertFrom-Json
if ([version]$version.'azure-cli' -lt [version]'2.85.0') {
    throw 'ACR-to-ACR managed identity caching requires Azure CLI 2.85.0 or later.'
}
foreach ($extension in @('k8s-extension', 'k8s-configuration')) {
    Invoke-Checked 'az' @('extension', 'show', '-n', $extension, '-o', 'none') | Out-Null
}
# Check extension imports before creating billable resources.
Invoke-Checked 'az' @('k8s-extension', 'create', '-h') | Out-Null
Invoke-Checked 'az' @('k8s-configuration', 'flux', 'create', '-h') | Out-Null
$account = Invoke-Az @('account', 'show', '-o', 'json') | ConvertFrom-Json
if ($account.id -ne $SubscriptionId) { throw 'Azure CLI did not resolve the requested subscription.' }

if ($Phase -eq 'Infrastructure') {
    Write-Templates
    foreach ($provider in @(
        'Microsoft.ContainerService', 'Microsoft.ContainerRegistry',
        'Microsoft.ManagedIdentity', 'Microsoft.KubernetesConfiguration'
    )) {
        Invoke-Az @('provider', 'register', '--namespace', $provider, '--wait', '-o', 'none')
    }
    Invoke-Az @('group', 'create', '-n', $rg, '-l', $location, '-o', 'none')
    $upstream = Invoke-Az @(
        'acr', 'create', '-g', $rg, '-n', $up, '-l', $location, '--sku', 'Standard',
        '--admin-enabled', 'false', '--role-assignment-mode', 'rbac-abac', '-o', 'json'
    ) | ConvertFrom-Json
    $state.upstreamLoginServer = $upstream.loginServer
    Write-Templates
    $downstream = Invoke-Az @(
        'acr', 'create', '-g', $rg, '-n', $down, '-l', $location, '--sku', 'Premium',
        '--admin-enabled', 'false', '--role-assignment-mode', 'rbac', '-o', 'json'
    ) | ConvertFrom-Json
    $state.downstreamLoginServer = $downstream.loginServer
    Write-Templates
    $identity = Invoke-Az @(
        'identity', 'create', '-g', $rg, '-n', $cacheIdentity, '-l', $location, '-o', 'json'
    ) | ConvertFrom-Json
    $cluster = Invoke-Az @(
        'aks', 'create', '-g', $rg, '-n', $aks, '-l', $location, '--node-count', '2',
        '--node-vm-size', 'Standard_D2s_v5', '--enable-managed-identity', '--generate-ssh-keys',
        '--attach-acr', $downstream.id, '-o', 'json'
    ) | ConvertFrom-Json
    $condition = "( (!(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/content/read'}) AND !(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/metadata/read'})) OR (@Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase '$ImageRepository') )"
    foreach ($principal in @($identity.principalId, $cluster.identityProfile.kubeletidentity.objectId)) {
        Invoke-Az @(
            'role', 'assignment', 'create', '--assignee-object-id', $principal,
            '--assignee-principal-type', 'ServicePrincipal', '--scope', $upstream.id,
            '--role', 'Container Registry Repository Reader',
            '--condition', $condition, '--condition-version', '2.0', '-o', 'none'
        )
    }
    Invoke-Az @(
        'acr', 'cache', 'create', '-g', $rg, '-r', $down, '-n', "upstream-$SN",
        '-s', "$($upstream.loginServer)/$ImageRepository", '-t', $ImageRepository,
        '--identity', $identity.id, '-o', 'none'
    )
    if (-not $SkipSeedImage) {
        Invoke-Az @(
            'acr', 'import', '-n', $up, '--source', $SeedImage,
            '--image', "${ImageRepository}:1.0.0", '-o', 'none'
        )
    }
    Write-Host "Infrastructure provisioned. Publish $gitOpsPath to $gitUrl ($branch), then run -Phase GitOps."
    return
}

Get-Command kubectl, gh -ErrorAction Stop | Out-Null
if (-not $GitHubUser -or -not $env:FLUX_GITHUB_TOKEN) {
    throw 'Set FLUX_GITHUB_USER and FLUX_GITHUB_TOKEN (repository Contents read/write) before configuring GitOps.'
}
Invoke-Checked 'gh' @(
    'api', "repos/oxcp/gitops/contents/${gitOpsPath}/kustomization.yaml?ref=$branch",
    '--jq', '.path'
) | Out-Null

$oldKubeconfig = $env:KUBECONFIG
$kubeconfig = Join-Path $OutputDirectory "$aks.kubeconfig"
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
try {
    $env:KUBECONFIG = $kubeconfig
    Invoke-Az @('aks', 'get-credentials', '-g', $rg, '-n', $aks, '--file', $kubeconfig, '--overwrite-existing', '-o', 'none')
    Invoke-Az @(
        'k8s-extension', 'create', '-g', $rg, '-c', $aks, '-t', 'managedClusters',
        '--name', 'flux', '--extension-type', 'microsoft.flux', '--config',
        'image-reflector-controller.enabled=true', 'image-automation-controller.enabled=true',
        'useKubeletIdentity=true', '-o', 'none'
    )
    foreach ($controller in @('image-reflector-controller', 'image-automation-controller', 'source-controller', 'kustomize-controller')) {
        Invoke-Checked 'kubectl' @('-n', 'flux-system', 'wait', '--for=create', "deployment/$controller", '--timeout=300s')
        Invoke-Checked 'kubectl' @('-n', 'flux-system', 'rollout', 'status', "deployment/$controller", '--timeout=300s')
    }
    foreach ($crd in @(
        'imagerepositories.image.toolkit.fluxcd.io', 'imagepolicies.image.toolkit.fluxcd.io',
        'imageupdateautomations.image.toolkit.fluxcd.io'
    )) {
        $definition = Invoke-Checked 'kubectl' @('get', 'crd', $crd, '-o', 'json') | ConvertFrom-Json
        if (-not @($definition.spec.versions | Where-Object { $_.name -eq 'v1' -and $_.served }).Count) {
            throw "$crd does not serve v1. Upgrade to a compatible microsoft.flux extension before publishing these templates."
        }
    }
    $gitSecret = @{
        apiVersion = 'v1'
        kind = 'Secret'
        metadata = @{ name = $secret; namespace = 'flux-system' }
        type = 'Opaque'
        stringData = @{ username = $GitHubUser; password = $env:FLUX_GITHUB_TOKEN }
    }
    # Pass credentials on stdin, never on the process command line or into a file.
    $gitSecret | ConvertTo-Json -Depth 5 -Compress | & kubectl apply -f - -o name
    if ($LASTEXITCODE -ne 0) { throw 'Failed to persist the Git authentication secret.' }
    Invoke-Az @(
        'k8s-configuration', 'flux', 'create', '-g', $rg, '-c', $aks,
        '-t', 'managedClusters', '-n', $configuration, '--namespace', 'flux-system',
        '--scope', 'cluster', '-u', $gitUrl, '--branch', $branch,
        '--local-auth-ref', $secret, '--sync-interval', '1m',
        '--kustomization', 'name=demo', "path=./$gitOpsPath", 'prune=true',
        'sync_interval=1m', 'timeout=5m', '-o', 'none'
    )
    foreach ($resource in @("gitrepository/$writer", "imagerepository/$policy", "imagepolicy/$policy", "imageupdateautomation/$policy")) {
        Invoke-Checked 'kubectl' @('-n', 'flux-system', 'wait', $resource, '--for=create', '--timeout=300s')
        Invoke-Checked 'kubectl' @('-n', 'flux-system', 'wait', $resource, '--for=condition=Ready', '--timeout=300s')
    }
    Invoke-Checked 'kubectl' @('-n', $namespace, 'wait', 'deployment/podinfo', '--for=create', '--timeout=300s')
    Invoke-Checked 'kubectl' @('-n', $namespace, 'rollout', 'status', 'deployment/podinfo', '--timeout=300s')
    Invoke-Az @('acr', 'cache', 'show', '-r', $down, '-n', "upstream-$SN", '-o', 'table')
    Invoke-Az @('k8s-configuration', 'flux', 'show', '-g', $rg, '-c', $aks, '-t', 'managedClusters', '-n', $configuration, '-o', 'table')
    Write-Host "GitOps configured. Use $statePath and README.md for the new-tag/cache acceptance check."
}
finally {
    $env:KUBECONFIG = $oldKubeconfig
}
