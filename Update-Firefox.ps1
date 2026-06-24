# ============================================================
# Update-Firefox.ps1
# Intune-deployed script — silently upgrades Mozilla Firefox
# Logs to: C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\
# ============================================================

$LogFile = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Update-Firefox.log"
$LogDir  = Split-Path $LogFile

if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }

$Apps = @(
    @{ Name = "Firefox"; IdPrefix = "Mozilla.Firefox"; Processes = @("firefox") }
)

function Write-Log {
    param([string]$Message, [ValidateSet("INFO","WARN","ERROR")]$Level = "INFO")
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry -Encoding UTF8
    Write-Output $entry
}

function Invoke-LogRotation {
    if (Test-Path $LogFile) {
        $lines = Get-Content $LogFile
        if ($lines.Count -gt 2500) {
            $lines | Select-Object -Last 2000 | Set-Content $LogFile -Encoding UTF8
            Write-Log "Log rotated — trimmed to last 2000 lines."
        }
    }
}

function Get-WinGet {
    $cmd = (Get-Command winget -ErrorAction SilentlyContinue).Source
    if ($cmd) { return $cmd }

    $cmd = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__*\winget.exe" `
           -ErrorAction SilentlyContinue |
           Sort-Object FullName -Descending |
           Select-Object -First 1 -ExpandProperty FullName

    return $cmd
}

function Resolve-InstalledId {
    param([string]$IdPrefix)
    $output = & $winget list --id $IdPrefix --source winget --accept-source-agreements --disable-interactivity 2>&1
    foreach ($line in $output) {
        if ($line -match "(?i)($([regex]::Escape($IdPrefix))\S*)") { return $Matches[1] }
    }
    return $null
}

try {
    Invoke-LogRotation
    Write-Log "====== Update-Firefox started ======"

    $winget = Get-WinGet
    if (-not $winget) { throw "winget.exe could not be located on this system." }
    Write-Log "winget resolved: $winget"

    $results = @()

    foreach ($app in $Apps) {
        Write-Log "--- Checking $($app.Name) ---"

        $resolvedId = Resolve-InstalledId -IdPrefix $app.IdPrefix
        if (-not $resolvedId) {
            Write-Log "  $($app.Name) is not installed — skipping." -Level WARN
            $results += [PSCustomObject]@{ App = $app.Name; Status = "NOT INSTALLED"; Code = $null }
            continue
        }
        Write-Log "  Resolved ID: $resolvedId"

        $wasRunning = $false
        foreach ($procName in $app.Processes) {
            $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
            if ($procs) {
                $wasRunning = $true
                Write-Log "  $($app.Name) is running ($procName) — requesting close." -Level WARN
                $procs | ForEach-Object { $_.CloseMainWindow() | Out-Null }
                Start-Sleep -Seconds 5
                $remaining = Get-Process -Name $procName -ErrorAction SilentlyContinue
                if ($remaining) {
                    Write-Log "  $($app.Name) did not close gracefully — forcing." -Level WARN
                    $remaining | Stop-Process -Force
                    Start-Sleep -Seconds 2
                } else {
                    Write-Log "  $($app.Name) closed gracefully."
                }
            }
        }
        if ($wasRunning) { Write-Log "  Proceeding with upgrade." }

        Write-Log "  Upgrading $($app.Name)..."
        $output   = & $winget upgrade --id $resolvedId --exact --silent --source winget --accept-source-agreements --disable-interactivity --accept-package-agreements 2>&1
        $exitCode = $LASTEXITCODE

        $output | ForEach-Object { Write-Log "  $_" }
        Write-Log "  Exit code: $exitCode"

        $success = $exitCode -in @(0, -1978335212, -1978335189)
        $results += [PSCustomObject]@{
            App    = $app.Name
            Status = if ($success) { "OK" } else { "FAILED" }
            Code   = $exitCode
        }
    }

    Write-Log "====== Summary ======"
    $anyFailed = $false
    foreach ($r in $results) {
        $level = switch ($r.Status) {
            "OK"            { "INFO" }
            "NOT INSTALLED" { "WARN" }
            default         { $anyFailed = $true; "ERROR" }
        }
        Write-Log "  $($r.App): $($r.Status) (exit $($r.Code))" -Level $level
    }

    Write-Log "====== Update-Firefox finished ======"
    exit ($anyFailed ? 1 : 0)
}
catch {
    Write-Log "====== Update-Firefox FAILED: $_ ======" -Level ERROR
    exit 1
}