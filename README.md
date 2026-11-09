# Laptop Health Check

A one-click, unattended health and software audit for a **used Windows laptop**, with extra checks for Lenovo machines. Run it once, walk away, and read the HTML report when it finishes.

It is built to catch the problems that matter most when you buy second-hand: a laptop still locked to a company, an anti-theft agent the previous owner controls, a cracked Windows licence, a worn battery or SSD, hidden crashes, and leftover remote-control or malicious software.

## How to run it

1. On the laptop, open this repository's page, click **Code > Download ZIP**, and extract the ZIP (right-click > Extract All).
2. Plug in the charger and keep the lid open.
3. Double-click **`Run-LaptopHealthCheck.bat`**.
   - If Windows SmartScreen says "Windows protected your PC", click **More info > Run anyway**. This happens with any downloaded script.
4. Click **Yes** on the administrator prompt.
5. Leave it. A full run takes **about 1-3 hours**, mostly the Defender full scan. The report opens in the browser when it is done.

Results go into a folder on the Desktop named `LaptopHealthCheck_<date>_<time>`, containing `report.html` plus evidence files.

### Options

Run from a PowerShell window in the extracted folder, or add the options after the `.bat` name in Command Prompt:

| Option | Effect |
| --- | --- |
| `-QuickScan` | Defender quick scan instead of a full scan (whole run about 30-45 min) |
| `-SkipDefenderScan` | No malware scan |
| `-SkipSystemFileCheck` | Skip DISM and SFC (saves 10-30 min) |
| `-SkipNetworkTest` | Skip the internet and speed test |
| `-OutputRoot <folder>` | Save the report somewhere other than the Desktop |
| `-NoPause` | Close the window automatically at the end |

Example: `Run-LaptopHealthCheck.bat -QuickScan`

## What it checks

| Area | Checks |
| --- | --- |
| System inventory | Model, machine type, serial (firmware vs Windows), BIOS version, CPU, each RAM module, drives, GPU, Windows version; full `msinfo32` report saved |
| Ownership and locks | Azure AD / domain / enterprise join, work accounts, MDM enrolment, Windows Autopilot profile, Absolute (Computrace) agent, ThinkPad BIOS passwords and Absolute BIOS setting, local accounts and leftover user profiles |
| Licence | Activation status and channel (flags KMS / volume activation typical of crack tools), factory key in firmware (masked), Windows 10 end-of-support warning |
| Security | Defender status, other antivirus, firewall, Secure Boot, TPM, drive encryption, UAC, Remote Desktop, **remote-access tools** (AnyDesk, TeamViewer, RustDesk, VNC, RMM agents and more), proxy settings, hosts file, startup programs, non-Microsoft scheduled tasks |
| Battery | Health % (full charge vs design capacity), cycle count, Windows battery report |
| Storage | Drive health, SSD wear %, power-on hours, temperature, uncorrected errors, SMART failure prediction, free space, `chkdsk /scan` |
| Devices | Device Manager errors, disabled devices, presence of webcam, Wi-Fi, Bluetooth, audio and fingerprint reader, full driver list |
| Stability | WHEA hardware errors, blue screens and crash dumps, unexpected shutdowns, storage errors, app crashes, reliability index (last 60 days) |
| Updates | Missing Windows and driver updates, last update installed, pending restart, Lenovo Vantage / System Update present |
| Network | Adapters, Wi-Fi signal and link rate, internet access, download speed |
| System files | `DISM /ScanHealth` and `sfc /verifyonly` |
| Malware | Updates definitions, then a Microsoft Defender full (or quick) scan |

Each result is marked **PASS**, **WARN**, **FAIL**, **INFO**, **SKIP** or **ERROR**, with advice on what to do. Problems are collected at the top of the report under "Needs attention".

## What it does not change

The script is **read-only**. It does not change settings, remove software or repair anything. It only:

- keeps the PC awake while it runs (released at the end; power settings are untouched),
- lets Defender download new definitions and quarantine any malware it finds,
- writes its report folder.

Repairs such as `sfc /scannow` or `DISM /RestoreHealth` are suggested in the report, not run.

## What it cannot test

Some checks need a person or a reboot. Do these by hand:

- Screen: dead pixels, backlight bleed, flicker while moving the hinge
- Keyboard, touchpad, TrackPoint
- Speakers, headphone jack, microphone and webcam image quality
- Every USB, USB-C and HDMI port; Bluetooth pairing
- CPU/GPU stress test with temperatures (Cinebench + HWiNFO, OCCT or FurMark)
- RAM test (MemTest86 from a USB stick, overnight)
- Battery rundown time
- Looking at the BIOS screens on IdeaPad / Yoga / Legion models, which do not expose BIOS passwords to Windows

## Run it twice

1. **Before** the clean reinstall, to find locks, leftover software and hardware problems while the seller can still be reached.
2. **After a week of normal use**, because the crash and hardware-error checks need log history. A fresh reset empties the logs.

## Requirements

- Windows 10 or 11, Windows PowerShell 5.1 (built in)
- An administrator account
- Internet for Windows Update, Defender definitions and the speed test (the other checks work offline)

## Licence

MIT. See [LICENSE](LICENSE).
