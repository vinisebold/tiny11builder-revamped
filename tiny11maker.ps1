<#
.SYNOPSIS
    Scripts to build a trimmed-down Windows 11 image.

.DESCRIPTION
    This is a script created to automate the build of a streamlined Windows 11 image, similar to tiny10.
    My main goal is to use only Microsoft utilities like DISM, and no utilities from external sources.
    The only executable included is oscdimg.exe, which is provided in the Windows ADK and it is used to create bootable ISO images.
	Tip: Start a PowerShell (with Admin rights) and use "Set-ExecutionPolicy Bypass -Scope Process" to change the policy.

.PARAMETER ISO
    Drive letter given to the mounted iso (eg: E)

.PARAMETER SCRATCH
    Drive letter of the desired scratch disk (eg: D)
	NOTE: The SCRATCH drive must support file/folder security (i.e., must be, e.g., NTFS filesystem).

.PARAMETER Custom
    Optional switch to manually choose which provisioned packages should be removed.

.EXAMPLE
    .\tiny11maker.ps1 E D
    .\tiny11maker.ps1 -ISO E -SCRATCH D
    .\tiny11maker.ps1 -SCRATCH D -ISO E
    .\tiny11maker.ps1 -SCRATCH D -ISO E -Custom
    .\tiny11maker.ps1

    *If you ordinal parameters the first one must be the mounted iso. The second is the scratch drive.
    prefer the use of full named parameter (eg: "-ISO") as you can put in the order you want.

.NOTES
    Author: ntdevlabs
    Date: 09-07-25
#>

#---------[ Parameters ]---------#
param (
    [ValidatePattern('^[c-zC-Z]$')][string]$ISO,
    [ValidatePattern('^[c-zC-Z]$')][string]$SCRATCH,
	[switch]$Custom
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'Continue'
$InformationPreference = 'Continue'

if (-not $SCRATCH) {
    $ScratchDisk = $PSScriptRoot -replace '[\\]+$', ''
} else {
    $ScratchDisk = $SCRATCH + ":"
}

$utilsModulePath = Join-Path $PSScriptRoot 'lib\tiny11utils.psm1'
if (-not (Test-Path -Path $utilsModulePath -PathType Leaf)) {
    Write-Error "Required module not found: $utilsModulePath"
    exit 1
}

Import-Module -Name $utilsModulePath -Force

$script:installImageMounted = $false
$script:bootImageMounted = $false
$script:offlineRegistryLoaded = $false
$script:transcriptStarted = $false

trap {
    Write-Error "A fatal error interrupted execution: $($_.Exception.Message)"

    if ($script:offlineRegistryLoaded) {
        Write-Warning "Attempting emergency registry unload..."
        Invoke-SafeOfflineRegistryUnload | Out-Null
        $script:offlineRegistryLoaded = $false
    }

    if ($script:bootImageMounted -or $script:installImageMounted) {
        Write-Warning "Attempting emergency image dismount..."
        Invoke-SafeDismountImage -Path "$ScratchDisk\scratchdir" | Out-Null
        $script:bootImageMounted = $false
        $script:installImageMounted = $false
    }

    if ($script:transcriptStarted) {
        try {
            Stop-Transcript | Out-Null
        } catch {
            Write-Warning "Transcript could not be stopped during emergency cleanup."
        }
        $script:transcriptStarted = $false
    }

    exit 1
}

#---------[ Functions ]---------#
# --- Interactive console selector for package prefixes ---
function Show-PackageSelector {
    param(
        [string[]]$Items,
        [switch]$DefaultAll
    )

    # Initialize selection state
    $selected = @{}
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $selected[$i] = $false
    }
    if ($DefaultAll) {
        for ($i = 0; $i -lt $Items.Count; $i++) { $selected[$i] = $true }
    }

    while ($true) {
        Clear-Host
        Write-Host "Select packages to REMOVE from the image:" -ForegroundColor Cyan
        Write-Host "Toggle items by entering numbers separated by commas. Commands: all, none" -ForegroundColor DarkGray
        Write-Host "Tip: use ranges like 1-5 or combinations like 1,3,7-9" -ForegroundColor DarkGray
        Write-Host "use: q / quit / exit to abort - use: 'done' if the selection is ready to proceed" -ForegroundColor DarkGreen
        Write-Host ""

        for ($i = 0; $i -lt $Items.Count; $i++) {
            $mark = if ($selected[$i]) { '[X]' } else { '[ ]' }
            $num = ($i + 1).ToString().PadLeft(3)
            Write-Host "$num $mark  $($Items[$i])"
        }

        Write-Host ""
        $input = Read-Host "Enter selection"
        if (-not $input) { continue }

        $input = $input.Trim()
        $lower = $input.ToLowerInvariant()
        if ($lower -in @('q','quit','exit')) {
            Write-Host "Exiting selection and keeping current choices." -ForegroundColor Yellow
            break
        }
        if ($lower -eq 'done') { break }
        if ($lower -eq 'all') {
            for ($i = 0; $i -lt $Items.Count; $i++) { $selected[$i] = $true }
            continue
        }
        if ($lower -eq 'none') {
            for ($i = 0; $i -lt $Items.Count; $i++) { $selected[$i] = $false }
            continue
        }

        # Parse numeric toggles like "1,3-5,8"
        $tokens = $input -split '[, ]+' | Where-Object { $_ -ne '' }
        foreach ($t in $tokens) {
            if ($t -match '^\d+$') {
                $idx = [int]$t - 1
                if ($idx -ge 0 -and $idx -lt $Items.Count) {
                    $selected[$idx] = -not $selected[$idx]
                } else {
                    Write-Host "Number out of range: $t" -ForegroundColor DarkYellow
                    Start-Sleep -Seconds 1
                }
            } elseif ($t -match '^(\d+)-(\d+)$') {
                $start = [int]$Matches[1] - 1
                $end = [int]$Matches[2] - 1
                if ($start -lt 0) { $start = 0 }
                if ($end -ge $Items.Count) { $end = $Items.Count - 1 }
                if ($start -le $end) {
                    for ($j = $start; $j -le $end; $j++) {
                        $selected[$j] = -not $selected[$j]
                    }
                } else {
                    Write-Host "Invalid range: $t" -ForegroundColor DarkYellow
                    Start-Sleep -Seconds 1
                }
            } else {
                Write-Host "Ignored token: $t" -ForegroundColor DarkYellow
                Start-Sleep -Seconds 1
            }
        }
    }

    # Build and return selected items
    $result = for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($selected[$i]) { $Items[$i] }
    }
    return ,$result
}
# --- End selector function ---

#---------[ Execution ]---------#
# Check if PowerShell execution is Restricted or AllSigned or Undefined
$needchange = @("AllSigned", "Restricted", "Undefined")
$curpolicy = Get-ExecutionPolicy
if ($curpolicy -in $needchange) {
    Write-Host "Your current PowerShell Execution Policy is set to $curpolicy, which prevents scripts from running. Do you want to change it to RemoteSigned? (yes/no)"
    $response = Read-Host
    if ($response -eq 'yes') {
        Set-ExecutionPolicy RemoteSigned -Scope Process -Confirm:$false
    } else {
        Write-Output "The script cannot be run without changing the execution policy. Exiting..."
        exit
    }
}

# Check and run the script as admin if required
$adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
$adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])
$myWindowsID=[System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal=new-object System.Security.Principal.WindowsPrincipal($myWindowsID)
$adminRole=[System.Security.Principal.WindowsBuiltInRole]::Administrator
if (! $myWindowsPrincipal.IsInRole($adminRole))
{
    Write-Output "Restarting Tiny11 image creator as admin in a new window, you can close this one."
    $newProcess = new-object System.Diagnostics.ProcessStartInfo "PowerShell";
    $newProcess.Arguments = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$($myInvocation.MyCommand.Definition)`"";
    $newProcess.Verb = "runas";
    [System.Diagnostics.Process]::Start($newProcess);
    exit
}

if (-not (Test-Path -Path "$PSScriptRoot/autounattend.xml")) {
    Invoke-RestMethod "https://raw.githubusercontent.com/ntdevlabs/tiny11builder/refs/heads/main/autounattend.xml" -OutFile "$PSScriptRoot/autounattend.xml"
}

# Start the transcript and prepare the window
Start-Transcript -Path "$PSScriptRoot\tiny11_$(get-date -f yyyyMMdd_HHmms).log"
$script:transcriptStarted = $true

$Host.UI.RawUI.WindowTitle = "Tiny11 image creator"

Clear-Host
Write-Output "=== Welcome to the tiny11 image creator! Release: 09-07-25"

$hostArchitecture = $Env:PROCESSOR_ARCHITECTURE
New-Item -ItemType Directory -Force -Path "$ScratchDisk\tiny11\sources" | Out-Null

$mountedImagePath = $null

do {
    if (-not $ISO) {
        $isoInput = Read-Host "Please enter the drive letter for the Windows 11 image, or a path to a Windows 11 ISO"
        $isoInput = $isoInput -replace '"', ''

        if ($isoInput -match '^[c-zC-Z]$') {
            $DriveLetter = $isoInput
        } elseif ((Test-Path $isoInput -PathType Leaf) -and ($isoInput -match '\.iso$')) {
            try {
                $DriveLetter = (Mount-DiskImage -ImagePath $isoInput -Access ReadOnly | Get-Volume | Select-Object -ExpandProperty DriveLetter)
                $mountedImagePath = $isoInput
                Write-Output "Selected ${isoInput} (mounted with drive letter ${DriveLetter}:)."
            } catch {
                Write-Output "Failed to mount ISO file. Please verify the image path and try again."
                $DriveLetter = $null
            }
        } else {
            Write-Output "Invalid input. Enter a drive letter (C-Z) or a valid .iso file path."
            $DriveLetter = $null
        }
    } else {
        $DriveLetter = $ISO
    }

    if ($DriveLetter -match '^[c-zC-Z]$') {
        $DriveLetter = $DriveLetter + ":"
        Write-Output "Drive letter set to $DriveLetter"
    } else {
        Write-Output "Invalid drive letter. Please enter a letter between C and Z."
    }
} while ($DriveLetter -notmatch '^[c-zC-Z]:$')

if ((Test-Path "$DriveLetter\sources\boot.wim") -eq $false -or (Test-Path "$DriveLetter\sources\install.wim") -eq $false) {
    if ((Test-Path "$DriveLetter\sources\install.esd") -eq $true) {
        Write-Output "Found install.esd, converting to install.wim..."
        Get-WindowsImage -ImagePath $DriveLetter\sources\install.esd
        $index = Read-Host "Please enter the image index"
        Write-Output ' '
        Write-Output 'Converting install.esd to install.wim. This may take a while...'
        Export-WindowsImage -SourceImagePath $DriveLetter\sources\install.esd -SourceIndex $index -DestinationImagePath $ScratchDisk\tiny11\sources\install.wim -Compressiontype Maximum -CheckIntegrity
    } else {
        Write-Output "Can't find Windows OS Installation files in the specified Drive Letter.."
        Write-Output "Please enter the correct DVD Drive Letter.."
        exit
    }
}

Write-Output "=== Copying Windows image..."

Copy-Item -Path "$DriveLetter\*" -Destination "$ScratchDisk\tiny11" -Recurse -Force | Out-Null

if ($mountedImagePath) {
    Dismount-DiskImage -ImagePath $mountedImagePath -ErrorAction SilentlyContinue | Out-Null
}

Set-ItemProperty -Path "$ScratchDisk\tiny11\sources\install.esd" -Name IsReadOnly -Value $false -ErrorAction 'Continue' > $null 2>&1
Remove-Item "$ScratchDisk\tiny11\sources\install.esd" -ErrorAction 'Continue' > $null 2>&1
Write-Output "Copy complete!"
Start-Sleep -Seconds 2

Clear-Host
Write-Output "=== Getting image information:"
$ImagesIndex = (Get-WindowsImage -ImagePath $ScratchDisk\tiny11\sources\install.wim).ImageIndex
while ($ImagesIndex -notcontains $index) {
    Get-WindowsImage -ImagePath $ScratchDisk\tiny11\sources\install.wim
    $index = Read-Host "Please enter the image index"
}

Write-Output "=== Mounting Windows image. This may take a while."
$wimFilePath = "$ScratchDisk\tiny11\sources\install.wim"
& takeown "/F" $wimFilePath
& icacls $wimFilePath "/grant" "$($adminGroup.Value):(F)"
try {
    Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false -ErrorAction Stop
} catch {
    # This block will catch the error and suppress it.
    Write-Error "$wimFilePath not found"
}

New-Item -ItemType Directory -Force -Path "$ScratchDisk\scratchdir" > $null
Mount-WindowsImage -ImagePath $wimFilePath -Index $index -Path $ScratchDisk\scratchdir
$script:installImageMounted = $true

# Powershell dism module does not have direct equivalent for /Get-Intl
$imageIntl = & dism /English /Get-Intl "/Image:$($ScratchDisk)\scratchdir"
$languageLine = $imageIntl -split '\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' }

if ($languageLine) {
    $languageCode = $Matches[1]
    Write-Output "Default system UI language code: $languageCode"
} else {
    Write-Output "Default system UI language code not found."
}

# Defined in (Microsoft.Dism.Commands.ImageInfoObject).Architecture formatting script
# 0 -> x86, 5 -> arm(currently unused), 6 -> ia64(currently unused), 9 -> x64, 12 -> arm64
switch ((Get-WindowsImage -ImagePath $wimFilePath -Index $index).Architecture) 
{
    0 { $architecture = "x86" }
    9 { $architecture = "amd64" }
    12 { $architecture = "arm64" }
}

if ($architecture) {
    Write-Output "Architecture: $architecture"
} else {
    Write-Output "Architecture information not found."
}

Write-Output "=== Mounting complete! Performing removal of applications..."

$packages = Get-ProvisionedAppxPackage -Path "$ScratchDisk\scratchdir" |
    ForEach-Object {
        $_.PackageName
    }

#---------[ Package prefixes list ]---------#
$packagePrefixes = 'AppUp.IntelManagementandSecurityStatus',
'Clipchamp.Clipchamp',
'DolbyLaboratories.DolbyAccess',
'DolbyLaboratories.DolbyDigitalPlusDecoderOEM',
'Microsoft.549981C3F5F10',
'Microsoft.BingNews',
'Microsoft.BingSearch',
'Microsoft.BingWeather',
'Microsoft.Copilot',
'Microsoft.Edge.GameAssist',
'Microsoft.GamingApp',
'Microsoft.GetHelp',
'Microsoft.Getstarted',
'Microsoft.Microsoft3DViewer',
'Microsoft.MicrosoftOfficeHub',
'Microsoft.MicrosoftSolitaireCollection',
'Microsoft.MicrosoftStickyNotes',
'Microsoft.MixedReality.Portal',
'Microsoft.MSPaint',
'Microsoft.Office.OneNote',
'Microsoft.OfficePushNotificationUtility',
'Microsoft.OutlookForWindows',
'Microsoft.Paint',
'Microsoft.People',
'Microsoft.PowerAutomateDesktop',
'Microsoft.SkypeApp',
'Microsoft.StartExperiencesApp',
'Microsoft.Todos',
'Microsoft.Wallet',
'Microsoft.Windows.Copilot',
'Microsoft.Windows.CrossDevice',
'Microsoft.Windows.DevHome',
'Microsoft.Windows.Teams',
'Microsoft.WindowsAlarms',
'Microsoft.WindowsCamera',
'microsoft.windowscommunicationsapps',
'Microsoft.WindowsFeedbackHub',
'Microsoft.WindowsMaps',
'Microsoft.WindowsNotepad',
'Microsoft.WindowsSoundRecorder',
'Microsoft.MicrosoftEdge.Stable',
'Microsoft.WindowsTerminal',
'Microsoft.Xbox.TCUI',
'Microsoft.XboxApp',
'Microsoft.XboxGameOverlay',
'Microsoft.XboxGamingOverlay',
'Microsoft.XboxIdentityProvider',
'Microsoft.XboxSpeechToTextOverlay',
'Microsoft.YourPhone',
'Microsoft.ZuneMusic',
'Microsoft.ZuneVideo',
'MicrosoftCorporationII.MicrosoftFamily',
'MicrosoftCorporationII.QuickAssist',
'MSTeams',
'MicrosoftTeams', 
'Microsoft.549981C3F5F10'

$packageFile = Join-Path $PSScriptRoot 'removePackage.txt'
if (Test-Path -Path $packageFile -PathType Leaf) {
    $packagePrefixesFromFile = Get-Content -Path $packageFile |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' } |
        Select-Object -Unique

    if ($packagePrefixesFromFile.Count -gt 0) {
        $packagePrefixes = $packagePrefixesFromFile
        Write-Output "Loaded package removal list from removePackage.txt"
    }
}

if ($Custom) {
    try {
        $selectedPrefixes = Show-PackageSelector -Items $packagePrefixes -DefaultAll
    } catch {
        Write-Warning "Interactive selector failed or was interrupted. Defaulting to all configured prefixes."
        $selectedPrefixes = $packagePrefixes
    }

    if (-not $selectedPrefixes -or $selectedPrefixes.Count -eq 0) {
        Write-Output "No package prefixes selected for removal. Skipping Appx package removal step."
        $packagesToRemove = @()
    } else {
        Write-Output "Selected package prefixes to remove:"
        $selectedPrefixes | ForEach-Object { Write-Output " - $_" }

        $packagesToRemove = $packages | Where-Object {
            $packageName = $_
            $selectedPrefixes -contains ($selectedPrefixes | Where-Object { $packageName -like "*$_*" })
        }
    }
} else {
    $packagesToRemove = $packages | Where-Object {
        $packageName = $_
        $packagePrefixes -contains ($packagePrefixes | Where-Object { $packageName -like "*$_*" })
    }
}

foreach ($package in $packagesToRemove) {
    Write-Host "Removing $package..."
    Remove-AppxProvisionedPackage -Path "$ScratchDisk\scratchdir" -PackageName "$package" | Out-Null
}

Write-Output "=== Removing Edge:"
Remove-Item -Path "$ScratchDisk\scratchdir\Program Files (x86)\Microsoft\Edge" -Recurse -Force | Out-Null
Remove-Item -Path "$ScratchDisk\scratchdir\Program Files (x86)\Microsoft\EdgeUpdate" -Recurse -Force | Out-Null
Remove-Item -Path "$ScratchDisk\scratchdir\Program Files (x86)\Microsoft\EdgeCore" -Recurse -Force | Out-Null
& 'takeown' '/f' "$ScratchDisk\scratchdir\Windows\System32\Microsoft-Edge-Webview" '/r' | Out-Null
& 'icacls' "$ScratchDisk\scratchdir\Windows\System32\Microsoft-Edge-Webview" '/grant' "$($adminGroup.Value):(F)" '/T' '/C' | Out-Null
Remove-Item -Path "$ScratchDisk\scratchdir\Windows\System32\Microsoft-Edge-Webview" -Recurse -Force | Out-Null

Write-Output "=== Removing OneDrive:"
& 'takeown' '/f' "$ScratchDisk\scratchdir\Windows\System32\OneDriveSetup.exe" | Out-Null
& 'icacls' "$ScratchDisk\scratchdir\Windows\System32\OneDriveSetup.exe" '/grant' "$($adminGroup.Value):(F)" '/T' '/C' | Out-Null
Remove-Item -Path "$ScratchDisk\scratchdir\Windows\System32\OneDriveSetup.exe" -Force | Out-Null
Write-Output "Removal complete!"
Start-Sleep -Seconds 2
Write-Output "Getting Windows version..."
$windowsIs24H2 = reg query "HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion" /v DisplayVersion | Select-String -Pattern '24H2' -Quiet

Write-Output "=== Loading registry..."
reg load HKLM\zCOMPONENTS $ScratchDisk\scratchdir\Windows\System32\config\COMPONENTS | Out-Null
reg load HKLM\zDEFAULT $ScratchDisk\scratchdir\Windows\System32\config\default | Out-Null
reg load HKLM\zNTUSER $ScratchDisk\scratchdir\Users\Default\ntuser.dat | Out-Null
reg load HKLM\zSOFTWARE $ScratchDisk\scratchdir\Windows\System32\config\SOFTWARE | Out-Null
reg load HKLM\zSYSTEM $ScratchDisk\scratchdir\Windows\System32\config\SYSTEM | Out-Null
$script:offlineRegistryLoaded = $true

Write-Output "=== Bypassing system requirements (on the system image):"
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassCPUCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassRAMCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassSecureBootCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassStorageCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassTPMCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'

Write-Output "=== Disabling Sponsored Apps:"
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'OemPreInstalledAppsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'ContentDeliveryAllowed' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start' 'ConfigureStartPins' 'REG_SZ' '{"pinnedList": [{}]}'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'FeatureManagementEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEverEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContentEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353694Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353696Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall' 'DisablePushToInstall' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\MRT' 'DontOfferThroughWUAU' 'REG_DWORD' '1'
Remove-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions'
if (-not $windowsIs24H2) {
    Remove-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps'
}
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 'REG_DWORD' '1'

Write-Output "=== Enabling Local Accounts on OOBE:"
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'BypassNRO' 'REG_DWORD' '1'
Copy-Item -Path "$PSScriptRoot\autounattend.xml" -Destination "$ScratchDisk\scratchdir\Windows\System32\Sysprep\autounattend.xml" -Force | Out-Null

Write-Output "=== Disabling Reserved Storage:"
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves' 'REG_DWORD' '0'

Write-Output "=== Disabling BitLocker Device Encryption"
Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' 'PreventDeviceEncryption' 'REG_DWORD' '1'

Write-Output "=== Disabling Chat icon:"
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 'REG_DWORD' '3'
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'REG_DWORD' '0'

Write-Output "=== Removing Edge related registries"
Remove-RegistryValue "HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge"
Remove-RegistryValue "HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update"

Write-Output "=== Disabling OneDrive folder backup"
Set-RegistryValue "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" "REG_DWORD" "1"
Write-Output "Disabling Search Highlights:"
Set-RegistryValue 'HKLM\zSoftware\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDynamicSearchBoxEnabled' 'REG_DWORD' '0'
Write-Output "=== Disabling Automatic Maintenance:"
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' 'MaintenanceDisabled' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\ScheduledDiagnostics' 'EnabledExecution' 'REG_DWORD' '0'
Write-Output "=== Optimizing shutdown and responsiveness timings:"
Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control' 'WaitToKillServiceTimeout' 'REG_SZ' '1500'
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\Desktop' 'HungAppTimeout' 'REG_SZ' '2000'
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\Desktop' 'WaitToKillAppTimeout' 'REG_SZ' '2000'
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\Desktop' 'LowLevelHooksTimeout' 'REG_SZ' '1000'
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\Desktop' 'AutoEndTasks' 'REG_SZ' '1'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\Desktop' 'HungAppTimeout' 'REG_SZ' '2000'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\Desktop' 'WaitToKillAppTimeout' 'REG_SZ' '2000'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\Desktop' 'LowLevelHooksTimeout' 'REG_SZ' '1000'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\Desktop' 'AutoEndTasks' 'REG_SZ' '1'
Write-Output "=== Disabling Telemetry:"
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC' 'Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice' 'Start' 'REG_DWORD' '4'

$disableDriverAutoInstall = Read-Host "Prevent Windows from automatically installing device drivers? (y/N)"
if ($disableDriverAutoInstall -match '^(?i:y|yes)$') {
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' 'SearchOrderConfig' 'REG_DWORD' '0'
    Write-Output "Automatic device driver installation was disabled for the offline image."
} elseif ($disableDriverAutoInstall -match '^(?i:n|no)?$') {
    Write-Output "Keeping default driver installation behavior."
} else {
    Write-Output "Unrecognized answer. Keeping default driver installation behavior."
}

Write-Output "Disabling Windows Spotlight and tips on lockscreen"
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'RotatingLockScreenEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'RotatingLockScreenOverlayEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338387Enabled' 'REG_DWORD' '0'
## Prevents installation of DevHome and Outlook

$devHomeSelected = $packagesToRemove | Where-Object { $_ -like '*Microsoft.Windows.DevHome*' }
$outlookSelected = $packagesToRemove | Where-Object { $_ -like '*Microsoft.OutlookForWindows*' }
$copilotSelected = $packagesToRemove | Where-Object { $_ -like '*Microsoft.Windows.Copilot*' -or $_ -like '*Microsoft.Copilot*' }
$teamsSelected = $packagesToRemove | Where-Object { $_ -like '*Microsoft.Windows.Teams*' -or $_ -like '*MicrosoftTeams*' -or $_ -like '*MSTeams*' }

if (-not $Custom -or $outlookSelected) {
    Write-Output "=== Prevent installation of New Outlook:"
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
    Remove-RegistryValue 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail' 'PreventRun' 'REG_DWORD' '1'
}

if (-not $Custom -or $devHomeSelected) {
    Write-Output "=== Prevents installation of DevHome:"
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' 'workCompleted' 'REG_DWORD' '1'
    Remove-RegistryValue 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate'
}

if (-not $Custom -or $copilotSelected) {
    Write-Output "=== Disabling Copilot"
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\WindowsNotepad' 'DisableAIFeatures' 'REG_DWORD' '1'
    Write-Output "=== Prevent taking screenshots for Recall"
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 'REG_DWORD' '1'
}

if (-not $Custom -or $teamsSelected) {
    Write-Output "=== Prevents installation of Teams:"
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Teams' 'DisableInstallation' 'REG_DWORD' '1'
}

Write-Host "=== Deleting scheduled task definition files..."
$tasksPath = "$ScratchDisk\scratchdir\Windows\System32\Tasks"

Write-Host "=== Deleting Application Compatibility Appraiser"
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -Force -ErrorAction SilentlyContinue

Write-Host "=== Deleting Customer Experience Improvement Program (removes the entire folder and all tasks within it)"
Remove-Item -Path "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "=== Deleting Program Data Updater"
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater" -Force -ErrorAction SilentlyContinue

Write-Host "=== Deleting Chkdsk Proxy"
Remove-Item -Path "$tasksPath\Microsoft\Windows\Chkdsk\Proxy" -Force -ErrorAction SilentlyContinue

Write-Host "=== Deleting Windows Error Reporting (QueueReporting)"
Remove-Item -Path "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting" -Force -ErrorAction SilentlyContinue
Write-Host "Task files have been deleted."
Write-Host "Deleting scheduled task cache entries..."
if ($windowsIs24H2) {
    $taskCacheGuids = @(
        '3047C197-66F1-4523-BA92-6C955FEF9E4E', 'A0C71CB8-E8F0-498A-901D-4EDA09E07FF4',
        '780E487D-C62F-4B55-AF84-0E38116AFE07', 'FD607F42-4541-418A-B812-05C32EBA8626',
        'E4FED5BC-D567-4044-9642-2EDADF7DE108', 'E292525C-72F1-482C-8F35-C513FAA98DAE',
        '30E6DB3D-C3AA-44DA-8E88-9DB52D84975E', '7235AFD9-C139-458E-AA61-F6FD579A198F',
        '6FD85B93-7A13-4DCA-B793-1D7D18FEAC39'
    )
} else {
    $taskCacheGuids = @(
        '0600DD45-FAF2-4131-A006-0B17509B9F78', '4738DE7A-BCC1-4E2D-B1B0-CADB044BFA81',
        '6FAC31FA-4A85-4E64-BFD5-2154FF4594B3', 'FC931F16-B50A-472E-B061-B6F79A71EF59',
        '0671EB05-7D95-4153-A32B-1426B9FE61DB', '87BF85F4-2CE1-4160-96EA-52F554AA28A2',
        '8A9C643C-3D74-4099-B6BD-9C6D170898B1', 'E3176A65-4E44-4ED3-AA73-3283660ACB9C'
    )
}

Write-Host "Preparing ACL permissions for TaskCache entries..."
$taskCacheAclReady = Enable-TaskCacheWriteAccess -AdminGroup $adminGroup
if (-not $taskCacheAclReady) {
    Write-Warning "TaskCache ACL hardening did not complete. Continuing with best-effort deletion."
}

Remove-TaskCacheEntries -TaskGuids $taskCacheGuids

Write-Host "=== Unmounting Registry..."
Invoke-SafeOfflineRegistryUnload | Out-Null
$script:offlineRegistryLoaded = $false

Write-Output "=== Cleaning up image..."
dism.exe /Image:$ScratchDisk\scratchdir /Cleanup-Image /StartComponentCleanup /ResetBase
Write-Output "Cleanup complete."

Write-Output ''
Write-Output "=== Unmounting image..."
if (-not (Invoke-SafeDismountImage -Path "$ScratchDisk\scratchdir" -Save)) {
    throw "Failed to dismount the install image safely."
}
$script:installImageMounted = $false

Write-Host "=== Exporting image..."
Dism.exe /Export-Image /SourceImageFile:"$ScratchDisk\tiny11\sources\install.wim" /SourceIndex:$index /DestinationImageFile:"$ScratchDisk\tiny11\sources\install2.wim" /Compress:recovery
Remove-Item -Path "$ScratchDisk\tiny11\sources\install.wim" -Force | Out-Null
Rename-Item -Path "$ScratchDisk\tiny11\sources\install2.wim" -NewName "install.wim" | Out-Null
Write-Output "Windows image completed. Continuing with boot.wim."
Start-Sleep -Seconds 2

Write-Output "=== Mounting boot image:"
$wimFilePath = "$ScratchDisk\tiny11\sources\boot.wim"
& takeown "/F" $wimFilePath | Out-Null
& icacls $wimFilePath "/grant" "$($adminGroup.Value):(F)"
Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false
Mount-WindowsImage -ImagePath $ScratchDisk\tiny11\sources\boot.wim -Index 2 -Path $ScratchDisk\scratchdir
$script:bootImageMounted = $true

Write-Output "=== Loading registry..."
reg load HKLM\zCOMPONENTS $ScratchDisk\scratchdir\Windows\System32\config\COMPONENTS
reg load HKLM\zDEFAULT $ScratchDisk\scratchdir\Windows\System32\config\default
reg load HKLM\zNTUSER $ScratchDisk\scratchdir\Users\Default\ntuser.dat
reg load HKLM\zSOFTWARE $ScratchDisk\scratchdir\Windows\System32\config\SOFTWARE
reg load HKLM\zSYSTEM $ScratchDisk\scratchdir\Windows\System32\config\SYSTEM
$script:offlineRegistryLoaded = $true

Write-Output "=== Bypassing system requirements(on the setup image):"
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassCPUCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassRAMCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassSecureBootCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassStorageCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassTPMCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'
Write-Output "Tweaking complete!"

Write-Output "=== Unmounting Registry..."
Invoke-SafeOfflineRegistryUnload | Out-Null
$script:offlineRegistryLoaded = $false

Write-Output "=== Unmounting image..."
if (-not (Invoke-SafeDismountImage -Path "$ScratchDisk\scratchdir" -Save)) {
    throw "Failed to dismount the boot image safely."
}
$script:bootImageMounted = $false

Write-Output "========================================"
Write-Output "The tiny11 image is now completed. Proceeding with the making of the ISO..."
Write-Output "Copying unattended file for bypassing MS account on OOBE..."

Copy-Item -Path "$PSScriptRoot\autounattend.xml" -Destination "$ScratchDisk\tiny11\autounattend.xml" -Force | Out-Null

Write-Output "=== Creating ISO image..."
$ADKDepTools = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$hostarchitecture\Oscdimg"
# Get Windows ADK path from registry (following Visual Studio's winsdk.bat approach).
$WinSDKPath = [Microsoft.Win32.Registry]::GetValue("HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots", "KitsRoot10", $null)
if (!$WinSDKPath) {
    $WinSDKPath = [Microsoft.Win32.Registry]::GetValue("HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Kits\Installed Roots", "KitsRoot10", $null)
}

if ($WinSDKPath) {
    # Trim trailing backslash for path concatenation.
    $WinSDKPath = $WinSDKPath.TrimEnd('\\')
    $ADKDepTools = "$WinSDKPath\Assessment and Deployment Kit\Deployment Tools\$hostarchitecture\Oscdimg"
}
$localOSCDIMGPath = "$PSScriptRoot\oscdimg.exe"

if ($ADKDepTools -and [System.IO.File]::Exists("$ADKDepTools\oscdimg.exe")) {
    Write-Output "Will be using oscdimg.exe from system ADK."
    $OSCDIMG = "$ADKDepTools\oscdimg.exe"
} else {
    Write-Output "oscdimg.exe from system ADK not found. Will be using bundled oscdimg.exe."
    
    $url = "https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe"

    if (![System.IO.File]::Exists($localOSCDIMGPath)) {
        Write-Output "Downloading oscdimg.exe..."
        Invoke-WebRequest -Uri $url -OutFile $localOSCDIMGPath

        if ([System.IO.File]::Exists($localOSCDIMGPath)) {
            Write-Output "oscdimg.exe downloaded successfully."
        } else {
            Write-Error "Failed to download oscdimg.exe."
            exit 1
        }
    } else {
        Write-Output "oscdimg.exe already exists locally."
    }

    $OSCDIMG = $localOSCDIMGPath
}

& "$OSCDIMG" '-m' '-o' '-u2' '-udfver102' "-bootdata:2#p0,e,b$ScratchDisk\tiny11\boot\etfsboot.com#pEF,e,b$ScratchDisk\tiny11\efi\microsoft\boot\efisys.bin" "$ScratchDisk\tiny11" "$PSScriptRoot\tiny11.iso"

# Finishing up
Write-Output "Creation completed! Press any key to exit the script..."
Read-Host "Press Enter to continue"

Write-Output "=== Performing Cleanup..."
Remove-Item -Path "$ScratchDisk\tiny11" -Recurse -Force | Out-Null
Remove-Item -Path "$ScratchDisk\scratchdir" -Recurse -Force | Out-Null

Write-Output "=== Ejecting Iso drive"
Get-Volume -DriveLetter $DriveLetter[0] | Get-DiskImage | Dismount-DiskImage
Write-Output "Iso drive ejected"

Write-Output "=== Removing oscdimg.exe..."
Remove-Item -Path "$PSScriptRoot\oscdimg.exe" -Force -ErrorAction SilentlyContinue

Write-Output "=== Removing autounattend.xml..."
Remove-Item -Path "$PSScriptRoot\autounattend.xml" -Force -ErrorAction SilentlyContinue

Write-Output "=== Cleanup check :"
if (Test-Path -Path "$ScratchDisk\tiny11") {
    Write-Output "tiny11 folder still exists. Attempting to remove it again..."
    Remove-Item -Path "$ScratchDisk\tiny11" -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -Path "$ScratchDisk\tiny11") {
        Write-Output "Failed to remove tiny11 folder."
    } else {
        Write-Output "tiny11 folder removed successfully."
    }
} else {
    Write-Output "tiny11 folder does not exist. No action needed."
}

if (Test-Path -Path "$ScratchDisk\scratchdir") {
    Write-Output "scratchdir folder still exists. Attempting to remove it again..."
    Remove-Item -Path "$ScratchDisk\scratchdir" -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -Path "$ScratchDisk\scratchdir") {
        Write-Output "Failed to remove scratchdir folder."
    } else {
        Write-Output "scratchdir folder removed successfully."
    }
} else {
    Write-Output "scratchdir folder does not exist. No action needed."
}

if (Test-Path -Path "$PSScriptRoot\oscdimg.exe") {
    Write-Output "oscdimg.exe still exists. Attempting to remove it again..."
    Remove-Item -Path "$PSScriptRoot\oscdimg.exe" -Force -ErrorAction SilentlyContinue
    if (Test-Path -Path "$PSScriptRoot\oscdimg.exe") {
        Write-Output "Failed to remove oscdimg.exe."
    } else {
        Write-Output "oscdimg.exe removed successfully."
    }
} else {
    Write-Output "oscdimg.exe does not exist. No action needed."
}

if (Test-Path -Path "$PSScriptRoot\autounattend.xml") {
    Write-Output "autounattend.xml still exists. Attempting to remove it again..."
    Remove-Item -Path "$PSScriptRoot\autounattend.xml" -Force -ErrorAction SilentlyContinue
    if (Test-Path -Path "$PSScriptRoot\autounattend.xml") {
        Write-Output "Failed to remove autounattend.xml."
    } else {
        Write-Output "autounattend.xml removed successfully."
    }
} else {
    Write-Output "autounattend.xml does not exist. No action needed."
}

# Stop the transcript
Stop-Transcript
$script:transcriptStarted = $false

exit
