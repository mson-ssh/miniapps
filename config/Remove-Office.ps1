# ================================================================================
#                    MINIAZ OFFICE FORCE REMOVAL SCRIPT (PS1)
#                    Compatible with Windows 10 / Windows 11
# ================================================================================
# Purpose:
# - Force-remove all Microsoft Office installations (MSI + Click-to-Run),
#   including installs that cannot be uninstalled through normal means.
# - Primary method : Microsoft's command-line Get Help tool, OfficeScrubScenario —
#                     official Microsoft removal engine. This tool used to be
#                     called SaRA (Support and Recovery Assistant) and shipped as
#                     SaRAcmd.exe; Microsoft retired that build, it is now
#                     GetHelpCmd.exe from aka.ms/SaRA_EnterpriseVersionFiles.
# - Alternate method: Office Deployment Tool (ODT) setup.exe /configure purge.xml
#                     (-UseSetupRemoval). ODT assets are bundled locally in
#                     .\OfficeRemoval so no third-party download is required.
# - Optional: reinstall the latest Office 365 build after removal (-InstallOffice365).
# - Run silently when called from MiniAZ / Tauri backend or WinRAR SFX.
# - Adapted from https://github.com/Admonstrator/msoffice-removal-tool (MIT License).
# ================================================================================

param(
    [switch]$Silent,
    [switch]$InstallOffice365,
    [switch]$SuppressReboot,
    [switch]$UseSetupRemoval,
    [switch]$RunAgain,
    [int]$SecondsToReboot = 60
)

# ----------------------------- CONFIGURATION ------------------------------------
$GetHelp_URL = "https://aka.ms/SaRA_EnterpriseVersionFiles"
$GetHelp_ZIP = "$env:TEMP\GetHelpCmd.zip"
$GetHelp_DIR = "$env:TEMP\GetHelpCmd"

# Local Office Deployment Tool assets (bundled — no external download dependency)
$AssetsDir   = "$PSScriptRoot\OfficeRemoval"
$ODT_SETUP   = "$AssetsDir\setup.exe"
$ODT_PURGE   = "$AssetsDir\purge.xml"
$ODT_UPGRADE = "$AssetsDir\upgrade.xml"

$StageRegPath = "HKLM:\Software\MiniAZ\OfficeRemoval"

$OfficeProcesses = "lync", "winword", "excel", "msaccess", "mstore", "infopath", "setlang", "msouc", "ois", "onenote", "outlook", "powerpnt", "mspub", "groove", "visio", "winproj", "graph", "teams"

# ----------------------------- SILENT MODE --------------------------------------
if (-not $Silent) {
    $forward = @("-Silent")
    if ($InstallOffice365) { $forward += "-InstallOffice365" }
    if ($SuppressReboot) { $forward += "-SuppressReboot" }
    if ($UseSetupRemoval) { $forward += "-UseSetupRemoval" }
    if ($RunAgain) { $forward += "-RunAgain" }
    $forward += "-SecondsToReboot", $SecondsToReboot

    $argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" $($forward -join ' ')"
    Start-Process -FilePath "powershell.exe" -ArgumentList $argList -WindowStyle Hidden -Wait
    exit $LASTEXITCODE
}

# ----------------------------- INITIALIZATION -----------------------------------
$status = @{
    ProcessesStopped = $false
    Removed          = $false
    Reinstalled      = $false
}

# ----------------------------- ADMIN CHECK --------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    exit 10
}

# ----------------------------- FUNCTIONS -----------------------------------------
function Stop-OfficeProcess {
    foreach ($name in $OfficeProcesses) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

function Remove-GetHelpFiles {
    if (Test-Path $GetHelp_ZIP) { Remove-Item $GetHelp_ZIP -Force -ErrorAction SilentlyContinue }
    if (Test-Path $GetHelp_DIR) { Remove-Item $GetHelp_DIR -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-GetHelpCmd {
    Remove-GetHelpFiles
    New-Item -Path $GetHelp_DIR -ItemType Directory -Force | Out-Null
    Start-BitsTransfer -Source $GetHelp_URL -Destination $GetHelp_ZIP -ErrorAction Stop
    Expand-Archive -Path $GetHelp_ZIP -DestinationPath $GetHelp_DIR -Force
    # Search instead of assuming a fixed subfolder: Microsoft has changed the
    # zip layout before (used to nest everything under a DONE\ folder).
    $exe = Get-ChildItem -Path $GetHelp_DIR -Filter "GetHelpCmd.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    return $exe.FullName
}

function Invoke-GetHelpRemoval($ExePath) {
    # -CloseOffice is not a valid switch for OfficeScrubScenario (only for the
    # activation scenarios) - Office processes are stopped separately below.
    # -OfficeVersion is documented on learn.microsoft.com but this build's own
    # -Help output does not list it and rejects it as an invalid argument, so
    # it is left out and GetHelpCmd auto-detects the installed version(s).
    $proc = Start-Process -FilePath $ExePath -ArgumentList @('-S', 'OfficeScrubScenario', '-AcceptEula') -Wait -PassThru -NoNewWindow
    return $proc.ExitCode
}

function Invoke-ODTRemoval {
    if (-not (Test-Path $ODT_SETUP) -or -not (Test-Path $ODT_PURGE)) { return $false }
    $proc = Start-Process -FilePath $ODT_SETUP -ArgumentList "/configure `"$ODT_PURGE`"" -Wait -PassThru -NoNewWindow
    return ($proc.ExitCode -eq 0)
}

function Invoke-ODTReinstall {
    if (-not (Test-Path $ODT_SETUP) -or -not (Test-Path $ODT_UPGRADE)) { return $false }
    $proc = Start-Process -FilePath $ODT_SETUP -ArgumentList "/configure `"$ODT_UPGRADE`"" -Wait -PassThru -NoNewWindow
    return ($proc.ExitCode -eq 0)
}

function Set-CurrentStage($StageValue) {
    if (-not (Test-Path $StageRegPath)) {
        New-Item -Path $StageRegPath -Force | Out-Null
    }
    New-ItemProperty -Path $StageRegPath -Name "CurrentStage" -Value $StageValue -PropertyType String -Force | Out-Null
}

function Get-CurrentStage {
    if (Test-Path $StageRegPath) {
        return (Get-ItemProperty -Path $StageRegPath -ErrorAction SilentlyContinue).CurrentStage
    }
    return $null
}

function Clear-Stage {
    Remove-Item -Path $StageRegPath -Recurse -Force -ErrorAction SilentlyContinue
}

function Invoke-PendingReboot($Seconds) {
    if (-not $SuppressReboot) {
        Start-Process -FilePath "$env:SystemRoot\system32\shutdown.exe" -ArgumentList "/r /t $Seconds /f /d p:4:1" -WindowStyle Hidden
    }
}

# ================================================================================
#                              MAIN EXECUTION
# ================================================================================
# Stage 1: Stop Office processes, force-remove all Office installations.
# Stage 2: (only when -InstallOffice365 was requested) Reinstall Office 365.
# The resume stage is tracked in the registry so that re-running this script
# after the reboot it triggers continues where it left off.
# ================================================================================

try {
    $stage = 1
    if (-not $RunAgain) {
        $stageRaw = Get-CurrentStage
        $parsed = 0
        if ($stageRaw -and [int]::TryParse($stageRaw, [ref]$parsed) -and $parsed -eq 2) {
            $stage = 2
        }
    }

    if ($stage -eq 1) {
        Stop-OfficeProcess
        $status.ProcessesStopped = $true

        $removed = $false
        if ($UseSetupRemoval) {
            $removed = Invoke-ODTRemoval
        }
        else {
            $exePath = Get-GetHelpCmd
            if ($exePath) {
                $exitCode = Invoke-GetHelpRemoval $exePath
                # 0 = removed successfully, 68 = no Office installation found (nothing to do)
                $removed = ($exitCode -eq 0 -or $exitCode -eq 68)
            }
        }
        $status.Removed = $removed
        Remove-GetHelpFiles

        if (-not $removed) {
            Clear-Stage
            exit 3
        }

        if ($InstallOffice365) {
            Set-CurrentStage 2
        }
        else {
            Clear-Stage
        }
        Invoke-PendingReboot $SecondsToReboot
    }
    else {
        $status.Reinstalled = Invoke-ODTReinstall
        Remove-GetHelpFiles
        Clear-Stage
        Invoke-PendingReboot $SecondsToReboot
    }

    exit 0
}
catch {
    exit 1
}

# ================================================================================
#                             EXIT CODES
# ================================================================================
# 0  = completed (removal succeeded; reinstall succeeded if -InstallOffice365 was resumed)
# 1  = unexpected error during removal / reinstall
# 3  = removal failed (GetHelpCmd and/or ODT purge method reported failure)
# 10 = administrator privilege required
