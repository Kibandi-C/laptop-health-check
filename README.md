# Laptop Health Check

[![Test on Windows](https://github.com/Kibandi-C/laptop-health-check/actions/workflows/test.yml/badge.svg)](https://github.com/Kibandi-C/laptop-health-check/actions/workflows/test.yml)
![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE)
![License](https://img.shields.io/badge/license-MIT-green)

A one-click health and software check for **used Windows laptops**, with extra checks for Lenovo ThinkPads. Double-click it, walk away, and read the HTML report when it finishes.

It is built for the moment you buy second-hand. It catches the problems that are expensive to find out about later:

- a laptop still **locked to a company** (Azure AD, Intune/MDM, Windows Autopilot)
- an **anti-theft agent** the previous owner controls (Absolute / Computrace)
- a **BIOS supervisor password** you can't remove
- a **cracked or lapsing Windows licence**
- a **worn battery or SSD**
- hidden **blue screens and hardware errors**
- leftover **remote-control tools** and **malware**

---

## Contents

- [Quick start](#quick-start)
- [Two modes](#two-modes)
- [Setup in detail](#setup-in-detail)
- [Options](#options)
- [Reading the report](#reading-the-report)
- [What it checks](#what-it-checks)
- [Buying a used laptop: the full workflow](#buying-a-used-laptop-the-full-workflow)
- [What it cannot test (and free tools for it)](#what-it-cannot-test-and-free-tools-for-it)
- [Safety and privacy](#safety-and-privacy)
- [Troubleshooting](#troubleshooting)
- [Project structure](#project-structure)
- [Contributing](#contributing)
- [Disclaimer](#disclaimer)
- [Licence](#licence)

---

## Quick start

1. On the laptop, click **Code > Download ZIP** on this page.
2. Right-click the ZIP, choose **Extract All**, and open the extracted folder.
3. Plug in the charger.
4. Double-click:
   - **`Run-QuickCheck.bat`** for a 5-minute check (stay with the laptop), or
   - **`Run-LaptopHealthCheck.bat`** for the full 1-3 hour check (walk away).
5. Click **Yes** on the administrator prompt.

The report opens in the browser when it is done. It is saved to a folder on the Desktop named `LaptopHealthCheck_<date>_<time>`.

---

## Two modes

| | Quick check | Full check |
| --- | --- | --- |
| Launcher | `Run-QuickCheck.bat` | `Run-LaptopHealthCheck.bat` |
| Time | about 5 minutes | about 1-3 hours |
| Use it | before you accept a laptop, e.g. at the shop | at home, unattended or overnight |
| Ownership locks, licence, security | Yes | Yes |
| Battery and SSD health | Yes | Yes |
| Devices, drivers, crash and error history | Yes | Yes |
| 90-second fan test (asks you if the fan spun up) | Yes | No |
| `chkdsk`, DISM, SFC | No | Yes |
| Windows Update check, download speed test | No | Yes |
| Microsoft Defender scan | No | Full scan |

> **Neither mode can see messages shown at power-on**, before Windows loads (such as "Fan error"). Test that by hand: shut down fully, wait 5 minutes, power on, and repeat 3 times.

---

## Setup in detail

### Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 (built into Windows, nothing to install)
- An **administrator** account on the laptop
- Internet for the full check (Windows Update, Defender definitions, speed test). The quick check works offline.

### Option A: download the ZIP (easiest)

1. Click **Code > Download ZIP**.
2. **Extract** the ZIP. Running the `.bat` from inside the ZIP will not work; the launcher tells you if you try.
3. Optional: copy the extracted folder to a USB flash drive, so you can run it on a laptop at the shop without internet.

### Option B: clone with Git

```powershell
git clone https://github.com/Kibandi-C/laptop-health-check.git
cd laptop-health-check
```

### Running it

**By double-click:** run either `.bat` file and approve the administrator prompt.

**From PowerShell:** open PowerShell in the folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\LaptopHealthCheck.ps1          # full check
powershell -ExecutionPolicy Bypass -File .\LaptopHealthCheck.ps1 -Quick   # quick check
```

The script asks for administrator rights by itself if you start it without them.

### First-run prompts you may see

| Prompt | What to do |
| --- | --- |
| "Windows protected your PC" (SmartScreen) | Click **More info > Run anyway**. This appears for any script downloaded from the internet. |
| User Account Control: "Do you want to allow this app to make changes?" | Click **Yes**. The checks need administrator rights to read battery, drive and security data. |
| Fan test question (quick mode only) | Hold your hand at the air vent during the 90-second test, then answer **Y**, **N** or **U** (not sure). |

---

## Options

Add these after the `.bat` name in Command Prompt, or after the `.ps1` path in PowerShell.

| Option | Effect |
| --- | --- |
| `-Quick` | Quick mode (what `Run-QuickCheck.bat` uses) |
| `-QuickScan` | Defender quick scan instead of a full scan (full run about 30-45 min) |
| `-SkipDefenderScan` | No malware scan |
| `-SkipSystemFileCheck` | Skip DISM and SFC (saves 10-30 min) |
| `-SkipNetworkTest` | Skip the internet and speed test |
| `-OutputRoot <folder>` | Save the report somewhere other than the Desktop |
| `-NoPause` | Close the window at the end instead of waiting for Enter (also skips the fan question) |

Examples:

```bat
Run-LaptopHealthCheck.bat -QuickScan
Run-LaptopHealthCheck.bat -SkipDefenderScan -OutputRoot D:\Reports
```

---

## Reading the report

The top of `report.html` gives an overall verdict, then a **Needs attention** table listing every problem with advice on what to do. Each check is marked:

| Status | Meaning |
| --- | --- |
| **FAIL** | A real problem. On a laptop you just bought, raise it with the seller. |
| **WARN** | Worth a look. Often fixable, or a reason to negotiate. |
| **PASS** | Checked and fine. |
| **INFO** | Facts for reference (specs, serial, accounts). |
| **SKIP** | Not run, or not supported on this model. |
| **ERROR** | The check itself could not run. The rest of the report is still valid. |

### Deal-breakers on a used laptop

Return the laptop if the report shows any of these:

- company / domain join, an MDM server, or a Windows Autopilot profile
- a BIOS supervisor password
- an Absolute / Computrace agent the seller cannot have released
- a missing or mismatched serial number with no explanation
- drive health not Healthy, uncorrected drive errors, or SMART failure prediction
- repeated blue screens or fatal WHEA hardware errors
- the fan not spinning up in the quick-mode fan test

### Usually fixable or negotiable

- battery health 60-79% (shorter runtime; negotiate) or under 60% (budget a new battery)
- Windows not genuinely activated (buy a licence)
- missing drivers or updates
- remote-access tools or a proxy left by the previous owner (a clean reinstall removes them)

### Evidence files in the report folder

| File | Contents |
| --- | --- |
| `report.html` | The report |
| `results.json` | Every result in machine-readable form |
| `console-log.txt` | Everything shown in the window while it ran |
| `battery-report.html` | Windows battery report: capacity history and usage |
| `system-information.txt` | Full `msinfo32` report (full mode) |
| `installed-programs.csv`, `startup-programs.csv`, `scheduled-tasks.csv`, `drivers.csv` | Inventories for review |
| `dsregcmd-status.txt` | Device join and work-account status |
| `chkdsk.txt`, `dism-scanhealth.txt`, `sfc-verify.txt` | Disk and system-file scan output (full mode) |

Keep the folder with your receipt. If you need to complain to the seller, it records the laptop's state on that date.

---

## What it checks

| Area | Checks |
| --- | --- |
| **System inventory** | Manufacturer, model and machine type; serial in firmware vs Windows; BIOS version; CPU; each RAM module; drives; graphics; Windows edition and build |
| **Ownership and locks** | Azure AD / domain / enterprise join, work or school accounts, MDM enrolment records, Windows Autopilot profile, Absolute (Computrace) agent in Windows, ThinkPad BIOS passwords and Absolute BIOS setting (via Lenovo WMI), enabled local accounts, administrators, leftover user profiles |
| **Licence** | Activation status and channel (flags KMS volume activation, common with crack tools), factory key embedded in firmware (shown masked), Windows 10 end-of-support warning |
| **Security** | Defender status and definition age, other antivirus, firewall, Secure Boot, TPM, BitLocker / device encryption, UAC, Remote Desktop, remote-access and remote-management tools (AnyDesk, TeamViewer, RustDesk, VNC, ScreenConnect, RMM agents and more), web proxy, hosts file, startup programs, non-Microsoft scheduled tasks |
| **Battery** | Health % (full charge vs design capacity), cycle count, charge status, Windows battery report |
| **Fan** (quick mode) | 90 seconds of full CPU load while you check the vent; thermal sensor readings before and during |
| **Storage** | Drive health, SSD wear %, power-on hours, temperature, uncorrected read/write errors, SMART failure prediction, free space, `chkdsk /scan` |
| **Devices** | Device Manager errors, disabled devices, webcam, Wi-Fi, Bluetooth, audio and fingerprint reader present and working, full driver list, idle thermal zones |
| **Stability** (last 60 days) | WHEA hardware errors, blue screens and crash dumps, unexpected shutdowns, storage errors in the event log, app crashes, Windows reliability index |
| **Updates** | Missing Windows and driver updates, last update installed, pending restart, Lenovo Vantage / System Update present |
| **Network** | Connected adapters, Wi-Fi signal and link rate, internet access, download speed |
| **System files** | `DISM /ScanHealth`, `sfc /verifyonly` |
| **Malware** | Updates Defender definitions, then a full (or quick) scan; earlier detections in Defender history |

Lenovo-specific BIOS checks work on ThinkPad, ThinkBook and other commercial models. IdeaPad, Yoga and Legion models do not expose them to Windows; the report says so and tells you how to check by hand. Every other check works on any Windows laptop.

---

## Buying a used laptop: the full workflow

1. **At the shop, before paying or accepting**
   - Inspect it: battery swelling (does it rock on a flat table?), cracks, hinges, ports, liquid damage.
   - Cold-start it 3 times and watch for errors before Windows loads.
   - Run **`Run-QuickCheck.bat`** from a USB drive. Any FAIL: don't accept it.
   - Optional stress test (see below), 10-25 minutes.
   - Get the **serial number** written on the receipt, plus the warranty terms.
2. **At home, the same day**
   - Run **`Run-LaptopHealthCheck.bat`** overnight.
3. **Clean reinstall of Windows**
   - Removes everything the previous owner left. If setup asks for a company or school login, the laptop is still enrolled: return it.
4. **After a week of normal use**
   - Run the full check again. The crash and hardware-error checks need log history, which a fresh reset empties.

---

## What it cannot test (and free tools for it)

These need a person, a reboot or extra software:

| Test | Free tool | What to look for |
| --- | --- | --- |
| CPU/cooling stress test | [Prime95](https://www.mersenne.org/download/) ("Just Stress Testing", Small FFTs 10 min, then Blend 15 min) | No "FATAL ERROR", "Rounding error" or "worker stopped"; no crash |
| Temperatures during stress | [HWiNFO](https://www.hwinfo.com) (Sensors-only) | CPU temperature levels off below about 95 °C. Recent HWiNFO versions don't show ThinkPad fan speed, so judge the fan by temperature and airflow |
| RAM, thorough | [MemTest86](https://www.memtest86.com) (bootable USB, 4 passes overnight) | 0 errors |
| Full SMART data | [CrystalDiskInfo](https://crystalmark.info/en/) | Health "Good", Media and Data Integrity Errors 0 |
| Screen | Full-screen solid colours in a browser | No dead pixels; no flicker while moving the hinge |
| Keyboard, touchpad, speakers, mic, webcam, ports | Windows itself | Every key, every port, both speakers, clear camera image |
| Battery runtime | A looped video at 50% brightness | Time to 10% is reasonable for the battery health % shown |

---

## Safety and privacy

**The script is read-only.** It changes no settings, removes no software and repairs nothing. The only changes it can cause:

- the PC is kept awake while the script runs (released at the end; power settings are untouched)
- Defender downloads new definitions and quarantines any malware it finds
- the report folder is written to the Desktop

Repairs such as `sfc /scannow` or `DISM /RestoreHealth` are suggested in the report, never run.

**Nothing is uploaded.** The report stays on the laptop. The only network traffic is:

- Windows Update and Defender talking to Microsoft (full mode)
- a connectivity check to `msftconnecttest.com` (Microsoft's own test page)
- a 25 MB download from `speed.cloudflare.com` for the speed test (full mode)

**Before sharing a report**, note that it contains the laptop's serial number, account names and installed programs. The Windows product key is shown masked (last 5 characters only).

The code is a single readable PowerShell file. Read it before you run it.

---

## Troubleshooting

| Problem | Fix |
| --- | --- |
| "LaptopHealthCheck.ps1 was not found next to this file" | You ran the `.bat` from inside the ZIP. Extract the ZIP first. |
| The window opens and closes instantly | Run it from PowerShell (see [Running it](#running-it)) to see the error. |
| "Administrator rights were refused" | Click **Yes** on the UAC prompt, or sign in with an administrator account. |
| "running scripts is disabled on this system" | Use the `.bat` launchers or the `-ExecutionPolicy Bypass` command above. They don't change your system policy. |
| Antivirus warns about the script | Scripts that read security settings sometimes trigger heuristics. Read the code, then allow it. |
| Stuck on "Asking Windows Update..." for a long time | It can take 10+ minutes on a laptop that hasn't updated in months. Leave it, or use `-Quick`. |
| Battery shows FAIL "No battery detected" | The battery is disconnected, dead, or missing. On a desktop this is expected. |
| BIOS passwords show SKIP | Normal on IdeaPad, Yoga and Legion. Check by opening the BIOS (F2 or Fn+F2). |
| No fan speed in HWiNFO | Expected on ThinkPads with recent HWiNFO. Use temperature and airflow instead. |
| Defender scan shows SKIP | Another antivirus is installed and Defender is passive. Scan with that antivirus instead. |

---

## Project structure

```
laptop-health-check/
|-- LaptopHealthCheck.ps1        The script (all checks and the report)
|-- Run-QuickCheck.bat           Launcher: quick mode, about 5 min
|-- Run-LaptopHealthCheck.bat    Launcher: full check, about 1-3 h
|-- README.md
|-- LICENSE
|-- .gitattributes               Keeps Windows line endings for .ps1 and .bat
`-- .github/workflows/test.yml   CI: parses, lints and runs the script on Windows
```

Every push runs the workflow on a GitHub-hosted Windows machine. It parse-checks the script, runs PSScriptAnalyzer, runs a shortened full check (without the Defender scan and DISM/SFC) and the quick mode, fails if any check throws a script error, and uploads the sample reports as build artifacts.

---

## Contributing

Issues and pull requests are welcome, especially:

- results from other laptop brands and models (attach `results.json` with the serial removed)
- false positives or false negatives in the remote-access and lock checks
- checks for other manufacturers' BIOS settings (Dell, HP)

Keep the script compatible with Windows PowerShell 5.1 and ASCII-only (5.1 misreads UTF-8 files without a BOM), and keep it read-only.

---

## Disclaimer

This tool reports what Windows and the firmware say about the laptop. It does not replace a technician's inspection, and a clean report does not guarantee the laptop is fault-free. It is not legal advice about your rights as a buyer. Use it at your own risk.

---

## Licence

[MIT](LICENSE) &copy; 2026 Collins Kibandi
