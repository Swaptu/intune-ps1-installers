# ============================================================
# Update-AllApps.ps1
# Personal use — updates all managed apps via winget
# Log: C:\Users\<you>\AppData\Local\UpdateAllApps\update.log
#
# Uses ID prefixes — resolves the actual installed winget ID
# at runtime, so variants like Google.Chrome vs Google.Chrome.EXE
# are handled automatically.
# ============================================================

$LogFile = "$env:LOCALAPPDATA\UpdateAllApps\update.log"
$LogDir  = Split-Path $LogFile

if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }

# IdPrefix: matched loosely — covers all ID variants (EXE, MSI, etc.)
$Apps = @(
    @{ Name = "Google Chrome";   IdPrefix = "Google.Chrome";    Processes = @("chrome") },
    @{ Name = "Firefox";         IdPrefix = "Mozilla.Firefox";  Processes = @("firefox") },
    @{ Name = "7-Zip";           IdPrefix = "7zip.7zip";        Processes = @("7zFM", "7zG") }
)

# ── Logging ──────────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [ValidateSet("INFO","WARN","ERROR")]$Level = "INFO")
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry -Encoding UTF8
    switch ($Level) {
        "ERROR" { Write-Host $entry -ForegroundColor Red }
        "WARN"  { Write-Host $entry -ForegroundColor Yellow }
        default { Write-Host $entry }
    }
}

# ── Resolve winget ───────────────────────────────────────────
function Get-WinGet {
    $cmd = (Get-Command winget -ErrorAction SilentlyContinue).Source
    if ($cmd) { return $cmd }

    $cmd = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__*\winget.exe" `
           -ErrorAction SilentlyContinue |
           Sort-Object FullName -Descending |
           Select-Object -First 1 -ExpandProperty FullName

    return $cmd
}

# ── Resolve actual installed ID from a prefix ────────────────
# Runs: winget list --id <prefix>  (no --exact)
# Scans output for any token that starts with the prefix.
# Returns the first match, or $null if nothing found.
function Resolve-InstalledId {
    param([string]$IdPrefix)

    $output = & $winget list --id $IdPrefix --source winget --accept-source-agreements --disable-interactivity 2>&1

    foreach ($line in $output) {
        if ($line -match "(?i)($([regex]::Escape($IdPrefix))\S*)") {
            return $Matches[1]
        }
    }

    return $null
}

# ── Main ─────────────────────────────────────────────────────
Write-Log "====== Update-AllApps started ======"

$winget = Get-WinGet
if (-not $winget) {
    Write-Log "winget.exe could not be located. Ensure App Installer is installed." -Level ERROR
    exit 1
}
Write-Log "winget resolved: $winget"

$results = @()

foreach ($app in $Apps) {
    Write-Log "--- Checking $($app.Name) ---"

    # Dynamically resolve the actual installed ID
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

    Write-Log "  $($app.Name) found — installing/upgrading."
    $output   = & $winget install --id $resolvedId --exact --silent --source winget --accept-source-agreements --disable-interactivity --accept-package-agreements 2>&1
    $exitCode = $LASTEXITCODE

    $output | ForEach-Object { Write-Log "  $_" }
    Write-Log "  Exit code: $exitCode"

    # 0            = success / updated
    # -1978335212  = no applicable update (already current)
    # -1978335189  = no newer version available from sources (already current)
    $success = $exitCode -in @(0, -1978335212, -1978335189)
    $results += [PSCustomObject]@{
        App     = $app.Name
        Status  = if ($success) { "OK" } else { "FAILED" }
        Code    = $exitCode
    }
}

# ── Summary ──────────────────────────────────────────────────
Write-Log "====== Summary ======"
foreach ($r in $results) {
    $level = switch ($r.Status) {
        "OK"            { "INFO" }
        "NOT INSTALLED" { "WARN" }
        default         { "ERROR" }
    }
    Write-Log "  $($r.App): $($r.Status) (exit $($r.Code))" -Level $level
}
Write-Log "====== Update-AllApps finished ======"
