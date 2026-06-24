# ============================================================
# Update-AllApps-Intune.ps1
# Intune-deployed script — silently upgrades all managed apps
# Logs to: C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\
#
# Uses ID prefixes — resolves the actual installed winget ID
# at runtime, so variants like Google.Chrome vs Google.Chrome.EXE
# are handled automatically.
# ============================================================

$LogFile = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Update-AllApps.log"
$LogDir  = Split-Path $LogFile

if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }

# IdPrefix: matched loosely — covers all ID variants (EXE, MSI, etc.)
# Processes: closed gracefully before upgrade if running
$Apps = @(
    @{ Name = "Zoom";          IdPrefix = "Zoom.Zoom";          Processes = @("Zoom") }
)

# ── Logging ──────────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [ValidateSet("INFO","WARN","ERROR")]$Level = "INFO")
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry -Encoding UTF8
    Write-Output $entry
}

# ── Log rotation (keep last 2000 lines) ──────────────────────
function Invoke-LogRotation {
    if (Test-Path $LogFile) {
        $lines = Get-Content $LogFile
        if ($lines.Count -gt 2500) {
            $lines | Select-Object -Last 2000 | Set-Content $LogFile -Encoding UTF8
            Write-Log "Log rotated — trimmed to last 2000 lines."
        }
    }
}

# ── Resolve winget ───────────────────────────────────────────
function Get-WinGet {
    # 1. Try SYSTEM PATH
    $cmd = (Get-Command winget -ErrorAction SilentlyContinue).Source
    if ($cmd) { return $cmd }

    # 2. Fallback: glob ProgramFiles, pick newest AppInstaller version
    $cmd = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__*\winget.exe" `
           -ErrorAction SilentlyContinue |
           Sort-Object FullName -Descending |
           Select-Object -First 1 -ExpandProperty FullName

    return $cmd
}

# ── Resolve actual installed ID from a prefix ────────────────
# Runs: winget list --id <prefix>  (no --exact)
# Scans output for any token that starts with the prefix.
# Returns the first match, or $null if not installed.
function Resolve-InstalledId {
    param([string]$IdPrefix)

    $output = & $winget list --id $IdPrefix 2>&1

    foreach ($line in $output) {
        if ($line -match "(?i)($([regex]::Escape($IdPrefix))\S*)") {
            return $Matches[1]
        }
    }

    return $null
}

# ── Main ─────────────────────────────────────────────────────
try {
    Invoke-LogRotation
    Write-Log "====== Update-AllApps started ======"

    $winget = Get-WinGet
    if (-not $winget) { throw "winget.exe could not be located on this system." }
    Write-Log "winget resolved: $winget"

    $results = @()

    foreach ($app in $Apps) {
        Write-Log "--- Checking $($app.Name) ---"

        # Pre-check: resolve actual installed ID
        $resolvedId = Resolve-InstalledId -IdPrefix $app.IdPrefix

        if (-not $resolvedId) {
            Write-Log "  $($app.Name) is not installed — skipping." -Level WARN
            $results += [PSCustomObject]@{ App = $app.Name; Status = "NOT INSTALLED"; Code = $null }
            continue
        }

        Write-Log "  Resolved ID: $resolvedId"

        # Graceful close: ask nicely first, force only if needed
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
        $output   = & $winget upgrade --id $resolvedId --exact --silent --accept-source-agreements --accept-package-agreements 2>&1
        $exitCode = $LASTEXITCODE

        $output | ForEach-Object { Write-Log "  $_" }
        Write-Log "  Exit code: $exitCode"

        # 0            = success / updated
        # -1978335212  = no applicable update (already current)
        # -1978335189  = no newer version available from sources (already current)
        $success = $exitCode -in @(0, -1978335212, -1978335189)
        $results += [PSCustomObject]@{
            App    = $app.Name
            Status = if ($success) { "OK" } else { "FAILED" }
            Code   = $exitCode
        }
    }

    # ── Summary ──────────────────────────────────────────────
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

    Write-Log "====== Update-AllApps finished ======"
    exit ($anyFailed ? 1 : 0)
}
catch {
    Write-Log "====== Update-AllApps FAILED: $_ ======" -Level ERROR
    exit 1
}