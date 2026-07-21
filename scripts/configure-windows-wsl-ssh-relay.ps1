[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$RuleName = 'PaperTerm WSL SSH over Tailscale'
$Tailscale = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated Windows PowerShell session.'
    }
}

function Get-TailscaleIPv4 {
    if (-not (Test-Path -LiteralPath $Tailscale -PathType Leaf)) {
        throw 'The Windows Tailscale CLI is not installed in the expected location.'
    }
    $status = (& $Tailscale status --json | ConvertFrom-Json)
    if ($status.BackendState -ne 'Running' -or -not $status.Self.Online) {
        throw 'Windows Tailscale is not online.'
    }
    $address = @($status.Self.TailscaleIPs | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })[0]
    if (-not $address) { throw 'Windows Tailscale has no IPv4 address.' }
    $octets = @($address.Split('.') | ForEach-Object { [int]$_ })
    if ($octets[0] -ne 100 -or $octets[1] -lt 64 -or $octets[1] -gt 127) {
        throw 'Refusing to bind: the discovered address is outside the Tailscale CGNAT range.'
    }
    return $address
}

Assert-Administrator
$listenAddress = Get-TailscaleIPv4

if ($Remove) {
    if ($PSCmdlet.ShouldProcess($listenAddress, 'Remove the PaperTerm WSL SSH port proxy')) {
        & netsh interface portproxy delete v4tov4 listenaddress=$listenAddress listenport=22 protocol=tcp | Out-Null
        Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    }
    Write-Host 'PaperTerm WSL SSH relay removed.'
    exit 0
}

$loopbackListener = Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalAddress -in @('127.0.0.1', '::1') } |
    Select-Object -First 1
if (-not $loopbackListener) { throw 'WSL relay is not listening on loopback port 22.' }
$owner = Get-Process -Id $loopbackListener.OwningProcess -ErrorAction Stop
if ($owner.ProcessName -ne 'wslrelay') {
    throw 'Loopback port 22 is not owned by the expected WSL relay.'
}

if ($PSCmdlet.ShouldProcess($listenAddress, 'Configure the PaperTerm WSL SSH port proxy')) {
    Set-Service -Name iphlpsvc -StartupType Automatic
    Start-Service -Name iphlpsvc
    & netsh interface portproxy delete v4tov4 listenaddress=$listenAddress listenport=22 protocol=tcp 2>$null | Out-Null
    & netsh interface portproxy add v4tov4 listenaddress=$listenAddress listenport=22 connectaddress=127.0.0.1 connectport=22 protocol=tcp | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Windows failed to create the Tailscale-only port proxy.'
    }

    Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule `
        -DisplayName $RuleName `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalAddress $listenAddress `
        -LocalPort 22 `
        -RemoteAddress '100.64.0.0/10' `
        -Profile Any | Out-Null
}

$listener = Get-NetTCPConnection -State Listen -LocalAddress $listenAddress -LocalPort 22 -ErrorAction SilentlyContinue
if (-not $listener -and -not $WhatIfPreference) {
    throw 'The Tailscale-only port-22 listener did not start.'
}
Write-Host 'PaperTerm WSL SSH relay is restricted to the Windows Tailscale address and tailnet sources.'
