#Requires -Version 7.2
[CmdletBinding()]
param(
    [string] $StatePath = (Join-Path $PSScriptRoot 'generated\environment.json'),
    [Parameter(Mandatory)]
    [ValidatePattern('^1\.[0-9]+\.[0-9]+$')]
    [string] $ExpectedTag
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$state = Get-Content $StatePath -Raw | ConvertFrom-Json
if (-not $state.subscriptionId) { throw 'Provision the saved environment before verification.' }
Get-Command az, kubectl, gh -ErrorAction Stop | Out-Null

function Invoke-Checked {
    param([string] $Command, [string[]] $Arguments)
    $result = & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE." }
    return $result
}

$oldKubeconfig = $env:KUBECONFIG
try {
    $env:KUBECONFIG = Join-Path (Split-Path ([IO.Path]::GetFullPath($StatePath))) "$($state.aks).kubeconfig"
    if (-not (Test-Path $env:KUBECONFIG)) { throw 'Run Deploy.ps1 -Phase GitOps to create the dedicated kubeconfig first.' }
    $expectedImage = "$($state.downstreamLoginServer)/$($state.imageRepository):$ExpectedTag"
    Invoke-Checked 'kubectl' @(
        '-n', 'flux-system', 'wait', "imagepolicy/$($state.imagePolicy)",
        "--for=jsonpath={.status.latestRef.tag}=$ExpectedTag", '--timeout=600s'
    )
    Invoke-Checked 'kubectl' @(
        '-n', $state.namespace, 'wait', 'deployment/podinfo',
        "--for=jsonpath={.spec.template.spec.containers[0].image}=$expectedImage", '--timeout=600s'
    )
    Invoke-Checked 'kubectl' @('-n', $state.namespace, 'rollout', 'status', 'deployment/podinfo', '--timeout=300s')
    $automation = Invoke-Checked 'kubectl' @(
        '-n', 'flux-system', 'get', 'imageupdateautomation', $state.imagePolicy, '-o', 'json'
    ) | ConvertFrom-Json
    $commitProperty = $automation.status.PSObject.Properties['lastPushCommit']
    if (-not $commitProperty -or -not $commitProperty.Value) {
        throw 'No image-automation Git push is recorded. A healthy workload alone does not prove automatic commits.'
    }
    $commit = $commitProperty.Value
    $committedApps = Invoke-Checked 'gh' @(
        'api', "repos/oxcp/gitops/contents/$($state.gitOpsPath)/apps/kustomization.yaml?ref=$commit",
        '-H', 'Accept: application/vnd.github.raw+json'
    )
    $tagPattern = "(?m)^\s*newTag:\s*['`"]?$([regex]::Escape($ExpectedTag))['`"]?(?:\s|$)"
    if (($committedApps -join "`n") -notmatch $tagPattern) {
        throw "The recorded automatic commit $commit does not contain the expected tag."
    }
    $digests = foreach ($registry in @($state.upstreamAcr, $state.downstreamAcr)) {
        $digest = Invoke-Checked 'az' @(
            'acr', 'repository', 'show', '-n', $registry,
            '--image', "$($state.imageRepository):$ExpectedTag", '--query', 'digest', '-o', 'tsv',
            '--subscription', $state.subscriptionId, '--only-show-errors'
        )
        if (-not $digest) { throw "No manifest digest returned by $registry." }
        ($digest -join '').Trim()
    }
    if ($digests[0] -ne $digests[1]) { throw 'Upstream and downstream manifest digests differ.' }
    Write-Host "Verified tag $ExpectedTag, automatic Git commit $commit, AKS rollout, and cache digest $($digests[0])."
}
finally {
    $env:KUBECONFIG = $oldKubeconfig
}
