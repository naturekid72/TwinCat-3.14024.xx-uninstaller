<#
.SYNOPSIS
    Deinstalliert Beckhoff TwinCAT 3.1 Build 4024.xx und zugehoerige Komponenten vollstaendig.

.DESCRIPTION
    Dieses Skript:
    1. Sichert vorhandene TwinCAT-Lizenzen (Target\License) und Boot-Projekte (Boot).
    2. Beendet alle laufenden TwinCAT-Dienste und -Prozesse.
    3. Deinstalliert saemtliche TwinCAT-3-Komponenten silent per MSI/UninstallString.
    4. Bereinigt verwaiste Registry-Eintraege.
    5. Entfernt auf Wunsch das Verzeichnis C:\TwinCAT.

.PARAMETER BackupPath
    Zielverzeichnis fuer die Sicherung von Lizenzen und Boot-Projekten.
    Standard: C:\TwinCAT_Backup_<Zeitstempel>

.PARAMETER SkipBackup
    Ueberspringt das automatische Sichern von Lizenzen und Boot-Projekten.

.PARAMETER RemoveFolder
    Entfernt nach der Deinstallation auch C:\TwinCAT.

.PARAMETER RestartAfterUninstall
    Fuehrt nach erfolgreicher Deinstallation automatisch einen Systemneustart durch.

.EXAMPLE
    .\Uninstall-TwinCAT4024.ps1 -RemoveFolder

.EXAMPLE
    .\Uninstall-TwinCAT4024.ps1 -RemoveFolder -BackupPath "D:\Backups\TwinCAT" -RestartAfterUninstall
#>

[CmdletBinding()]
param(
    [string]$BackupPath = "$($env:SystemDrive)\TwinCAT_Backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')",
    [switch]$SkipBackup = $false,
    [switch]$RemoveFolder = $false,
    [switch]$RestartAfterUninstall = $false
)

# 1. Administratorrechte pruefen
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "Dieses Skript muss mit Administratorrechten (Als Administrator ausfuehren) gestartet werden."
    exit 1
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   TwinCAT 3.1.4024.xx Vollstaendige Deinstallation        " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 2. Sicherung von Lizenzen und Boot-Projekten
if (-not $SkipBackup) {
    Write-Host "`n[1/6] Pruefe und sichere Lizenzen und Boot-Projekte..." -ForegroundColor Yellow

    $backupCreated = $false
    $tcBasePaths = @("C:\TwinCAT", "$env:SystemDrive\TwinCAT") | Select-Object -Unique

    # Lizenzordner ermitteln
    $licenseFolders = @()
    foreach ($base in $tcBasePaths) {
        if (Test-Path $base) {
            $licenseFolders += Get-ChildItem -Path $base -Recurse -Directory -Filter "License" -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -like "*\Target\License*" -or $_.FullName -like "*\CustomConfig\Licenses*" }
        }
    }

    # Boot-Ordner ermitteln
    $bootFolders = @()
    foreach ($base in $tcBasePaths) {
        if (Test-Path $base) {
            $bootFolders += Get-ChildItem -Path $base -Recurse -Directory -Filter "Boot" -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -like "*\3.1\Boot*" -or $_.FullName -match "\\Boot$" }
        }
    }

    # Lizenzen sichern
    $backedUpLicensesCount = 0
    foreach ($licDir in ($licenseFolders | Select-Object -Unique -ExpandProperty FullName)) {
        $files = Get-ChildItem -Path $licDir -File -ErrorAction SilentlyContinue
        if ($files.Count -gt 0) {
            $destLic = Join-Path -Path $BackupPath -ChildPath "Licenses"
            if (-not (Test-Path $destLic)) { New-Item -ItemType Directory -Path $destLic -Force | Out-Null }
            Copy-Item -Path "$licDir\*" -Destination $destLic -Recurse -Force
            $backedUpLicensesCount += $files.Count
            $backupCreated = $true
        }
    }

    # Boot-Projekte sichern
    $backedUpBootCount = 0
    foreach ($bDir in ($bootFolders | Select-Object -Unique -ExpandProperty FullName)) {
        $files = Get-ChildItem -Path $bDir -File -Recurse -ErrorAction SilentlyContinue
        if ($files.Count -gt 0) {
            $destBoot = Join-Path -Path $BackupPath -ChildPath "Boot"
            if (-not (Test-Path $destBoot)) { New-Item -ItemType Directory -Path $destBoot -Force | Out-Null }
            Copy-Item -Path "$bDir\*" -Destination $destBoot -Recurse -Force
            $backedUpBootCount += $files.Count
            $backupCreated = $true
        }
    }

    if ($backupCreated) {
        Write-Host "  [OK] Sicherung erfolgreich erstellt in: $BackupPath" -ForegroundColor Green
        if ($backedUpLicensesCount -gt 0) {
            Write-Host "       - Lizenzen gesichert ($backedUpLicensesCount Dateien)" -ForegroundColor Green
        }
        if ($backedUpBootCount -gt 0) {
            Write-Host "       - Boot-Projekte gesichert ($backedUpBootCount Dateien)" -ForegroundColor Green
        }
    } else {
        Write-Host "  Keine vorhandenen Lizenzen oder Boot-Projekte gefunden (kein Backup erforderlich)." -ForegroundColor DarkGray
    }
} else {
    Write-Host "`n[1/6] Sicherung durch Schalter -SkipBackup uebersprungen." -ForegroundColor DarkGray
}

# 3. Laufende TwinCAT-Dienste und -Prozesse beenden
Write-Host "`n[2/6] Beende TwinCAT-Dienste und Prozesse..." -ForegroundColor Yellow

$servicesToStop = @("TcSysSrv", "TcAdsSysSrv", "TcEventLogger", "TcTimerSrv", "TcRealtimeDriver")
foreach ($svc in $servicesToStop) {
    $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Running') {
        Write-Host "  Stoppe Dienst: $svc"
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
    }
}

$processesToKill = @("TcSysUI", "TcXaeShell", "devenv", "TcEventLogger", "TcRouter", "TcMessageServer")
foreach ($proc in $processesToKill) {
    Get-Process -Name $proc -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "  Beende Prozess: $($_.ProcessName) (PID: $($_.Id))"
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
}

# 4. TwinCAT-Komponenten in der Registry suchen
Write-Host "`n[3/6] Suche nach installierten TwinCAT-Komponenten..." -ForegroundColor Yellow

$uninstallPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

$installedProducts = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
    Where-Object {
        ($_.DisplayName -like "*TwinCAT*" -or $_.DisplayName -like "*Beckhoff*") -and
        ($_.DisplayName -notlike "*Package Manager*")
    }

if (-not $installedProducts) {
    Write-Host "  Keine TwinCAT-Installationen ueber Windows Uninstall Registry gefunden." -ForegroundColor Green
} else {
    Write-Host "  Gefundene Komponenten:" -ForegroundColor Green
    foreach ($item in $installedProducts) {
        Write-Host "   - $($item.DisplayName) ($($item.DisplayVersion))"
    }

    # 5. Deinstallation durchfuehren
    Write-Host "`n[4/6] Deinstalliere Komponenten..." -ForegroundColor Yellow

    # Sortierung: Zusatzmodule/Scope/TargetBrowser zuerst, danach TwinCAT Core / XAE / XAR
    $sortedProducts = $installedProducts | Sort-Object {
        if ($_.DisplayName -match "Scope|Target|Add-In|Extension|Function") { 1 }
        elseif ($_.DisplayName -match "XAE|XAR|Full") { 3 }
        else { 2 }
    }

    foreach ($app in $sortedProducts) {
        Write-Host "  Deinstalliere: $($app.DisplayName)..." -ForegroundColor Cyan

        if ($app.UninstallString -match "MsiExec\.exe" -or $app.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$') {
            $guid = if ($app.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$') { $app.PSChildName } else { [regex]::Match($app.UninstallString, '\{[0-9A-Fa-f-]{36}\}').Value }
            if ($guid) {
                Write-Host "    Fuehre msiexec /x $guid aus..."
                $proc = Start-Process "msiexec.exe" -ArgumentList "/x $guid /qn /norestart /L*V `"$env:TEMP\uninstall_$guid.log`"" -Wait -PassThru
                Write-Host "    ExitCode: $($proc.ExitCode)"
            }
        } elseif ($app.QuietUninstallString) {
            Write-Host "    Fuehre QuietUninstallString aus..."
            Start-Process "cmd.exe" -ArgumentList "/c $($app.QuietUninstallString)" -Wait
        } elseif ($app.UninstallString) {
            Write-Host "    Fuehre UninstallString im Silent-Modus aus..."
            $cmd = $app.UninstallString
            if ($cmd -match "\.exe") {
                Start-Process "cmd.exe" -ArgumentList "/c $cmd /s /v`"/qn /norestart`"" -Wait
            } else {
                Start-Process "cmd.exe" -ArgumentList "/c $cmd" -Wait
            }
        }
    }
}

# 6. Registry-Bereinigung
Write-Host "`n[5/6] Bereinige verwaiste Registry-Eintraege..." -ForegroundColor Yellow
$registryKeysToRemove = @(
    "HKLM:\SOFTWARE\Beckhoff\TwinCAT3",
    "HKLM:\SOFTWARE\WOW6432Node\Beckhoff\TwinCAT3",
    "HKCU:\Software\Beckhoff\TwinCAT3"
)

foreach ($regPath in $registryKeysToRemove) {
    if (Test-Path $regPath) {
        Write-Host "  Entferne Registry-Pfad: $regPath"
        Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 7. Ordner C:\TwinCAT entfernen (optional oder per Parameter)
Write-Host "`n[6/6] Ordnerbereinigung..." -ForegroundColor Yellow
if (Test-Path "C:\TwinCAT") {
    if ($RemoveFolder) {
        Write-Host "  Loesche C:\TwinCAT..." -ForegroundColor Yellow
        Remove-Item -Path "C:\TwinCAT" -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path "C:\TwinCAT") {
            Write-Warning "Einige Dateien in C:\TwinCAT konnten nicht entfernt werden (moeglicherweise durch geladene Kernel-Treiber gesperrt). Sie werden nach einem Neustart entfernbar sein."
        } else {
            Write-Host "  C:\TwinCAT erfolgreich geloescht." -ForegroundColor Green
        }
    } else {
        Write-Host "  C:\TwinCAT wurde beibehalten (Schalter -RemoveFolder nicht gesetzt)." -ForegroundColor DarkGray
    }
} else {
    Write-Host "  C:\TwinCAT existiert nicht mehr." -ForegroundColor Green
}

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "   Deinstallation abgeschlossen!                          " -ForegroundColor Green
if ($backupCreated) {
    Write-Host "   Sicherung liegt unter: $BackupPath" -ForegroundColor Cyan
}
Write-Host "   WICHTIG: Ein Neustart ist erforderlich, um gesperrte   " -ForegroundColor Green
Write-Host "   Kernel-Treiber (.sys) vollstaendig zu entladen.        " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green

if ($RestartAfterUninstall) {
    Write-Host "Systemneustart in 10 Sekunden..." -ForegroundColor Red
    Restart-Computer -Force
}
