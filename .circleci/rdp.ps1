# Temporary Windows RDP access for CircleCI build troubleshooting.
# Required CircleCI project secrets:
#   TAILSCALE_AUTHKEY - preferably a one-use ephemeral auth key
#   RDP_PASSWORD     - a unique strong password (16+ characters)
# RDP is restricted to the Tailscale CGNAT range, not public internet.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($env:TAILSCALE_AUTHKEY)) {
    throw 'Set TAILSCALE_AUTHKEY under CircleCI Project Settings > Environment Variables.'
}
if ([string]::IsNullOrWhiteSpace($env:RDP_PASSWORD) -or $env:RDP_PASSWORD.Length -lt 16) {
    throw 'Set RDP_PASSWORD (16+ characters) under CircleCI Project Settings > Environment Variables.'
}

Write-Host 'Installing the signed Tailscale Windows client...'
$msi = Join-Path $env:TEMP 'tailscale-setup-amd64.msi'
Invoke-WebRequest -Uri 'https://pkgs.tailscale.com/stable/tailscale-setup-1.104.7-amd64.msi' -OutFile $msi -UseBasicParsing
$signature = Get-AuthenticodeSignature -FilePath $msi
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Tailscale') {
    throw "Tailscale installer signature verification failed: $($signature.Status)"
}
$install = Start-Process -FilePath 'msiexec.exe' -ArgumentList ('/i "' + $msi + '" /qn /norestart TS_UNATTENDEDMODE=always TS_NOLAUNCH=1') -Wait -PassThru
if ($install.ExitCode -notin @(0, 3010)) {
    throw "Tailscale MSI install failed with exit code $($install.ExitCode)"
}

$tailscale = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
if (-not (Test-Path $tailscale)) { throw 'Tailscale CLI was not installed.' }
Start-Service -Name Tailscale -ErrorAction SilentlyContinue
Start-Sleep -Seconds 4
& $tailscale up "--authkey=$env:TAILSCALE_AUTHKEY" --hostname=circleci-rdp --reset
if ($LASTEXITCODE -ne 0) { throw 'Tailscale login failed. Check the auth key and your tailnet approval policy.' }
$ip = (& $tailscale ip -4 | Select-Object -First 1).Trim()
if ($ip -notmatch '^100\.') { throw 'No valid Tailscale IPv4 was assigned.' }

Write-Host 'Creating a dedicated local RDP account...'
$user = 'circleci-rdp'
$password = ConvertTo-SecureString $env:RDP_PASSWORD -AsPlainText -Force
$existing = Get-LocalUser -Name $user -ErrorAction SilentlyContinue
if ($null -eq $existing) {
    New-LocalUser -Name $user -Password $password -PasswordNeverExpires | Out-Null
} else {
    Set-LocalUser -Name $user -Password $password -PasswordNeverExpires $true
}
Add-LocalGroupMember -Group 'Remote Desktop Users' -Member $user -ErrorAction SilentlyContinue

$terminalServer = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
Set-ItemProperty -Path $terminalServer -Name 'fDenyTSConnections' -Value 0
Set-ItemProperty -Path "$terminalServer\WinStations\RDP-Tcp" -Name 'UserAuthentication' -Value 1
Set-ItemProperty -Path "$terminalServer\WinStations\RDP-Tcp" -Name 'SecurityLayer' -Value 2

# Never enable RDP on the runner's public network.
Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue |
    Disable-NetFirewallRule -ErrorAction SilentlyContinue
New-NetFirewallRule -Name 'CircleCI-Tailscale-RDP-TCP' -DisplayName 'CircleCI RDP via Tailscale' `
    -Enabled True -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3389 `
    -RemoteAddress '100.64.0.0/10' -Profile Any | Out-Null
Start-Service -Name TermService -ErrorAction SilentlyContinue

if (-not (Test-NetConnection -ComputerName '127.0.0.1' -Port 3389 -InformationLevel Quiet)) {
    throw 'RDP is not listening locally on TCP/3389.'
}

Write-Host '========== RDP READY =========='
Write-Host "Computer: $ip"
Write-Host "User name: .\$user"
Write-Host 'Password: the RDP_PASSWORD secret set in CircleCI (never printed)'
Write-Host 'Tailscale is required on your local PC.'
Write-Host 'Access window: approximately 45 minutes; the VM is destroyed when the job ends.'
Write-Host '==============================='

try {
    for ($minute = 1; $minute -le 45; $minute++) {
        Write-Host "Secure RDP session active: minute $minute of 45."
        Start-Sleep -Seconds 60
    }
} finally {
    & $tailscale down | Out-Null
}
