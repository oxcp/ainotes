#Requires -Version 7.2
[CmdletBinding()]
param(
    [string] $AzureExtensionDirectory = (Join-Path $PSScriptRoot 'generated\azure-cli-extensions')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Get-Command az -ErrorAction Stop | Out-Null
$previousExtensionDirectory = $env:AZURE_EXTENSION_DIR
try {
    $env:AZURE_EXTENSION_DIR = [IO.Path]::GetFullPath($AzureExtensionDirectory)
    New-Item -ItemType Directory -Force $env:AZURE_EXTENSION_DIR | Out-Null
    foreach ($extension in @('k8s-extension', 'k8s-configuration')) {
        & az extension add --name $extension --upgrade --yes --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw "Failed to install isolated extension $extension." }
    }
    & az k8s-extension create -h | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The isolated k8s-extension still fails to load.' }
    & az k8s-configuration flux create -h | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The isolated k8s-configuration still fails to load.' }
    Write-Host "Verified isolated Azure CLI extensions: $env:AZURE_EXTENSION_DIR"
    Write-Host 'Deploy.ps1 uses this default project directory automatically; no cloud resources were created.'
}
finally {
    $env:AZURE_EXTENSION_DIR = $previousExtensionDirectory
}
