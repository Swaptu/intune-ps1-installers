# intune-ps1-installers

PowerShell scripts for keeping managed endpoints perpetually current via Microsoft Intune. Maintained for **Probe**.

---

## Overview

This repository contains Intune-deployable PowerShell scripts that silently upgrade a defined set of applications using the Windows Package Manager (`winget`). Scripts are designed to run as `SYSTEM` under the Intune Management Extension and produce structured logs for auditing and troubleshooting.

Two deployment models are provided:

| Model | Script | Use case |
|---|---|---|
| **Combined** | `Update-AllApps-Intune.ps1` | Single policy, all apps, one log |
| **Granular** | `Update-<AppName>.ps1` (×7) | Per-app Intune policy, per-app reporting |

---

## Managed Applications

| Application | winget ID Prefix | Process(es) closed |
|---|---|---|
| Zoom | `Zoom.Zoom` | `Zoom` |
| TeamViewer | `TeamViewer.TeamViewer` | `TeamViewer` |
| Notepad++ | `Notepad++.Notepad++` | `notepad++` |
| Google Chrome | `Google.Chrome` | `chrome` |
| Mozilla Firefox | `Mozilla.Firefox` | `firefox` |
| Adobe Acrobat Reader | `Adobe.Acrobat.Reader` | `AcroRd32`, `Acrobat` |
| 7-Zip | `7zip.7zip` | `7zFM`, `7zG` |

---

## How It Works

Each script follows this execution flow:

1. **Resolve `winget`** — attempts `Get-Command winget` first; falls back to globbing `%ProgramFiles%\WindowsApps\Microsoft.DesktopAppInstaller_*` to handle the SYSTEM context where PATH is minimal.
2. **Pre-check** — runs `winget list --id <prefix>` (without `--exact`) and scans output for any ID beginning with the configured prefix. This makes ID resolution dynamic — `Google.Chrome` matches both `Google.Chrome` and `Google.Chrome.EXE` without hardcoding the variant.
3. **Graceful close** — if the application is running, `CloseMainWindow()` is called first (WM_CLOSE, allows the app to save state). After a 5-second grace period, any remaining processes are force-terminated.
4. **Upgrade** — runs `winget upgrade --id <resolvedId> --exact --silent` using the ID resolved at runtime.
5. **Exit code evaluation** — the following codes are treated as success:

   | Code | Meaning |
   |---|---|
   | `0` | Upgraded successfully |
   | `-1978335212` | No applicable update — already current |
   | `-1978335189` | No newer version available from configured sources |

6. **Logging** — all output is written to `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\` with timestamps and severity levels (`INFO`, `WARN`, `ERROR`). Log rotation kicks in at 2500 lines, trimming to the last 2000.

---

## Repository Structure

```
evergreen-intune/
│
├── Update-AllApps-Intune.ps1       # Combined — all 7 apps in one policy
│
├── Update-Zoom.ps1
├── Update-TeamViewer.ps1
├── Update-NotepadPlusPlus.ps1
├── Update-Chrome.ps1
├── Update-Firefox.ps1
├── Update-AdobeReader.ps1
├── Update-7zip.ps1
│
└── Update-AllApps.ps1              # Personal use — interactive, colour-coded output
```

---

## Deployment — Microsoft Intune

### Prerequisites

- Windows 10 21H2+ or Windows 11
- App Installer (`winget`) present on target devices — available via Microsoft Store or pre-provisioned in image
- Intune Management Extension enrolled

### Adding a Script Policy

1. **Intune portal** → Devices → Scripts and remediations → Platform scripts → **Add** → Windows 10 and later
2. Configure:
   - **Name**: `Evergreen — <AppName>` (e.g. `Evergreen — Google Chrome`)
   - **Script file**: upload the relevant `.ps1`
   - **Run this script using the logged on credentials**: `No` (runs as SYSTEM)
   - **Enforce script signature check**: `No`
   - **Run script in 64-bit PowerShell host**: `Yes`
3. Assign to the target device group
4. Set a recurrence via the assignment schedule (weekly recommended)

### Log Location on Endpoints

```
C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Update-<AppName>.log
```

Logs can be retrieved via Intune's **Collect diagnostics** action or via a Log Analytics / MEM integration if configured.

---

## Adding a New Application

1. Open `Update-AllApps-Intune.ps1` (or the relevant individual script)
2. Add an entry to the `$Apps` array:

```powershell
@{ Name = "App Display Name"; IdPrefix = "Publisher.AppName"; Processes = @("processname") }
```

3. To find the correct `IdPrefix`:

```powershell
winget search <appname>
```

4. Copy `Update-AllApps-Intune.ps1`, adjust the `$Apps` array to a single entry, rename the log file path and script header — done.

---

## Personal Use

`Update-AllApps.ps1` is a personal-use variant of the combined script. It includes colour-coded console output and logs to `%LOCALAPPDATA%\UpdateAllApps\update.log`. It is not intended for Intune deployment.

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\Update-AllApps.ps1"
```

---

## Exit Codes

Intune reads the script exit code to determine remediation state:

| Code | Intune interpretation |
|---|---|
| `0` | Success |
| `1` | Failure — check log for details |

---

## Notes

- **Chrome ID variance**: Chrome may be registered as `Google.Chrome` or `Google.Chrome.EXE` depending on how it was installed. The dynamic ID resolution handles this transparently.
- **SYSTEM context**: `winget` is not always on the SYSTEM PATH. The fallback glob in `Get-WinGet` covers this without hardcoding a version-stamped path.
- **Adobe Reader**: The `IdPrefix` `Adobe.Acrobat.Reader` matches both `Adobe.Acrobat.Reader.64-bit` and `Adobe.Acrobat.Reader.32-bit`. Verify the variant present in your environment with `winget list --id Adobe.Acrobat.Reader`.

---

## Maintainer

Maintained by the infrastructure team. Deployed and validated against the **Probe** endpoint fleet.