<#
.SYNOPSIS
    Laptop Health Check - an unattended software and health audit for a used
    Windows laptop of any brand, with extra firmware checks for Lenovo, Dell
    and HP. Run it once, leave it, read the report.

.DESCRIPTION
    Checks ownership locks (company enrolment, Autopilot, Absolute/Computrace,
    BIOS passwords on Lenovo, Dell and HP business models), Windows licence
    and version, security
    settings, remote-access software, battery and SSD health, device and
    driver problems, crash and hardware-error logs, pending Windows updates,
    network, system file integrity (DISM + SFC) and runs a Microsoft Defender
    scan. Writes an HTML report plus evidence files to a folder on the Desktop.

    The script is read-only: it changes no settings. The only things that can
    change are Defender quarantining malware it finds and Defender downloading
    new virus definitions.

.PARAMETER Quick
    Quick check, about 5 minutes, for testing a laptop before you accept it
    (for example at the shop). Keeps the ownership, licence, battery, SSD,
    device and crash-log checks, adds a 90-second fan test that asks you
    whether the fan spun up, and skips the long scans (Defender, DISM/SFC,
    chkdsk, Windows Update search, speed test, msinfo32).

.PARAMETER QuickScan
    Run a Defender quick scan (minutes) instead of a full scan (1-3 hours).

.PARAMETER SkipDefenderScan
    Skip the Defender scan entirely.

.PARAMETER SkipSystemFileCheck
    Skip DISM and SFC (saves 10-30 minutes).

.PARAMETER SkipNetworkTest
    Skip the internet connectivity and download-speed test.

.PARAMETER OutputRoot
    Folder in which the report folder is created. Default: the Desktop.

.PARAMETER NoPause
    Do not wait for Enter at the end.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\LaptopHealthCheck.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\LaptopHealthCheck.ps1 -QuickScan
#>
[CmdletBinding()]
param(
    [switch]$Quick,
    [switch]$QuickScan,
    [switch]$SkipDefenderScan,
    [switch]$SkipSystemFileCheck,
    [switch]$SkipNetworkTest,
    [switch]$NoPause,
    [string]$OutputRoot = ''
)

$ScriptVersion = '1.2.0'

# ---------------------------------------------------------------------------
# Pre-flight: Windows only, then self-elevate to Administrator
# ---------------------------------------------------------------------------
if ($env:OS -ne 'Windows_NT') {
    Write-Error 'This script only runs on Windows.'
    exit 1
}

if (-not $OutputRoot) { $OutputRoot = [Environment]::GetFolderPath('Desktop') }
if (-not $OutputRoot) { $OutputRoot = $env:USERPROFILE }
$OutputRoot = $OutputRoot.TrimEnd('\')   # a trailing \ would break the quoting below

# Arguments to start this script again with the same options
$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
             '-OutputRoot', ('"{0}"' -f $OutputRoot))
foreach ($name in @('Quick', 'QuickScan', 'SkipDefenderScan', 'SkipSystemFileCheck', 'SkipNetworkTest', 'NoPause')) {
    if ($PSBoundParameters.ContainsKey($name) -and $PSBoundParameters[$name]) { $argList += "-$name" }
}

# 32-bit PowerShell on 64-bit Windows cannot run DISM and sees redirected
# registry keys, so restart in the native 64-bit PowerShell.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $nativePs = Join-Path $env:windir 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $nativePs) {
        $p = Start-Process -FilePath $nativePs -ArgumentList $argList -Wait -PassThru -NoNewWindow
        exit $p.ExitCode
    }
}

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Requesting administrator rights (click Yes on the prompt)...' -ForegroundColor Yellow
    try {
        $selfPs = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path $selfPs)) { $selfPs = 'powershell.exe' }
        Start-Process -FilePath $selfPs -ArgumentList $argList -Verb RunAs -ErrorAction Stop
    } catch {
        Write-Host 'Administrator rights were refused. The checks need them, so the script will stop.' -ForegroundColor Red
        Start-Sleep -Seconds 8
    }
    exit
}

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'   # makes Invoke-WebRequest fast on PowerShell 5.1
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

try { $Host.UI.RawUI.WindowTitle = 'Laptop Health Check - running, leave this window open' } catch { }

# ---------------------------------------------------------------------------
# Shared state and helpers
# ---------------------------------------------------------------------------
$script:Results        = New-Object System.Collections.Generic.List[object]
$script:Artifacts      = New-Object System.Collections.Generic.List[object]
$script:Timings        = [ordered]@{}
$script:Facts          = @{}
$script:CurrentSection = 'General'
$script:StartTime      = Get-Date
$reportFolderName      = 'LaptopHealthCheck_' + (Get-Date -Format 'yyyy-MM-dd_HHmm')
$script:OutDir         = Join-Path $OutputRoot $reportFolderName
try {
    # Test that we can really write here: Controlled folder access (ransomware
    # protection) or folder permissions can block writes to the Desktop.
    New-Item -ItemType Directory -Path $script:OutDir -Force -ErrorAction Stop | Out-Null
    $probe = Join-Path $script:OutDir 'write-test.tmp'
    Set-Content -Path $probe -Value 'ok' -ErrorAction Stop
    Remove-Item -Path $probe -Force -ErrorAction SilentlyContinue
} catch {
    $fallbackRoot = Join-Path $env:SystemDrive 'LaptopHealthCheck-Reports'
    Write-Host ('Cannot write to {0} (Controlled folder access or permissions). Saving the report to {1} instead.' -f $OutputRoot, $fallbackRoot) -ForegroundColor Yellow
    $script:OutDir = Join-Path $fallbackRoot $reportFolderName
    New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null
}

try { Start-Transcript -Path (Join-Path $script:OutDir 'console-log.txt') -Force | Out-Null } catch { }

function Add-Result {
    param(
        [string]$Check,
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO', 'SKIP', 'ERROR')][string]$Status,
        [string]$Detail = '',
        [string]$Advice = ''
    )
    $script:Results.Add([pscustomobject]@{
        Section = $script:CurrentSection
        Check   = $Check
        Status  = $Status
        Detail  = $Detail
        Advice  = $Advice
    })
    $color = 'Gray'
    switch ($Status) {
        'PASS'  { $color = 'Green' }
        'WARN'  { $color = 'Yellow' }
        'FAIL'  { $color = 'Red' }
        'ERROR' { $color = 'Magenta' }
    }
    $shown = $Detail
    if ($shown.Length -gt 160) { $shown = $shown.Substring(0, 157) + '...' }
    $shown = $shown -replace "`r?`n", ' | '
    Write-Host ('  [{0,-5}] {1}: {2}' -f $Status, $Check, $shown) -ForegroundColor $color
}

function Save-Artifact {
    param([string]$FileName, [string]$Description, $Content)
    $path = Join-Path $script:OutDir $FileName
    if ($null -ne $Content) {
        Set-Content -Path $path -Value $Content -Encoding UTF8
    }
    if (Test-Path $path) {
        $script:Artifacts.Add([pscustomobject]@{ File = $FileName; Description = $Description })
    }
}

function Invoke-Native {
    # Runs a console program and returns @{ Output = text; ExitCode = n }
    param([string]$FilePath, [string[]]$Arguments)
    $out = & $FilePath @Arguments 2>&1 | Out-String
    return @{ Output = $out; ExitCode = $LASTEXITCODE }
}

function Get-EventsSafe {
    param([hashtable]$Filter)
    try { return @(Get-WinEvent -FilterHashtable $Filter -ErrorAction Stop) } catch { return @() }
}

function Hide-ProductKey {
    param([string]$Key)
    if (-not $Key) { return '' }
    $parts = $Key.Split('-')
    for ($i = 0; $i -lt $parts.Count - 1; $i++) { $parts[$i] = 'XXXXX' }
    return ($parts -join '-')
}

function Get-InstalledPrograms {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'Registry::HKEY_USERS\*\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $all = foreach ($p in $paths) {
        Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName } |
            Select-Object DisplayName, DisplayVersion, Publisher, InstallDate
    }
    return @($all | Sort-Object DisplayName -Unique)
}

function Format-Bytes {
    param([double]$Bytes)
    $kb = 1024.0; $mb = $kb * 1024; $gb = $mb * 1024; $tb = $gb * 1024
    if ($Bytes -ge $tb) { return ('{0:N2} TB' -f ($Bytes / $tb)) }
    if ($Bytes -ge $gb) { return ('{0:N1} GB' -f ($Bytes / $gb)) }
    return ('{0:N0} MB' -f ($Bytes / $mb))
}

# Which brand is this? Used for brand-specific firmware checks and advice.
$script:VendorInfo = @{
    Lenovo    = @{ Support = 'https://pcsupport.lenovo.com';          BiosKey = 'F1 (ThinkPad) or F2 / Fn+F2 / the Novo button (IdeaPad, Yoga, Legion)'; Tools = 'Lenovo Vantage (Microsoft Store), or Lenovo System Update / Commercial Vantage on ThinkPads'; ToolPattern = 'Lenovo ?(System Update|Vantage|Commercial Vantage|Companion|SettingsforEnterprise)' }
    Dell      = @{ Support = 'https://www.dell.com/support';          BiosKey = 'F2';                                       Tools = 'Dell Command | Update or Dell SupportAssist';          ToolPattern = 'Dell ?(Command|SupportAssist|Update)' }
    HP        = @{ Support = 'https://support.hp.com';                BiosKey = 'Esc, then F10';                            Tools = 'HP Support Assistant or HP Image Assistant';           ToolPattern = 'HP ?(Support ?Assistant|Image Assistant)|myHP' }
    ASUS      = @{ Support = 'https://www.asus.com/support';          BiosKey = 'F2 or Del';                                Tools = 'MyASUS (Microsoft Store)';                             ToolPattern = 'MyASUS|ASUSPCAssistant' }
    Acer      = @{ Support = 'https://www.acer.com/support';          BiosKey = 'F2';                                       Tools = 'Acer Care Center';                                     ToolPattern = 'Acer ?Care ?Center|AcerCareCenter' }
    MSI       = @{ Support = 'https://www.msi.com/support';           BiosKey = 'Del';                                      Tools = 'MSI Center';                                           ToolPattern = 'MSI ?Center|Dragon ?Center' }
    Microsoft = @{ Support = 'https://support.microsoft.com/surface'; BiosKey = 'hold Volume Up while pressing Power';       Tools = 'Windows Update (Surface drivers and firmware come through it)'; ToolPattern = '' }
    Other     = @{ Support = "the manufacturer's support website";    BiosKey = 'usually F2, Del, F10 or Esc right after power-on'; Tools = "the manufacturer's driver/update app, or Windows Update"; ToolPattern = '' }
}
$script:Vendor = 'Other'
try {
    $mfr = '' + (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Manufacturer
    if     ($mfr -match 'LENOVO')               { $script:Vendor = 'Lenovo' }
    elseif ($mfr -match 'Dell')                 { $script:Vendor = 'Dell' }
    elseif ($mfr -match '^HP|Hewlett')          { $script:Vendor = 'HP' }
    elseif ($mfr -match 'ASUS')                 { $script:Vendor = 'ASUS' }
    elseif ($mfr -match '^Acer')                { $script:Vendor = 'Acer' }
    elseif ($mfr -match '^Micro-Star|^MSI')     { $script:Vendor = 'MSI' }
    elseif ($mfr -match '^Microsoft')           { $script:Vendor = 'Microsoft' }
} catch { }
$script:VI = $script:VendorInfo[$script:Vendor]

# Keep the PC awake while the script runs (does not change power settings).
$keepAwake = $false
try {
    Add-Type -Namespace LaptopHealthCheck -Name Power -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern uint SetThreadExecutionState(uint esFlags);
'@ -ErrorAction Stop
    # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
    [void][LaptopHealthCheck.Power]::SetThreadExecutionState([uint32]2147483649)
    $keepAwake = $true
} catch { }

# ---------------------------------------------------------------------------
# The checks. Each step runs in its own try/catch, so one failure never
# stops the rest.
# ---------------------------------------------------------------------------
$Steps = New-Object System.Collections.Generic.List[object]

# 1 ------------------------------------------------------------------------
$Steps.Add(@{ Name = 'System inventory'; Body = {
    $cs   = Get-CimInstance Win32_ComputerSystem
    $csp  = Get-CimInstance Win32_ComputerSystemProduct
    $bios = Get-CimInstance Win32_BIOS
    $os   = Get-CimInstance Win32_OperatingSystem
    $cpus = @(Get-CimInstance Win32_Processor)
    $ram  = @(Get-CimInstance Win32_PhysicalMemory)
    $gpus = @(Get-CimInstance Win32_VideoController)

    $script:Facts['Serial'] = ('' + $csp.IdentifyingNumber).Trim()
    if ($script:Vendor -eq 'Lenovo') {
        # Lenovo keeps the friendly name (e.g. ThinkPad T495s) in Version and the machine type in Name
        $script:Facts['Model'] = ('{0} {1} ({2})' -f $cs.Manufacturer, $csp.Version, $csp.Name).Trim()
    } else {
        $script:Facts['Model'] = ('{0} {1}' -f $cs.Manufacturer, $cs.Model).Trim()
    }
    Add-Result 'Manufacturer and model' 'INFO' $script:Facts['Model']

    $mfrPlaceholder = '^(|System manufacturer|To be filled by O\.E\.M\.|Default string|OEM|Not Applicable)$'
    if (('' + $cs.Manufacturer).Trim() -match $mfrPlaceholder -or ('' + $cs.Model).Trim() -match '^(|System Product Name|To be filled by O\.E\.M\.|Default string)$') {
        Add-Result 'Firmware identity' 'WARN' ("Maker/model not programmed in the firmware ('{0}' / '{1}')." -f $cs.Manufacturer, $cs.Model) 'On a branded laptop this usually means the motherboard was replaced and never programmed. Ask the seller.'
    }

    $pcType = [int]$cs.PCSystemType
    $chassis = @()
    try { $chassis = @((Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes) } catch { }
    $portableChassis = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $script:Facts['IsPortable'] = ($pcType -eq 2) -or (@($chassis | Where-Object { $portableChassis -contains [int]$_ }).Count -gt 0)

    $placeholder = '^(|0+|Default string|To be filled by O\.E\.M\.|System Serial Number|None|Not Applicable)$'
    $serialA = ('' + $csp.IdentifyingNumber).Trim()
    $serialB = ('' + $bios.SerialNumber).Trim()
    if ($serialA -match $placeholder -or $serialB -match $placeholder) {
        Add-Result 'Serial number' 'FAIL' ("Serial is missing or a placeholder ('{0}' / '{1}')." -f $serialA, $serialB) 'A blank serial usually means a replacement motherboard that was never programmed. Warranty lookup will not work; ask the seller.'
    } elseif ($serialA -ne $serialB) {
        Add-Result 'Serial number' 'WARN' ("Two different serials reported: {0} and {1}" -f $serialA, $serialB) 'Compare both with the sticker under the laptop.'
    } else {
        Add-Result 'Serial number' 'INFO' $serialA ('Must match the sticker under the laptop. Enter it at {0} to see the warranty status and original factory specs.' -f $script:VI.Support)
    }

    $biosDate = ''
    if ($bios.ReleaseDate) { $biosDate = ([datetime]$bios.ReleaseDate).ToString('yyyy-MM-dd') }
    Add-Result 'BIOS version' 'INFO' ('{0} (released {1})' -f $bios.SMBIOSBIOSVersion, $biosDate)

    foreach ($c in $cpus) {
        Add-Result 'Processor' 'INFO' ('{0}  |  {1} cores / {2} threads  |  max {3} MHz' -f $c.Name.Trim(), $c.NumberOfCores, $c.NumberOfLogicalProcessors, $c.MaxClockSpeed)
    }

    $ramTotal = ($ram | Measure-Object -Property Capacity -Sum).Sum
    $sticks = foreach ($m in $ram) {
        $speed = $m.ConfiguredClockSpeed
        if (-not $speed) { $speed = $m.Speed }
        '{0}: {1} {2} {3} @ {4} MHz' -f $m.DeviceLocator, (Format-Bytes $m.Capacity), ('' + $m.Manufacturer).Trim(), ('' + $m.PartNumber).Trim(), $speed
    }
    Add-Result 'Memory (RAM)' 'INFO' ("Total {0} in {1} module(s)`n{2}" -f (Format-Bytes $ramTotal), $ram.Count, ($sticks -join "`n")) 'Compare with what the seller advertised.'

    try {
        foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop)) {
            Add-Result 'Storage drive' 'INFO' ('{0}  |  {1} {2}  |  {3}' -f $d.FriendlyName, $d.BusType, $d.MediaType, (Format-Bytes $d.Size))
        }
    } catch {
        foreach ($d in @(Get-CimInstance Win32_DiskDrive)) {
            Add-Result 'Storage drive' 'INFO' ('{0}  |  {1}' -f $d.Model, (Format-Bytes $d.Size))
        }
    }

    foreach ($g in $gpus) {
        Add-Result 'Graphics' 'INFO' ('{0}  |  driver {1}' -f $g.Name, $g.DriverVersion)
    }

    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $displayVersion = $cv.DisplayVersion
    if (-not $displayVersion) { $displayVersion = $cv.ReleaseId }
    $script:Facts['Build'] = [int]$cv.CurrentBuildNumber
    $installDate = ''
    if ($os.InstallDate) { $installDate = ([datetime]$os.InstallDate).ToString('yyyy-MM-dd') }
    $osName = $os.Caption
    if ($script:Facts['Build'] -ge 22000) { $osName = $osName -replace 'Windows 10', 'Windows 11' }
    $script:Facts['OS'] = '{0} {1} (build {2}.{3})' -f $osName, $displayVersion, $cv.CurrentBuildNumber, $cv.UBR
    Add-Result 'Windows' 'INFO' ('{0}, installed {1}' -f $script:Facts['OS'], $installDate)

    if (-not $Quick) { try {
        Write-Host '  Saving the full System Information report (1-3 minutes)...' -ForegroundColor DarkGray
        $p = Start-Process -FilePath 'msinfo32.exe' -ArgumentList @('/report', ('"{0}"' -f (Join-Path $script:OutDir 'system-information.txt'))) -PassThru -WindowStyle Hidden
        if (-not $p.WaitForExit(600000)) { try { $p.Kill() } catch { } }
        Save-Artifact 'system-information.txt' 'Full System Information report (msinfo32)' $null
    } catch { } }
}})

# 2 ------------------------------------------------------------------------
$Steps.Add(@{ Name = 'Ownership and lock checks'; Body = {
    # Azure AD / domain / company enrolment
    $ds = (Invoke-Native 'dsregcmd.exe' @('/status')).Output
    Save-Artifact 'dsregcmd-status.txt' 'Device join and work-account status (dsregcmd /status)' $ds
    $dsv = @{}
    foreach ($line in ($ds -split "`r?`n")) {
        if ($line -match '^\s*([A-Za-z]+)\s*:\s*(.+?)\s*$') { if (-not $dsv.ContainsKey($Matches[1])) { $dsv[$Matches[1]] = $Matches[2] } }
    }
    $joined = @()
    foreach ($k in @('AzureAdJoined', 'EnterpriseJoined', 'DomainJoined')) { if ($dsv[$k] -eq 'YES') { $joined += $k } }
    if ($joined.Count -gt 0) {
        $tenant = ''
        if ($dsv['TenantName']) { $tenant = ' (organisation: ' + $dsv['TenantName'] + ')' }
        Add-Result 'Company / domain join' 'FAIL' (($joined -join ', ') + ' = YES' + $tenant) 'The laptop is still joined to an organisation. Return it unless the seller removes it and a clean reinstall shows no company login.'
    } elseif ($dsv.Count -eq 0) {
        Add-Result 'Company / domain join' 'WARN' 'Could not read dsregcmd output.' 'Run "dsregcmd /status" manually and check AzureAdJoined / DomainJoined say NO.'
    } else {
        Add-Result 'Company / domain join' 'PASS' 'AzureAdJoined, EnterpriseJoined and DomainJoined are all NO.'
    }
    if ($dsv['WorkplaceJoined'] -eq 'YES') {
        Add-Result 'Work or school account' 'WARN' 'A work or school account is registered on this PC.' 'Remove it in Settings > Accounts > Access work or school, or do the clean reinstall.'
    }
    if ($dsv['MdmUrl']) {
        Add-Result 'MDM server' 'FAIL' ('Device management URL: ' + $dsv['MdmUrl']) 'The laptop is managed by an organisation (Intune or similar). Return it.'
    }

    # MDM enrolment registry
    $enrolments = @()
    $enrRoot = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
    if (Test-Path $enrRoot) {
        foreach ($k in @(Get-ChildItem $enrRoot -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.PSObject.Properties['ProviderID'] -and $p.ProviderID) {
                $upn = ''
                if ($p.PSObject.Properties['UPN'] -and $p.UPN) { $upn = ' (' + $p.UPN + ')' }
                $enrolments += ($p.ProviderID + $upn)
            }
        }
    }
    if ($enrolments.Count -gt 0) {
        Add-Result 'Device-management enrolment' 'WARN' ('Enrolment records found: ' + (($enrolments | Select-Object -Unique) -join '; ')) 'Leftover or active management. Confirm with a clean reinstall of Windows that setup shows no company login.'
    } else {
        Add-Result 'Device-management enrolment' 'PASS' 'No MDM enrolment records.'
    }

    # Windows Autopilot
    $apKey = 'HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot'
    $apTenant = ''
    if (Test-Path $apKey) {
        $ap = Get-ItemProperty $apKey -ErrorAction SilentlyContinue
        if ($ap -and $ap.PSObject.Properties['CloudAssignedTenantDomain']) { $apTenant = $ap.CloudAssignedTenantDomain }
    }
    if ($apTenant) {
        Add-Result 'Windows Autopilot' 'FAIL' ('Autopilot profile from organisation: ' + $apTenant) 'After any reset this laptop will demand that company login. Only the company can release it. Return it.'
    } else {
        Add-Result 'Windows Autopilot' 'PASS' 'No Autopilot profile found on this installation.' 'Final proof: do the clean reinstall while the seller is reachable and confirm setup shows no company name.'
    }

    # Absolute / Computrace agent in Windows
    $absSvc = @(Get-CimInstance Win32_Service | Where-Object { $_.Name -match '^rpcnet' -or $_.DisplayName -match 'Absolute|Computrace|rpcnet' })
    $absFiles = @()
    foreach ($dir in @("$env:windir\System32", "$env:windir\SysWOW64")) {
        foreach ($f in @('rpcnet.exe', 'rpcnetp.exe', 'rpcnet.dll', 'rpcnetp.dll')) {
            $fp = Join-Path $dir $f
            if (Test-Path $fp) { $absFiles += $fp }
        }
    }
    if ($absSvc.Count -gt 0 -or $absFiles.Count -gt 0) {
        $what = @()
        if ($absSvc.Count -gt 0) { $what += ('services: ' + (($absSvc | ForEach-Object { $_.Name + ' (' + $_.State + ')' }) -join ', ')) }
        if ($absFiles.Count -gt 0) { $what += ('files: ' + ($absFiles -join ', ')) }
        Add-Result 'Absolute / Computrace agent' 'WARN' ($what -join ' | ') 'This anti-theft agent lets the previous owner track or lock the laptop. Check its BIOS setting (Security menu) and ask the seller to have it released.'
    } else {
        Add-Result 'Absolute / Computrace agent' 'PASS' 'No Absolute (Computrace) agent found in Windows.'
    }

    # BIOS passwords and the Absolute BIOS setting, read from the maker's firmware
    # WMI where it exists (Lenovo ThinkPad/ThinkBook, Dell and HP business models).
    # Every other model gets a SKIP with instructions for a manual check.
    $manualBios = ('Check by hand: restart, open the BIOS ({0}) and confirm it opens without asking for a password.' -f $script:VI.BiosKey)
    $pwChecked = $false; $pwSet = @(); $pwSupervisor = $false
    try {
        if ($script:Vendor -eq 'Lenovo') {
            $pw = @(Get-CimInstance -Namespace root\wmi -ClassName Lenovo_BiosPasswordSettings -ErrorAction Stop)
            if ($pw.Count -gt 0) {
                $pwChecked = $true
                $state = [int]$pw[0].PasswordState
                if ($state -band 1)  { $pwSet += 'power-on' }
                if ($state -band 2)  { $pwSet += 'supervisor'; $pwSupervisor = $true }
                if ($state -band 4)  { $pwSet += 'hard-disk' }
                if ($state -band 64) { $pwSet += 'system-management' }
                if ($state -ne 0 -and $pwSet.Count -eq 0) { $pwSet += ('state code ' + $state) }
            }
        } elseif ($script:Vendor -eq 'HP') {
            $pw = @(Get-CimInstance -Namespace root\HP\InstrumentedBIOS -ClassName HP_BIOSPassword -ErrorAction Stop)
            if ($pw.Count -gt 0) {
                $pwChecked = $true
                foreach ($p in @($pw | Where-Object { [int]$_.IsSet -eq 1 })) {
                    $pwSet += $p.Name
                    if ($p.Name -match 'Setup|Admin') { $pwSupervisor = $true }
                }
            }
        } elseif ($script:Vendor -eq 'Dell') {
            $pw = @(Get-CimInstance -Namespace root\dcim\sysman\wmisecurity -ClassName PasswordObject -ErrorAction Stop)
            if ($pw.Count -gt 0) {
                $pwChecked = $true
                foreach ($p in @($pw | Where-Object { [int]$_.IsPasswordSet -eq 1 })) {
                    $pwSet += $p.NameId
                    if ($p.NameId -match 'Admin') { $pwSupervisor = $true }
                }
            }
        }
    } catch { $pwChecked = $false }

    if (-not $pwChecked) {
        Add-Result 'BIOS passwords' 'SKIP' 'This model does not report BIOS passwords to Windows.' $manualBios
    } elseif ($pwSupervisor) {
        Add-Result 'BIOS passwords' 'FAIL' ('Passwords set: ' + ($pwSet -join ', ')) 'A supervisor/admin BIOS password locks the firmware and usually cannot be removed without the previous owner. Get it from the seller or return the laptop.'
    } elseif ($pwSet.Count -gt 0) {
        Add-Result 'BIOS passwords' 'WARN' ('Passwords set: ' + ($pwSet -join ', ')) 'Get the password from the seller and remove it in the BIOS.'
    } else {
        Add-Result 'BIOS passwords' 'PASS' 'No BIOS passwords set.'
    }

    $absSettings = @()
    try {
        if ($script:Vendor -eq 'Lenovo') {
            foreach ($s in @(Get-CimInstance -Namespace root\wmi -ClassName Lenovo_BiosSetting -ErrorAction Stop | Where-Object { $_.CurrentSetting -match '^\w*(Computrace|Absolute)\w*\s*,' })) {
                $pair = ($s.CurrentSetting -split ';')[0]
                $absSettings += @{ Name = ($pair -split ',')[0]; Value = ('' + ($pair -split ',', 2)[1]) }
            }
        } elseif ($script:Vendor -eq 'HP') {
            foreach ($s in @(Get-CimInstance -Namespace root\HP\InstrumentedBIOS -ClassName HP_BIOSSetting -ErrorAction Stop | Where-Object { $_.Name -match 'Absolute|Computrace' })) {
                $v = ''
                if ($s.PSObject.Properties['CurrentValue'] -and $s.CurrentValue) { $v = $s.CurrentValue }
                elseif ($s.PSObject.Properties['Value']) { $v = $s.Value }
                $absSettings += @{ Name = $s.Name; Value = ('' + $v) }
            }
        } elseif ($script:Vendor -eq 'Dell') {
            foreach ($s in @(Get-CimInstance -Namespace root\dcim\sysman\biosattributes -ClassName EnumerationAttribute -ErrorAction Stop | Where-Object { $_.AttributeName -match 'Absolute|Computrace' })) {
                $absSettings += @{ Name = $s.AttributeName; Value = (@($s.CurrentValue) -join ', ') }
            }
        }
    } catch { }
    foreach ($a in $absSettings) {
        if ($a.Value -match '^\s*(Enable|Activ)') {
            Add-Result ('BIOS: ' + $a.Name) 'WARN' $a.Value 'The Absolute anti-theft module can be activated by the previous owner. Ask the seller; ideally it shows Disabled, Inactive or Permanently Disabled.'
        } elseif ($a.Value -match 'Disable|Inactive|Deactivat') {
            Add-Result ('BIOS: ' + $a.Name) 'PASS' $a.Value
        } else {
            Add-Result ('BIOS: ' + $a.Name) 'INFO' $a.Value
        }
    }

    # Local accounts and leftover profiles
    $users = @()
    try { $users = @(Get-LocalUser -ErrorAction Stop | Where-Object { $_.Enabled }) } catch { }
    if ($users.Count -gt 0) {
        Add-Result 'Enabled local accounts' 'INFO' (($users | ForEach-Object { $_.Name }) -join ', ') 'Any account the new owner does not recognise belongs to a previous owner. A clean reinstall removes them.'
    }
    try {
        # Read the Administrators group by its SID through ADSI: works in every
        # Windows language (the group name and "net localgroup" text are localised).
        $adminName = (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
        $group = [ADSI]('WinNT://{0}/{1},group' -f $env:COMPUTERNAME, $adminName)
        $members = @($group.psbase.Invoke('Members') | ForEach-Object { $_.GetType().InvokeMember('Name', 'GetProperty', $null, $_, $null) })
        Add-Result 'Administrator accounts' 'INFO' ($members -join ', ')
    } catch { }
    $profiles = @(Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special } | ForEach-Object { $_.LocalPath })
    Add-Result 'User profiles on disk' 'INFO' ($profiles -join ', ')
}})

# 3 ------------------------------------------------------------------------
$Steps.Add(@{ Name = 'Windows licence and version'; Body = {
    $winAppId = '55c92734-d682-4d71-983e-d6ec3f16059f'
    $lic = @(Get-CimInstance SoftwareLicensingProduct -Filter ("ApplicationID='{0}' AND PartialProductKey IS NOT NULL" -f $winAppId))
    if ($lic.Count -eq 0) {
        Add-Result 'Activation' 'FAIL' 'No Windows product key is installed.' 'Windows is not activated. It should reactivate after a clean reinstall if the laptop has a factory key; otherwise buy a genuine licence.'
    } else {
        $l = $lic[0]
        $statusNames = @{ 0 = 'Unlicensed'; 1 = 'Licensed'; 2 = 'Initial grace period'; 3 = 'Additional grace period'; 4 = 'Non-genuine grace period'; 5 = 'Notification mode'; 6 = 'Extended grace period' }
        $statusText = $statusNames[[int]$l.LicenseStatus]
        # ProductKeyChannel (e.g. OEM:DM, Retail, Volume:GVLK, Volume:MAK) is not
        # localised; the Description text is the fallback for older builds.
        $channel = 'unknown'
        if ($l.PSObject.Properties['ProductKeyChannel'] -and $l.ProductKeyChannel) { $channel = '' + $l.ProductKeyChannel }
        elseif ($l.Description -match ',\s*(\S+)\s+channel') { $channel = $Matches[1] }
        $kmsHost = ''
        if ($l.PSObject.Properties['KeyManagementServiceMachine'] -and $l.KeyManagementServiceMachine) { $kmsHost = '' + $l.KeyManagementServiceMachine }
        $detail = '{0} | status: {1} | channel: {2} | key ends {3}' -f $l.Name, $statusText, $channel, $l.PartialProductKey
        if ([int]$l.LicenseStatus -ne 1) {
            Add-Result 'Activation' 'FAIL' $detail 'Windows is not genuinely activated.'
        } elseif ($channel -match 'KMS|GVLK' -or $kmsHost) {
            $kms = ''
            if ($kmsHost) { $kms = ' | KMS host: ' + $kmsHost }
            Add-Result 'Activation' 'WARN' ($detail + $kms) 'Volume (KMS) activation on a personal laptop usually means a crack tool or a company licence that will lapse. Plan a genuine licence; the clean reinstall may reactivate with the factory key.'
        } elseif ($channel -match 'MAK') {
            Add-Result 'Activation' 'WARN' $detail 'A volume (MAK) key belongs to a company or school licence, not to this laptop. It can be blocked at any time; plan a genuine licence.'
        } else {
            Add-Result 'Activation' 'PASS' $detail
        }
    }

    try {
        $oa3 = (Get-CimInstance SoftwareLicensingService).OA3xOriginalProductKey
        if ($oa3) {
            Add-Result 'Factory product key in firmware' 'PASS' ('Present: ' + (Hide-ProductKey $oa3)) 'Windows will reactivate by itself after a clean reinstall.'
        } else {
            Add-Result 'Factory product key in firmware' 'INFO' 'None embedded.' 'Normal on some models and on laptops sold without Windows. Activation then depends on a digital licence or a key you buy.'
        }
    } catch { }

    if (-not $script:Facts['Build']) {
        Add-Result 'Windows version' 'INFO' 'Could not read the Windows build number.' 'Run "winver" to see the version.'
    } elseif ($script:Facts['Build'] -lt 22000) {
        Add-Result 'Windows 10' 'WARN' 'This laptop runs Windows 10, which reached end of support on 14 Oct 2025.' 'Upgrade to Windows 11 if PC Health Check says it is eligible; otherwise enrol in the free consumer Extended Security Updates (currently through 12 Oct 2027).'
    } else {
        Add-Result 'Windows 11' 'PASS' $script:Facts['OS'] 'The Windows Update step below shows whether a newer version is waiting.'
    }
}})

# 4 ------------------------------------------------------------------------
$Steps.Add(@{ Name = 'Security settings and unwanted software'; Body = {
    # Antivirus
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $script:Facts['DefenderMode'] = '' + $mp.AMRunningMode
        if ($mp.AntivirusEnabled -and $mp.RealTimeProtectionEnabled) {
            Add-Result 'Microsoft Defender' 'PASS' ('Real-time protection on | definitions {0} day(s) old | tamper protection: {1}' -f $mp.AntivirusSignatureAge, $mp.IsTamperProtected)
        } else {
            Add-Result 'Microsoft Defender' 'WARN' ('Antivirus enabled: {0} | real-time: {1} | mode: {2}' -f $mp.AntivirusEnabled, $mp.RealTimeProtectionEnabled, $mp.AMRunningMode) 'Turn real-time protection on in Windows Security, unless another antivirus is installed.'
        }
    } catch {
        $script:Facts['DefenderMode'] = 'Unavailable'
        Add-Result 'Microsoft Defender' 'WARN' 'Could not read Defender status (it may be removed or replaced by another antivirus).' $_.Exception.Message
    }
    try {
        $av = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop | ForEach-Object { $_.displayName })
        if ($av.Count -gt 0) { Add-Result 'Antivirus products registered' 'INFO' ($av -join ', ') }
    } catch { }

    # Firewall
    try {
        $fw = @(Get-NetFirewallProfile -ErrorAction Stop)
        $off = @($fw | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Name })
        if ($off.Count -eq 0) { Add-Result 'Firewall' 'PASS' 'On for Domain, Private and Public networks.' }
        else { Add-Result 'Firewall' 'WARN' ('Off for: ' + ($off -join ', ')) 'Turn it on in Windows Security > Firewall & network protection.' }
    } catch { }

    # Secure Boot and TPM
    try {
        if (Confirm-SecureBootUEFI -ErrorAction Stop) { Add-Result 'Secure Boot' 'PASS' 'Enabled.' }
        else { Add-Result 'Secure Boot' 'WARN' 'Disabled.' 'Enable Secure Boot in the BIOS Security menu.' }
    } catch {
        Add-Result 'Secure Boot' 'WARN' 'Not supported or the PC is booting in legacy (CSM) mode.' 'Windows 11 needs UEFI with Secure Boot.'
    }
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        $spec = ''
        try { $spec = ((Get-CimInstance -Namespace root\cimv2\Security\MicrosoftTpm -ClassName Win32_Tpm -ErrorAction Stop).SpecVersion -split ',')[0].Trim() } catch { }
        if ($tpm.TpmPresent -and $tpm.TpmReady) { Add-Result 'TPM security chip' 'PASS' ('Present and ready, version ' + $spec) }
        elseif ($tpm.TpmPresent) { Add-Result 'TPM security chip' 'WARN' ('Present but not ready, version ' + $spec) 'Enable the Security Chip in the BIOS, or clear it in tpm.msc after the reinstall.' }
        else { Add-Result 'TPM security chip' 'WARN' 'Not detected.' 'Enable the Security Chip / PTT / fTPM in the BIOS.' }
    } catch { }

    # Drive encryption
    $bitlockerDone = $false
    try {
        $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        $bitlockerDone = $true
        if ([string]$bl.ProtectionStatus -eq 'On') {
            Add-Result 'Drive encryption' 'PASS' ('BitLocker on (' + $bl.VolumeStatus + ')') 'Make sure the recovery key is saved in YOUR Microsoft account (account.microsoft.com/devices/recoverykey), not a previous owner''s.'
        } else {
            Add-Result 'Drive encryption' 'INFO' ('Off (' + $bl.VolumeStatus + ')') 'Turn on device encryption after the clean reinstall, signed in with your own Microsoft account.'
        }
    } catch { }
    if (-not $bitlockerDone) {
        $mb = (Invoke-Native 'manage-bde.exe' @('-status', $env:SystemDrive)).Output
        if ($mb -match 'Protection Status:\s*(.+)') { Add-Result 'Drive encryption' 'INFO' ('Protection status: ' + $Matches[1].Trim()) }
    }

    # UAC and Remote Desktop
    $sys = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
    if ($sys -and $sys.EnableLUA -eq 0) { Add-Result 'User Account Control' 'FAIL' 'UAC is turned off.' 'Turn UAC back on; it blocks silent admin changes.' }
    else { Add-Result 'User Account Control' 'PASS' 'On.' }
    $ts = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue
    if ($ts -and $ts.fDenyTSConnections -eq 0) { Add-Result 'Remote Desktop' 'WARN' 'Incoming Remote Desktop connections are allowed.' 'Turn off in Settings > System > Remote Desktop unless you need it.' }
    else { Add-Result 'Remote Desktop' 'PASS' 'Incoming connections are off.' }

    # Remote-access and remote-management software
    $programs = Get-InstalledPrograms
    $programs | Export-Csv -Path (Join-Path $script:OutDir 'installed-programs.csv') -NoTypeInformation -Encoding UTF8
    Save-Artifact 'installed-programs.csv' 'Every installed program' $null
    $raPattern = 'AnyDesk|TeamViewer|RustDesk|UltraViewer|Chrome Remote Desktop|RealVNC|TightVNC|UltraVNC|VNC Server|Splashtop|ScreenConnect|ConnectWise|LogMeIn|GoTo Resolve|Ammyy|Supremo|AeroAdmin|DWService|DWAgent|Radmin|Zoho Assist|NinjaRMM|NinjaOne|\bAtera\b|Kaseya|N-able|Action1|MeshAgent|MeshCentral|Remote Utilities|HopToDesk|Parsec|Quick Assist Agent'
    $found = @()
    $found += @($programs | Where-Object { $_.DisplayName -match $raPattern } | ForEach-Object { 'program: ' + $_.DisplayName })
    $found += @(Get-CimInstance Win32_Service | Where-Object { $_.DisplayName -match $raPattern -or $_.Name -match $raPattern } | ForEach-Object { 'service: ' + $_.DisplayName + ' (' + $_.State + ')' })
    $found += @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $raPattern } | ForEach-Object { 'running: ' + $_.ProcessName })
    $found = @($found | Select-Object -Unique)
    if ($found.Count -gt 0) {
        Add-Result 'Remote-access software' 'WARN' ($found -join "`n") 'Remote-control tools let someone else see and control the laptop. Remove any you did not install yourself (the clean reinstall removes them all).'
    } else {
        Add-Result 'Remote-access software' 'PASS' 'None of the common remote-control or remote-management tools found.'
    }

    # Proxy and hosts file (traffic redirection)
    $inet = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    $proxyBits = @()
    if ($inet -and $inet.ProxyEnable -eq 1) { $proxyBits += ('proxy server ' + $inet.ProxyServer) }
    if ($inet -and $inet.PSObject.Properties['AutoConfigURL'] -and $inet.AutoConfigURL) { $proxyBits += ('auto-config script ' + $inet.AutoConfigURL) }
    if ($proxyBits.Count -gt 0) { Add-Result 'Web proxy' 'WARN' ($proxyBits -join ' | ') 'A proxy can route your browsing through someone else''s server. Turn it off in Settings > Network & internet > Proxy unless you set it.' }
    else { Add-Result 'Web proxy' 'PASS' 'No proxy configured.' }

    $hostsPath = Join-Path $env:windir 'System32\drivers\etc\hosts'
    if (Test-Path $hostsPath) {
        $entries = @(Get-Content $hostsPath -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -and $_.Trim() -notmatch '^#' -and $_ -notmatch '\slocalhost\s*$' })
        if ($entries.Count -gt 0) { Add-Result 'Hosts file' 'WARN' (($entries | Select-Object -First 10) -join "`n") 'Custom hosts entries can redirect websites. Review them.' }
        else { Add-Result 'Hosts file' 'PASS' 'No custom entries.' }
    }

    # Startup programs and non-Microsoft scheduled tasks (for review)
    $startup = @(Get-CimInstance Win32_StartupCommand | Select-Object Name, Command, Location, User)
    $startup | Export-Csv -Path (Join-Path $script:OutDir 'startup-programs.csv') -NoTypeInformation -Encoding UTF8
    Save-Artifact 'startup-programs.csv' 'Programs that start with Windows' $null
    Add-Result 'Startup programs' 'INFO' ('{0} item(s): {1}' -f $startup.Count, (($startup | Select-Object -First 15 | ForEach-Object { $_.Name }) -join ', ')) 'Anything unfamiliar is worth a web search.'
    try {
        $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } |
                   Select-Object TaskName, TaskPath, State, Author, @{ n = 'Action'; e = { ($_.Actions | ForEach-Object { ('' + $_.Execute + ' ' + $_.Arguments).Trim() }) -join '; ' } })
        $tasks | Export-Csv -Path (Join-Path $script:OutDir 'scheduled-tasks.csv') -NoTypeInformation -Encoding UTF8
        Save-Artifact 'scheduled-tasks.csv' 'Non-Microsoft scheduled tasks' $null
        Add-Result 'Non-Microsoft scheduled tasks' 'INFO' ('{0} task(s): {1}' -f $tasks.Count, (($tasks | Select-Object -First 15 | ForEach-Object { $_.TaskName }) -join ', '))
    } catch { }
}})

# 5 ------------------------------------------------------------------------
$Steps.Add(@{ Name = 'Battery health'; Body = {
    $batteries = @(Get-CimInstance Win32_Battery)
    if ($batteries.Count -eq 0) {
        if ($script:Facts['IsPortable']) {
            Add-Result 'Battery' 'FAIL' 'No battery detected on this laptop.' 'The battery is dead, disconnected or missing.'
        } else {
            Add-Result 'Battery' 'INFO' 'No battery (this PC reports itself as a desktop).'
        }
        return
    }
    $reportPath = Join-Path $script:OutDir 'battery-report.html'
    [void](Invoke-Native 'powercfg.exe' @('/batteryreport', '/output', $reportPath))
    Save-Artifact 'battery-report.html' 'Windows battery report (capacity history, usage, life estimates)' $null

    $design = 0; $full = 0; $cycles = $null
    try {
        $design = (@(Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop) | Measure-Object -Property DesignedCapacity -Sum).Sum
        $full   = (@(Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop) | Measure-Object -Property FullChargedCapacity -Sum).Sum
    } catch { }
    try {
        $cc = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount -ErrorAction Stop)
        if ($cc.Count -gt 0) { $cycles = ($cc | Measure-Object -Property CycleCount -Sum).Sum }
    } catch { }

    if ((-not $design -or -not $full) -and (Test-Path $reportPath)) {
        # Fallback: read the numbers from the battery report
        $text = (Get-Content $reportPath -Raw) -replace '<[^>]+>', ' '
        if ($text -match 'DESIGN CAPACITY\s+([\d][\d,\.\s]*?)\s*mWh')      { $design = [double](($Matches[1]) -replace '[^\d]', '') }
        if ($text -match 'FULL CHARGE CAPACITY\s+([\d][\d,\.\s]*?)\s*mWh') { $full   = [double](($Matches[1]) -replace '[^\d]', '') }
        if ($null -eq $cycles -and $text -match 'CYCLE COUNT\s+(\d+)')     { $cycles = [int]$Matches[1] }
    }

    if ($design -gt 0 -and $full -gt 0) {
        $health = [math]::Round(100.0 * $full / $design, 1)
        $detail = 'Health {0}%  |  full charge {1:N0} mWh of {2:N0} mWh design' -f $health, $full, $design
        if ($null -ne $cycles -and $cycles -gt 0) { $detail += ('  |  {0} charge cycles' -f $cycles) }
        $script:Facts['BatteryHealth'] = $health
        if ($health -ge 80)     { Add-Result 'Battery capacity' 'PASS' $detail }
        elseif ($health -ge 60) { Add-Result 'Battery capacity' 'WARN' $detail 'Worn but usable: noticeably shorter runtime. Fair grounds to negotiate the price.' }
        else                    { Add-Result 'Battery capacity' 'FAIL' $detail 'Heavily worn. Budget for a replacement battery or ask the seller to cover it.' }
    } else {
        Add-Result 'Battery capacity' 'WARN' 'Could not read capacity values.' 'Open battery-report.html in the report folder and compare DESIGN CAPACITY with FULL CHARGE CAPACITY.'
    }

    $b = $batteries[0]
    $statusNames = @{ 1 = 'Discharging'; 2 = 'On AC power'; 3 = 'Fully charged'; 4 = 'Low'; 5 = 'Critical'; 6 = 'Charging'; 7 = 'Charging (high)'; 8 = 'Charging (low)'; 9 = 'Charging (critical)'; 10 = 'Undefined'; 11 = 'Partially charged' }
    Add-Result 'Battery status' 'INFO' ('{0}% charged  |  {1}' -f $b.EstimatedChargeRemaining, $statusNames[[int]$b.BatteryStatus])
}})

# 6 ------------------------------------------------------------------------
$Steps.Add(@{ Name = 'Fan and cooling test'; Body = {
    Add-Result 'Cold-start fan check' 'INFO' 'A "Fan error" appears at power-on, before Windows loads, so this script cannot see it.' 'Shut down fully, wait 5 minutes, power on. Repeat 3 times and watch the screen each time.'
    if (-not $Quick) { Add-Result 'Fan under load' 'SKIP' 'Runs in quick mode (Run-QuickCheck.bat), where someone is there to listen.'; return }
    if ($NoPause)    { Add-Result 'Fan under load' 'SKIP' 'Needs a person to listen; skipped because -NoPause was used.'; return }

    $seconds = 90
    $cores = [Environment]::ProcessorCount
    $readTemps = {
        try {
            @(Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop |
              ForEach-Object { [math]::Round(($_.CurrentTemperature / 10.0) - 273.15, 0) })
        } catch { @() }
    }
    $before = & $readTemps
    $during = @()

    Write-Host ''
    Write-Host ('  FAN TEST: all {0} CPU threads will run at 100% for {1} seconds.' -f $cores, $seconds) -ForegroundColor Yellow
    Write-Host '  Hold your hand at the air vent and listen. The fan should get clearly louder' -ForegroundColor Yellow
    Write-Host '  and blow warm air within about a minute.' -ForegroundColor Yellow
    Write-Host '  (If this laptop has no fan at all, answer S at the end.)' -ForegroundColor Yellow
    # Each load process stops by itself after the test time, even if this window
    # is closed mid-test, so no stray 100% CPU processes are left behind.
    $loadScript  = '$e = [DateTime]::Now.AddSeconds({0}); while ([DateTime]::Now -lt $e) {{ }}' -f ($seconds + 10)
    $loadEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($loadScript))
    $procs = @()
    try {
        for ($i = 0; $i -lt $cores; $i++) {
            $procs += Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $loadEncoded) -WindowStyle Hidden -PassThru
        }
        for ($t = $seconds; $t -gt 0; $t -= 5) {
            Write-Host ('  {0,3} s left - listen for the fan...' -f $t) -ForegroundColor DarkYellow
            Start-Sleep -Seconds 5
        }
        $during = & $readTemps
    } finally {
        foreach ($proc in $procs) { try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { } }
    }

    $answer = ''
    while ($answer -notmatch '^[YyNnUuSs]$') {
        $answer = Read-Host '  Did the fan get louder and blow warm air out of the vent? Y = yes, N = no, U = not sure, S = this laptop has no fan'
    }
    $tempText = ''
    if ($before.Count -gt 0 -and $during.Count -gt 0) {
        $tempText = ('  |  sensor temps before: {0} C, at full load: {1} C' -f ($before -join '/'), ($during -join '/'))
    }
    switch -Regex ($answer) {
        '^[Yy]$' { Add-Result 'Fan under load' 'PASS' ('Fan spun up under 90 s of full load (tester confirmed).' + $tempText) }
        '^[Nn]$' { Add-Result 'Fan under load' 'FAIL' ('Fan did not respond to full load (tester observation).' + $tempText) 'Do not accept this laptop: the cooling fan is not working.' }
        '^[Ss]$' { Add-Result 'Fan under load' 'INFO' ('Tester says this laptop is fanless.' + $tempText) 'Fanless laptops slow down instead of spinning a fan when hot. Check the model really is fanless in its specs.' }
        default  { Add-Result 'Fan under load' 'WARN' ('Tester was not sure the fan spun up.' + $tempText) 'Repeat somewhere quieter, or install HWiNFO and check the fan speed (RPM) rises under load.' }
    }
}})

# 7 ------------------------------------------------------------------------
$Steps.Add(@{ Name = 'Storage health and file system'; Body = {
    $disks = @()
    try { $disks = @(Get-PhysicalDisk -ErrorAction Stop) } catch { }
    foreach ($d in $disks) {
        $name = '{0} ({1})' -f $d.FriendlyName, (Format-Bytes $d.Size)
        if ([string]$d.BusType -eq 'USB' -or [string]$d.BusType -eq '7') { Add-Result ('Drive ' + $name) 'INFO' 'External USB drive - skipped.'; continue }
        if ([string]$d.HealthStatus -eq 'Healthy' -or [string]$d.HealthStatus -eq '0') { Add-Result ('Drive health: ' + $name) 'PASS' ('Healthy | ' + ($d.OperationalStatus -join ', ')) }
        else { Add-Result ('Drive health: ' + $name) 'FAIL' ('{0} | {1}' -f $d.HealthStatus, ($d.OperationalStatus -join ', ')) 'The drive reports a problem. Back up and return the laptop.' }

        try {
            $rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop
            $bits = @()
            if ($null -ne $rc.Wear)         { $bits += ('wear {0}% used' -f $rc.Wear) }
            if ($null -ne $rc.PowerOnHours) { $bits += ('{0:N0} power-on hours' -f $rc.PowerOnHours) }
            if ($rc.Temperature)            { $bits += ('{0} C now, {1} C max' -f $rc.Temperature, $rc.TemperatureMax) }
            $errs = 0
            foreach ($p in @('ReadErrorsUncorrected', 'WriteErrorsUncorrected')) { if ($rc.$p) { $errs += [long]$rc.$p } }
            $bits += ('{0} uncorrected read/write errors' -f $errs)
            $detail = $bits -join '  |  '
            if ($errs -gt 0) {
                Add-Result ('Drive wear and errors: ' + $name) 'FAIL' $detail 'Uncorrected errors mean data is being lost. Return the laptop or replace the drive.'
            } elseif ($null -ne $rc.Wear -and $rc.Wear -ge 90) {
                Add-Result ('Drive wear and errors: ' + $name) 'FAIL' $detail 'The SSD is near the end of its rated life.'
            } elseif ($null -ne $rc.Wear -and $rc.Wear -ge 70) {
                Add-Result ('Drive wear and errors: ' + $name) 'WARN' $detail 'Heavily used SSD. Keep backups and consider replacing it.'
            } else {
                Add-Result ('Drive wear and errors: ' + $name) 'PASS' $detail 'For full SMART detail, also run CrystalDiskInfo (Available Spare, Media and Data Integrity Errors).'
            }
        } catch {
            Add-Result ('Drive wear and errors: ' + $name) 'SKIP' 'This drive does not report wear counters to Windows.' 'Run CrystalDiskInfo for the full SMART data.'
        }
    }

    try {
        $pred = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop | Where-Object { $_.PredictFailure })
        if ($pred.Count -gt 0) { Add-Result 'SMART failure prediction' 'FAIL' 'A drive predicts its own failure.' 'Back up now and return the laptop.' }
    } catch { }

    $vol = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive)
    if ($vol -and $vol.Size) {
        $freePct = [math]::Round(100.0 * $vol.FreeSpace / $vol.Size, 0)
        $detail = '{0} free of {1} ({2}%)' -f (Format-Bytes $vol.FreeSpace), (Format-Bytes $vol.Size), $freePct
        $freeLabel = 'Free space on ' + $env:SystemDrive
        if ($freePct -lt 15) { Add-Result $freeLabel 'WARN' $detail 'Under 15% free slows Windows and blocks updates.' }
        else { Add-Result $freeLabel 'PASS' $detail }
    }

    if ($Quick) { Add-Result 'File system (chkdsk)' 'SKIP' 'Skipped in quick mode.' 'Covered by the full run.'; return }
    Write-Host '  Scanning the C: file system (chkdsk /scan, a few minutes)...' -ForegroundColor DarkGray
    $ck = Invoke-Native 'chkdsk.exe' @($env:SystemDrive, '/scan')
    Save-Artifact 'chkdsk.txt' 'File system scan output (chkdsk /scan)' $ck.Output
    if ($ck.ExitCode -eq 0) { Add-Result 'File system (chkdsk)' 'PASS' 'No problems found.' }
    else { Add-Result 'File system (chkdsk)' 'WARN' ('chkdsk exit code ' + $ck.ExitCode) 'See chkdsk.txt. Running "chkdsk C: /f" and restarting usually repairs it; repeated errors point to a failing drive.' }
}})

# 8 ------------------------------------------------------------------------
$Steps.Add(@{ Name = 'Devices and drivers'; Body = {
    $problems = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 -and $_.ConfigManagerErrorCode -ne 45 })
    $disabled = @($problems | Where-Object { $_.ConfigManagerErrorCode -eq 22 })
    $broken   = @($problems | Where-Object { $_.ConfigManagerErrorCode -ne 22 })
    if ($broken.Count -gt 0) {
        $list = $broken | ForEach-Object {
            $n = $_.Name; if (-not $n) { $n = $_.DeviceID }
            '{0} (code {1})' -f $n, $_.ConfigManagerErrorCode
        }
        Add-Result 'Device Manager problems' 'WARN' ($list -join "`n") ('Code 28 = missing driver: install drivers with {0}. Other codes that remain after updating drivers can mean faulty hardware.' -f $script:VI.Tools)
    } else {
        Add-Result 'Device Manager problems' 'PASS' 'Every device has a working driver.'
    }
    if ($disabled.Count -gt 0) {
        Add-Result 'Disabled devices' 'INFO' (($disabled | ForEach-Object { $_.Name }) -join ', ') 'Someone switched these off. Re-enable in Device Manager if needed.'
    }

    # Is each key component present and working?
    $checks = @(
        @{ Label = 'Webcam';             Classes = @('Camera', 'Image'); Pattern = '.' },
        @{ Label = 'Wi-Fi adapter';      Classes = @('Net');             Pattern = 'Wi-?Fi|Wireless|802\.11|WLAN' },
        @{ Label = 'Bluetooth';          Classes = @('Bluetooth');       Pattern = 'Bluetooth|Wireless' },
        @{ Label = 'Audio';              Classes = @('AudioEndpoint');   Pattern = '.' },
        @{ Label = 'Fingerprint reader'; Classes = @('Biometric');       Pattern = '.' }
    )
    foreach ($c in $checks) {
        $devs = @()
        foreach ($cls in $c.Classes) {
            try { $devs += @(Get-PnpDevice -Class $cls -PresentOnly -ErrorAction Stop | Where-Object { $_.FriendlyName -match $c.Pattern }) } catch { }
        }
        $ok = @($devs | Where-Object { $_.Status -eq 'OK' })
        if ($ok.Count -gt 0) {
            Add-Result $c.Label 'PASS' ((($ok | Select-Object -ExpandProperty FriendlyName -Unique) | Select-Object -First 6) -join ', ') 'Detected by Windows. Still test that it actually works (see the README: What it cannot test).'
        } elseif ($devs.Count -gt 0) {
            Add-Result $c.Label 'WARN' ('Found but not working: ' + (($devs | ForEach-Object { $_.FriendlyName + ' (' + $_.Status + ')' }) -join ', ')) 'Update drivers; if it stays broken, the part may be faulty.'
        } elseif ($c.Label -eq 'Fingerprint reader') {
            Add-Result $c.Label 'INFO' 'Not detected (many models have none).'
        } else {
            Add-Result $c.Label 'WARN' 'Not detected.' 'Check it is not switched off (F-key, BIOS) and that drivers are installed. A missing device can mean a hardware fault.'
        }
    }

    $dq = (Invoke-Native 'driverquery.exe' @('/v', '/fo', 'csv')).Output
    Save-Artifact 'drivers.csv' 'Every installed driver (driverquery)' $dq

    try {
        $tz = @(Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop)
        if ($tz.Count -gt 0) {
            $temps = $tz | ForEach-Object { '{0:N0} C' -f (($_.CurrentTemperature / 10.0) - 273.15) }
            Add-Result 'Temperature sensors (idle)' 'INFO' ($temps -join ', ') 'Firmware thermal zones; not always the CPU core. Use HWiNFO during the stress test for real CPU temperatures.'
        }
    } catch { }
}})

# 9 ------------------------------------------------------------------------
$Steps.Add(@{ Name = 'Crash and hardware-error history'; Body = {
    $since = (Get-Date).AddDays(-60)
    $oldest = $null
    try { $oldest = (Get-WinEvent -LogName System -MaxEvents 1 -Oldest -ErrorAction Stop).TimeCreated } catch { }
    if ($oldest -and $oldest -gt $since) { $since = $oldest }
    Add-Result 'Log window' 'INFO' ('Event logs checked from {0} to now.' -f $since.ToString('yyyy-MM-dd')) 'A recent reset empties the logs; re-run this script after a week of normal use.'

    $whea = Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since }
    $wheaFatal = @($whea | Where-Object { $_.Level -le 2 })
    if ($wheaFatal.Count -gt 0) {
        Add-Result 'Hardware errors (WHEA)' 'FAIL' ('{0} fatal/uncorrected hardware error(s), latest {1}' -f $wheaFatal.Count, $wheaFatal[0].TimeCreated) 'Windows caught CPU, memory or PCIe hardware errors. Run MemTest86 and the stress test; repeated errors are grounds to return it.'
    } elseif ($whea.Count -gt 0) {
        Add-Result 'Hardware errors (WHEA)' 'WARN' ('{0} corrected hardware error(s), latest {1}' -f $whea.Count, $whea[0].TimeCreated) 'Corrected errors are sometimes harmless (often PCIe power saving), but watch whether the count keeps growing.'
    } else {
        Add-Result 'Hardware errors (WHEA)' 'PASS' 'None.'
    }

    $bsod = Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since }
    $dumps = @(Get-ChildItem (Join-Path $env:windir 'Minidump') -Filter *.dmp -ErrorAction SilentlyContinue)
    if ($bsod.Count -gt 0 -or $dumps.Count -gt 0) {
        $dates = ($bsod | Select-Object -First 5 | ForEach-Object { $_.TimeCreated.ToString('yyyy-MM-dd HH:mm') }) -join ', '
        Add-Result 'Blue-screen crashes' 'FAIL' ('{0} crash event(s), {1} crash dump file(s). Latest: {2}' -f $bsod.Count, $dumps.Count, $dates) 'Repeated blue screens point to bad drivers, RAM or storage. Note the stop code if it happens again.'
    } else {
        Add-Result 'Blue-screen crashes' 'PASS' 'None.'
    }

    $kp = Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since }
    if ($kp.Count -gt 2) { Add-Result 'Unexpected shutdowns' 'WARN' ('{0} times the PC lost power or restarted without shutting down' -f $kp.Count) 'Can be forced power-offs, but many suggest a failing battery, overheating or instability.' }
    else { Add-Result 'Unexpected shutdowns' 'PASS' ('{0} in the log window.' -f $kp.Count) }

    # Query by level, then filter providers here: a provider that does not exist on
    # this PC would make Get-WinEvent fail the whole query.
    $storageProviders = @('disk', 'Ntfs', 'stornvme', 'storahci', 'iaStorAC', 'iaStorVD')
    $diskEv = @(Get-EventsSafe @{ LogName = 'System'; Level = @(1, 2, 3); StartTime = $since } | Where-Object { $storageProviders -contains $_.ProviderName })
    if ($diskEv.Count -gt 0) {
        $groups = $diskEv | Group-Object { $_.ProviderName + ' event ' + $_.Id } | Sort-Object Count -Descending | Select-Object -First 6 | ForEach-Object { '{0} x{1}' -f $_.Name, $_.Count }
        Add-Result 'Storage errors in log' 'WARN' ($groups -join ', ') 'Disk event 7/51/153 or stornvme 11 suggest a failing drive or connection. Cross-check with CrystalDiskInfo.'
    } else {
        Add-Result 'Storage errors in log' 'PASS' 'None.'
    }

    $appCrash = Get-EventsSafe @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $since }
    if ($appCrash.Count -gt 0) {
        $top = $appCrash | Group-Object { if ($_.Properties.Count -gt 0) { $_.Properties[0].Value } else { 'unknown' } } | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { '{0} x{1}' -f $_.Name, $_.Count }
        Add-Result 'App crashes' 'INFO' ('{0} app crash(es). Most frequent: {1}' -f $appCrash.Count, ($top -join ', '))
    } else {
        Add-Result 'App crashes' 'PASS' 'None.'
    }

    try {
        $rel = Get-CimInstance Win32_ReliabilityStabilityMetrics -ErrorAction Stop | Sort-Object TimeGenerated -Descending | Select-Object -First 1
        if ($rel) {
            $idx = [math]::Round([double]$rel.SystemStabilityIndex, 1)
            if ($idx -lt 5) { Add-Result 'Reliability index' 'WARN' ('{0} / 10' -f $idx) 'Open Reliability Monitor (perfmon /rel) to see which crashes pulled it down.' }
            else { Add-Result 'Reliability index' 'PASS' ('{0} / 10' -f $idx) }
        }
    } catch { }
}})

# 10 -----------------------------------------------------------------------
$Steps.Add(@{ Name = 'Windows Update and manufacturer tools'; Body = {
    if ($Quick) { Add-Result 'Missing updates' 'SKIP' 'Skipped in quick mode.' 'Covered by the full run.' } else { try {
        Write-Host '  Asking Windows Update for missing updates (can take several minutes)...' -ForegroundColor DarkGray
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $res = $searcher.Search('IsInstalled=0 and IsHidden=0')
        $sw = @(); $drv = @()
        for ($i = 0; $i -lt $res.Updates.Count; $i++) {
            $u = $res.Updates.Item($i)
            if ($u.Type -eq 2) { $drv += $u.Title } else { $sw += $u.Title }
        }
        if (($sw.Count + $drv.Count) -eq 0) {
            Add-Result 'Missing updates' 'PASS' 'Windows reports it is up to date.'
        } else {
            $lines = @()
            if ($sw.Count -gt 0)  { $lines += ('Windows/software ({0}): {1}' -f $sw.Count, (($sw | Select-Object -First 10) -join '; ')) }
            if ($drv.Count -gt 0) { $lines += ('Drivers ({0}): {1}' -f $drv.Count, (($drv | Select-Object -First 10) -join '; ')) }
            Add-Result 'Missing updates' 'WARN' ($lines -join "`n") 'Install them in Settings > Windows Update (driver updates are under Advanced options > Optional updates).'
        }
        $count = $searcher.GetTotalHistoryCount()
        if ($count -gt 0) {
            $last = $searcher.QueryHistory(0, 1)
            if ($last.Count -gt 0) { Add-Result 'Last update installed' 'INFO' ($last.Item(0).Date.ToString('yyyy-MM-dd') + ' - ' + $last.Item(0).Title) }
        }
    } catch {
        Add-Result 'Missing updates' 'WARN' ('Windows Update could not be queried: ' + $_.Exception.Message) 'Check the internet connection and open Settings > Windows Update by hand.'
    } }

    $pending = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
                 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') | Where-Object { Test-Path $_ }
    if (@($pending).Count -gt 0) { Add-Result 'Restart pending' 'INFO' 'Windows is waiting for a restart to finish updates.' }

    $pattern = $script:VI.ToolPattern
    if (-not $pattern) {
        Add-Result 'Manufacturer update tool' 'INFO' ('Get drivers and firmware updates from: ' + $script:VI.Tools)
    } else {
        $storeApps = @()
        try { $storeApps = @(Get-AppxPackage -AllUsers -ErrorAction Stop | Where-Object { $_.Name -match $pattern } | ForEach-Object { $_.Name }) } catch { }
        $desktopApps = @(Get-InstalledPrograms | Where-Object { $_.DisplayName -match $pattern } | ForEach-Object { $_.DisplayName })
        $all = @($storeApps + $desktopApps | Select-Object -Unique)
        if ($all.Count -gt 0) { Add-Result 'Manufacturer update tool' 'PASS' ($all -join ', ') 'Use it to install the maker''s driver, firmware and BIOS updates.' }
        else { Add-Result 'Manufacturer update tool' 'INFO' 'Not installed.' ('Install ' + $script:VI.Tools + ' to get BIOS, firmware and driver updates that Windows Update may not offer.') }
    }
}})

# 11 -----------------------------------------------------------------------
$Steps.Add(@{ Name = 'Network'; Body = {
    $up = @()
    try { $up = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }) } catch { }
    if ($up.Count -gt 0) { Add-Result 'Connected adapters' 'INFO' (($up | ForEach-Object { '{0} ({1})' -f $_.Name, $_.LinkSpeed }) -join ', ') }

    $wl = (Invoke-Native 'netsh.exe' @('wlan', 'show', 'interfaces')).Output
    $fields = [ordered]@{}
    foreach ($line in ($wl -split "`r?`n")) {
        if ($line -match '^\s*(SSID|Radio type|Band|Channel|Receive rate \(Mbps\)|Signal)\s*:\s*(.+?)\s*$') { $fields[$Matches[1]] = $Matches[2] }
    }
    if ($fields.Count -gt 0) {
        Add-Result 'Wi-Fi connection' 'INFO' (($fields.Keys | ForEach-Object { '{0}: {1}' -f $_, $fields[$_] }) -join '  |  ') 'Signal should be high near the router; test again two rooms away.'
    }

    if ($SkipNetworkTest) { Add-Result 'Internet test' 'SKIP' 'Skipped by option.'; return }
    try {
        $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 20
        if ($r.Content -match 'Microsoft Connect Test') { Add-Result 'Internet access' 'PASS' 'Connected.' }
        else { Add-Result 'Internet access' 'WARN' 'Unexpected reply - a login page or filter may be in the way.' }
    } catch {
        Add-Result 'Internet access' 'WARN' 'No internet connection.' 'Not a hardware fault by itself. Connect to Wi-Fi and confirm it works; the full run needs internet for updates and Defender.'
        return
    }
    if ($Quick) { return }
    try {
        $tmp = Join-Path $env:TEMP 'lhc-speedtest.bin'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Invoke-WebRequest -Uri 'https://speed.cloudflare.com/__down?bytes=25000000' -OutFile $tmp -UseBasicParsing -TimeoutSec 180
        $sw.Stop()
        $bytes = (Get-Item $tmp).Length
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        $mbps = [math]::Round(($bytes * 8 / 1e6) / $sw.Elapsed.TotalSeconds, 1)
        Add-Result 'Download speed' 'INFO' ('{0} Mbps ({1} downloaded in {2:N1} s)' -f $mbps, (Format-Bytes $bytes), $sw.Elapsed.TotalSeconds) 'Compare with a speed test on your phone on the same Wi-Fi. Much slower points to a weak Wi-Fi card or antenna.'
    } catch {
        Add-Result 'Download speed' 'SKIP' ('Speed test failed: ' + $_.Exception.Message)
    }
}})

# 12 -----------------------------------------------------------------------
$Steps.Add(@{ Name = 'System file integrity (DISM and SFC)'; Body = {
    if ($SkipSystemFileCheck -or $Quick) { Add-Result 'System files' 'SKIP' 'Skipped (quick mode or option).' 'Covered by the full run.'; return }

    Write-Host '  DISM component store scan (5-20 minutes)...' -ForegroundColor DarkGray
    $dism = Invoke-Native 'dism.exe' @('/Online', '/Cleanup-Image', '/ScanHealth')
    Save-Artifact 'dism-scanhealth.txt' 'Windows component store scan (DISM /ScanHealth)' $dism.Output
    if ($dism.Output -match 'No component store corruption detected') {
        Add-Result 'Windows component store (DISM)' 'PASS' 'No corruption detected.'
    } elseif ($dism.Output -match 'repairable') {
        Add-Result 'Windows component store (DISM)' 'WARN' 'Corruption found (repairable).' 'Run "DISM /Online /Cleanup-Image /RestoreHealth" then "sfc /scannow", or do the clean reinstall.'
    } elseif ($dism.ExitCode -eq 0) {
        Add-Result 'Windows component store (DISM)' 'PASS' 'Completed with exit code 0.' 'See dism-scanhealth.txt.'
    } else {
        Add-Result 'Windows component store (DISM)' 'WARN' ('DISM exit code ' + $dism.ExitCode) 'See dism-scanhealth.txt.'
    }

    Write-Host '  System File Checker, verify only (5-15 minutes)...' -ForegroundColor DarkGray
    $prevEnc = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [Text.Encoding]::Unicode   # sfc writes UTF-16
        $sfc = Invoke-Native 'sfc.exe' @('/verifyonly')
    } finally {
        [Console]::OutputEncoding = $prevEnc
    }
    $sfcText = ($sfc.Output -replace "`0", '')
    Save-Artifact 'sfc-verify.txt' 'System File Checker output (sfc /verifyonly)' $sfcText
    if ($sfcText -match 'did not find any integrity violations') {
        Add-Result 'System files (SFC)' 'PASS' 'No integrity violations.'
    } elseif ($sfcText -match 'found integrity violations|found corrupt files') {
        Add-Result 'System files (SFC)' 'WARN' 'Damaged system files found.' 'Run "sfc /scannow" as administrator to repair them, or do the clean reinstall.'
    } else {
        Add-Result 'System files (SFC)' 'INFO' ('Finished (exit code {0}); result not recognised.' -f $sfc.ExitCode) 'See sfc-verify.txt.'
    }
}})

# 13 -----------------------------------------------------------------------
$Steps.Add(@{ Name = 'Malware scan (Microsoft Defender)'; Body = {
    if ($SkipDefenderScan -or $Quick) { Add-Result 'Defender scan' 'SKIP' 'Skipped (quick mode or option).' 'Covered by the full run.'; return }
    $mode = $script:Facts['DefenderMode']
    if ($mode -and $mode -ne 'Normal') {
        Add-Result 'Defender scan' 'SKIP' ('Defender is in "{0}" mode, usually because another antivirus is installed.' -f $mode) 'Run a full scan with the installed antivirus instead.'
        return
    }
    try {
        Write-Host '  Updating virus definitions...' -ForegroundColor DarkGray
        try { Update-MpSignature -ErrorAction Stop } catch { Write-Host ('  Definition update failed: ' + $_.Exception.Message) -ForegroundColor DarkYellow }

        $scanType = 'FullScan'
        if ($QuickScan) { $scanType = 'QuickScan' }
        Write-Host ('  Running Defender {0} - a full scan usually takes 1-3 hours. Leave it running.' -f $scanType) -ForegroundColor DarkGray
        $scanStart = Get-Date
        Start-MpScan -ScanType $scanType -ErrorAction Stop
        $mins = [math]::Round(((Get-Date) - $scanStart).TotalMinutes, 0)

        $newThreats = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -ge $scanStart.AddMinutes(-1) })
        if ($newThreats.Count -gt 0) {
            $names = @()
            foreach ($t in $newThreats) {
                $info = Get-MpThreat -ThreatID $t.ThreatID -ErrorAction SilentlyContinue
                if ($info) { $names += $info.ThreatName } else { $names += ('Threat ID ' + $t.ThreatID) }
            }
            Add-Result ('Defender ' + $scanType) 'FAIL' ('{0} threat(s) found in {1} min: {2}' -f $newThreats.Count, $mins, (($names | Select-Object -Unique) -join ', ')) 'Open Windows Security > Protection history and remove them. A clean reinstall is the safest fix on a used laptop.'
        } else {
            Add-Result ('Defender ' + $scanType) 'PASS' ('No threats found ({0} min).' -f $mins)
        }
        $history = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -lt $scanStart.AddMinutes(-1) })
        if ($history.Count -gt 0) {
            Add-Result 'Earlier detections' 'INFO' ('{0} older detection(s) in Defender history.' -f $history.Count) 'Malware was caught on this laptop before. Another reason for a clean reinstall.'
        }
    } catch {
        Add-Result 'Defender scan' 'ERROR' ('Scan could not run: ' + $_.Exception.Message) 'Run a full scan by hand in Windows Security > Virus & threat protection > Scan options.'
    }
}})

# ---------------------------------------------------------------------------
# Run all steps
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('Laptop Health Check v{0}' -f $ScriptVersion) -ForegroundColor Cyan
Write-Host ('Report folder: {0}' -f $script:OutDir) -ForegroundColor Cyan
if ($Quick) {
    Write-Host 'QUICK MODE: about 5 minutes. Stay with the laptop - the fan test will ask you a question.' -ForegroundColor Cyan
} else {
    Write-Host 'Keep the charger plugged in and the lid open. Total time: about 1-3 hours with the full Defender scan.' -ForegroundColor Cyan
}

$bat = @(Get-CimInstance Win32_Battery)
if ($bat.Count -gt 0 -and [int]$bat[0].BatteryStatus -eq 1) {
    Write-Host 'The laptop is on battery. Plug in the charger - waiting up to 2 minutes...' -ForegroundColor Yellow
    for ($i = 0; $i -lt 24; $i++) {
        Start-Sleep -Seconds 5
        $bat = @(Get-CimInstance Win32_Battery)
        if ([int]$bat[0].BatteryStatus -ne 1) { Write-Host 'Charger detected.' -ForegroundColor Green; break }
    }
}

$stepNo = 0
foreach ($step in $Steps) {
    $stepNo++
    $script:CurrentSection = $step.Name
    Write-Host ''
    Write-Host ('[{0}/{1}] {2}   ({3})' -f $stepNo, $Steps.Count, $step.Name, (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Cyan
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $body = $step.Body
    try {
        & $body
    } catch {
        Add-Result 'Step error' 'ERROR' $_.Exception.Message 'This check could not finish. The rest of the report is still valid.'
    }
    $timer.Stop()
    $script:Timings[$step.Name] = $timer.Elapsed
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$endTime  = Get-Date
$duration = $endTime - $script:StartTime
$counts = @{}
foreach ($s in @('PASS', 'WARN', 'FAIL', 'INFO', 'SKIP', 'ERROR')) { $counts[$s] = @($script:Results | Where-Object { $_.Status -eq $s }).Count }

if ($counts['FAIL'] -gt 0) {
    $verdict = 'Problems found. Review every red FAIL row before the return window closes.'; $verdictClass = 'FAIL'
} elseif ($counts['WARN'] -gt 0 -or $counts['ERROR'] -gt 0) {
    $verdict = 'No hard failures. Review the yellow WARN rows.'; $verdictClass = 'WARN'
} else {
    $verdict = 'All automated checks passed.'; $verdictClass = 'PASS'
}

function ConvertTo-HtmlText {
    param([string]$Text)
    if (-not $Text) { return '' }
    return ([System.Net.WebUtility]::HtmlEncode($Text) -replace "`r?`n", '<br>')
}

$css = @'
body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1f2328; background: #fafafa; }
h1 { margin-bottom: 4px; } h2 { margin-top: 32px; border-bottom: 2px solid #ddd; padding-bottom: 4px; }
.meta { color: #555; margin: 2px 0; }
.verdict { padding: 14px 18px; border-radius: 8px; font-size: 1.15em; font-weight: 600; margin: 18px 0; }
.verdict.PASS { background: #e5f4e4; } .verdict.WARN { background: #f9eeda; } .verdict.FAIL { background: #fbebeb; }
.counts span { display: inline-block; margin-right: 10px; padding: 4px 10px; border-radius: 12px; font-weight: 600; }
table { border-collapse: collapse; width: 100%; background: #fff; }
th, td { text-align: left; vertical-align: top; padding: 8px 10px; border-bottom: 1px solid #e6e6e6; }
th { background: #f0efec; }
td.status { width: 64px; }
.badge { display: inline-block; min-width: 48px; text-align: center; padding: 2px 6px; border-radius: 6px; font-weight: 700; font-size: 0.85em; }
.PASS .badge, span.PASS { background: #e5f4e4; color: #1a7f37; }
.WARN .badge, span.WARN { background: #f9eeda; color: #9a6700; }
.FAIL .badge, span.FAIL { background: #fbebeb; color: #cf222e; }
.ERROR .badge, span.ERROR { background: #efedff; color: #6639ba; }
.INFO .badge, span.INFO, .SKIP .badge, span.SKIP { background: #eef0f2; color: #57606a; }
.advice { color: #57606a; font-size: 0.92em; }
.note { background: #e7f1fb; padding: 12px 16px; border-radius: 8px; }
'@

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"><title>Laptop Health Check report</title>')
[void]$sb.AppendLine('<style>' + $css + '</style></head><body>')
[void]$sb.AppendLine('<h1>Laptop Health Check report</h1>')
[void]$sb.AppendLine(('<p class="meta"><b>{0}</b> &middot; serial {1}</p>' -f (ConvertTo-HtmlText $script:Facts['Model']), (ConvertTo-HtmlText $script:Facts['Serial'])))
[void]$sb.AppendLine(('<p class="meta">{0}</p>' -f (ConvertTo-HtmlText $script:Facts['OS'])))
$modeText = 'Full check'
if ($Quick) { $modeText = 'Quick check (long scans skipped)' }
[void]$sb.AppendLine(('<p class="meta">{4} &middot; run {0} to {1} ({2:N0} min) &middot; script v{3}</p>' -f $script:StartTime.ToString('yyyy-MM-dd HH:mm'), $endTime.ToString('HH:mm'), $duration.TotalMinutes, $ScriptVersion, $modeText))
[void]$sb.AppendLine(('<div class="verdict {0}">{1}</div>' -f $verdictClass, (ConvertTo-HtmlText $verdict)))
[void]$sb.Append('<p class="counts">')
foreach ($s in @('FAIL', 'WARN', 'PASS', 'INFO', 'SKIP', 'ERROR')) {
    if ($counts[$s] -gt 0) { [void]$sb.Append(('<span class="{0}">{1} {0}</span>' -f $s, $counts[$s])) }
}
[void]$sb.AppendLine('</p>')

$problemRows = @($script:Results | Where-Object { $_.Status -in @('FAIL', 'WARN', 'ERROR') })
if ($problemRows.Count -gt 0) {
    [void]$sb.AppendLine('<h2>Needs attention</h2><table><tr><th>Status</th><th>Check</th><th>Finding</th><th>What to do</th></tr>')
    foreach ($r in ($problemRows | Sort-Object @{ e = { @{ FAIL = 0; ERROR = 1; WARN = 2 }[$_.Status] } })) {
        [void]$sb.AppendLine(('<tr class="{0}"><td class="status"><span class="badge">{0}</span></td><td>{1}</td><td>{2}</td><td class="advice">{3}</td></tr>' -f $r.Status, (ConvertTo-HtmlText ($r.Section + ': ' + $r.Check)), (ConvertTo-HtmlText $r.Detail), (ConvertTo-HtmlText $r.Advice)))
    }
    [void]$sb.AppendLine('</table>')
}

foreach ($step in $Steps) {
    $rows = @($script:Results | Where-Object { $_.Section -eq $step.Name })
    if ($rows.Count -eq 0) { continue }
    $t = $script:Timings[$step.Name]
    $tText = ''
    if ($t) { $tText = (' <span class="meta" style="font-size:0.6em">({0:N1} min)</span>' -f $t.TotalMinutes) }
    [void]$sb.AppendLine(('<h2>{0}{1}</h2><table><tr><th>Status</th><th>Check</th><th>Result</th><th>Notes</th></tr>' -f (ConvertTo-HtmlText $step.Name), $tText))
    foreach ($r in $rows) {
        [void]$sb.AppendLine(('<tr class="{0}"><td class="status"><span class="badge">{0}</span></td><td>{1}</td><td>{2}</td><td class="advice">{3}</td></tr>' -f $r.Status, (ConvertTo-HtmlText $r.Check), (ConvertTo-HtmlText $r.Detail), (ConvertTo-HtmlText $r.Advice)))
    }
    [void]$sb.AppendLine('</table>')
}

if ($script:Artifacts.Count -gt 0) {
    [void]$sb.AppendLine('<h2>Evidence files in this folder</h2><table><tr><th>File</th><th>What it is</th></tr>')
    foreach ($a in $script:Artifacts) {
        [void]$sb.AppendLine(('<tr><td><a href="{0}">{0}</a></td><td>{1}</td></tr>' -f (ConvertTo-HtmlText $a.File), (ConvertTo-HtmlText $a.Description)))
    }
    [void]$sb.AppendLine('</table>')
}

[void]$sb.AppendLine('<h2>Not covered by this script</h2><p class="note"><b>Cold-start test:</b> shut down fully, wait 5 minutes, power on, and watch for "Fan error" or any other message before Windows loads. Repeat 3 times. This script cannot see that screen.<br><br>These also need a person or a reboot: screen (dead pixels, hinge flicker), keyboard and touchpad, speakers, microphone and webcam image, every port, Bluetooth pairing, the CPU/GPU stress test with temperatures, MemTest86, the battery rundown, and checking the BIOS screens by eye. The README section &quot;What it cannot test&quot; lists free tools for each.</p>')
[void]$sb.AppendLine('</body></html>')

$reportFile = Join-Path $script:OutDir 'report.html'
Set-Content -Path $reportFile -Value $sb.ToString() -Encoding UTF8
$script:Results | ConvertTo-Json -Depth 3 | Set-Content -Path (Join-Path $script:OutDir 'results.json') -Encoding UTF8

if ($keepAwake) { try { [void][LaptopHealthCheck.Power]::SetThreadExecutionState([uint32]2147483648) } catch { } }

Write-Host ''
Write-Host '==================================================================' -ForegroundColor Cyan
Write-Host (' Finished in {0:N0} minutes.' -f $duration.TotalMinutes) -ForegroundColor Cyan
$vColor = 'Green'
if ($verdictClass -eq 'WARN') { $vColor = 'Yellow' } elseif ($verdictClass -eq 'FAIL') { $vColor = 'Red' }
Write-Host (' ' + $verdict) -ForegroundColor $vColor
Write-Host (' FAIL {0} | WARN {1} | PASS {2} | INFO {3} | SKIP {4} | ERROR {5}' -f $counts['FAIL'], $counts['WARN'], $counts['PASS'], $counts['INFO'], $counts['SKIP'], $counts['ERROR'])
Write-Host (' Report: {0}' -f $reportFile) -ForegroundColor Cyan
Write-Host '==================================================================' -ForegroundColor Cyan

try { Stop-Transcript | Out-Null } catch { }
try { Start-Process $reportFile } catch { }
if (-not $NoPause) { [void](Read-Host 'Press Enter to close this window') }
