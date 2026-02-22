param(
    [int]$AutoCloseSeconds = 0
)

$ErrorActionPreference = 'Stop'

if (-not $PSScriptRoot) {
    $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

$startScript = Join-Path $PSScriptRoot 'Start.ps1'
if (-not (Test-Path $startScript)) {
    throw "Start.ps1 not found at: $startScript"
}

& $startScript -AutoCloseSeconds $AutoCloseSeconds
