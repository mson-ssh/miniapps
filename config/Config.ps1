# ================================================================================
#                    MINIAZ SYSTEM CONFIGURATION SCRIPT (PS1)
#                    Compatible with Windows 10 / Windows 11
# ================================================================================
# Purpose:
# - Configure common Windows settings for LaptopAZ / MiniAZ setup workflow.
# - Run silently when called from MiniAZ / Tauri backend or WinRAR SFX.
# - No Wi-Fi profile import. No Wi-Fi auto-connect.
# ================================================================================

param(
    [switch]$Silent
)

# ----------------------------- CONFIGURATION ------------------------------------
$PrimaryDNS = "1.1.1.1"
$SecondaryDNS = "8.8.8.8"
$TimezoneID = "SE Asia Standard Time"

# ----------------------------- SILENT MODE --------------------------------------
# If the script is run without the -Silent switch, relaunch it in hidden mode.
if (-not $Silent) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Silent"
    Start-Process -FilePath "powershell.exe" -ArgumentList $argList -WindowStyle Hidden -Wait
    exit $LASTEXITCODE
}

# ----------------------------- INITIALIZATION -----------------------------------

$status = @{
    SMB          = $false
    DesktopIcons = $false
    Power        = $false
    FastStartup  = $false
    DNS          = $false
    Timezone     = $false
}

# ----------------------------- ADMIN CHECK --------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    exit 10
}

# ================================================================================
#                              MAIN CONFIGURATION
# ================================================================================

# ----------------------------- 1. SMB CLIENT SETTING -----------------------------
try {
    Set-SmbClientConfiguration -RequireSecuritySignature $false -Force -ErrorAction Stop
    $status.SMB = $true
}
catch {
}

# ----------------------------- 2. DESKTOP ICONS ----------------------------------
try {
    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }

    # Show: This PC, Control Panel, User Files
    $icons = @(
        "{20D04FE0-3AEA-1069-A2D8-08002B30309D}",
        "{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}",
        "{59031a47-3f72-44a7-89c5-5595fe6b30ee}"
    )

    foreach ($icon in $icons) {
        New-ItemProperty -Path $regPath -Name $icon -Value 0 -PropertyType DWord -Force | Out-Null
    }

    # Call Win32 API to refresh desktop icons immediately without restarting Explorer
    $code = @'
    using System;
    using System.Runtime.InteropServices;
    public class Win32UI {
        [DllImport("shell32.dll")]
        public static extern void SHChangeNotify(int eventId, int flags, IntPtr item1, IntPtr item2);
    }
'@
    Add-Type -TypeDefinition $code -ErrorAction SilentlyContinue
    [Win32UI]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero)

    $status.DesktopIcons = $true
}
catch {
}

# ----------------------------- 3. PASSWORD POLICY --------------------------------
try {
    net accounts /maxpwage:unlimited | Out-Null
    if ($LASTEXITCODE -eq 0) {
    }
    else {
        throw "net accounts command returned exit code $LASTEXITCODE"
    }
}
catch {
}

# ----------------------------- 4. POWER MANAGEMENT -------------------------------
try {
    powercfg /change monitor-timeout-ac 0 | Out-Null
    powercfg /change monitor-timeout-dc 0 | Out-Null
    powercfg /change standby-timeout-ac 0 | Out-Null
    powercfg /change standby-timeout-dc 0 | Out-Null
    
    $status.Power = $true
}
catch {
}

# Disable Fast Startup
try {
    $powerRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
    New-ItemProperty -Path $powerRegPath -Name "HiberbootEnabled" -Value 0 -PropertyType DWord -Force | Out-Null
    $status.FastStartup = $true
}
catch {
}

# ----------------------------- 5. DNS CONFIGURATION ------------------------------
try {
    $adapters = Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }
    if (-not $adapters) {
    }
    else {
        $dnsSuccessCount = 0
        foreach ($adapter in $adapters) {
            try {
                Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($PrimaryDNS, $SecondaryDNS) -ErrorAction Stop
                $dnsSuccessCount++
            }
            catch {
            }
        }
        if ($dnsSuccessCount -gt 0) {
            $status.DNS = $true
        }
    }
}
catch {
}

# ----------------------------- 6. DNS VERIFICATION -------------------------------
try {
    $verifyDns = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.ServerAddresses -contains $PrimaryDNS }
    foreach ($v in $verifyDns) {
    }
}
catch {
}

# ----------------------------- 7. TIMEZONE ---------------------------------------
try {
    Set-TimeZone -Id $TimezoneID -ErrorAction Stop
    $status.Timezone = $true
}
catch {
}

# ================================================================================
#                             RESULT HANDLING
# ================================================================================

# Exit codes:
# 0  = completed, core configuration succeeded
# 2  = DNS failed; other settings may have succeeded
# 10 = administrator privilege required

if (-not $status.DNS) {
    exit 2
}
exit 0
