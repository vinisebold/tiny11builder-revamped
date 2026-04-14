<#
.SYNOPSIS
    Cross-platform entrypoint for building trimmed-down Windows 11 images.

.DESCRIPTION
    On Windows hosts this script forwards to the existing tiny11maker/tiny11coremaker
    scripts. On Linux hosts it performs a wimlib-powered flow that mirrors the core
    steps of tiny11maker: extract ISO, remove bundled applications, apply offline
    registry tweaks, and rebuild a bootable ISO.

.PARAMETER ISO
    (Windows only) Drive letter of the mounted Windows 11 ISO (eg: E).

.PARAMETER SCRATCH
    (Windows only) Drive letter for scratch space (eg: D).

.PARAMETER ISOPath
    (Linux only) Path to the Windows 11 ISO file.

.PARAMETER ScratchPath
    (Linux only) Directory to use for temporary build files. Defaults to the script
    location when not provided.

.PARAMETER Custom
    Optional switch to interactively choose which packages to remove (mirrors
    tiny11maker behaviour).

.PARAMETER ImageIndex
    Optional image index to operate on. When omitted you will be prompted after ISO
    extraction with the available indexes.

.PARAMETER Core
    On Windows, forwards to tiny11coremaker.ps1 instead of tiny11maker.ps1.
    On Linux the core workflow is not yet implemented and the flag is rejected.
#>
[CmdletBinding(DefaultParameterSetName = 'Windows')]
param(
    [Parameter(ParameterSetName = 'Windows', Mandatory = $true)]
    [ValidatePattern('^[c-zC-Z]$')]
    [string]$ISO,

    [Parameter(ParameterSetName = 'Windows', Mandatory = $true)]
    [ValidatePattern('^[c-zC-Z]$')]
    [string]$SCRATCH,

    [Parameter(ParameterSetName = 'Linux', Mandatory = $true)]
    [string]$ISOPath,

    [Parameter(ParameterSetName = 'Linux')]
    [string]$ScratchPath,

    [switch]$Custom,

    [Parameter(ParameterSetName = 'Linux')]
    [int]$ImageIndex,

    [switch]$Core
)

$ErrorActionPreference = 'Stop'

if ($IsWindows) {
    $scriptPath = if ($Core) {
        Join-Path $PSScriptRoot 'tiny11coremaker.ps1'
    } else {
        Join-Path $PSScriptRoot 'tiny11maker.ps1'
    }

    if (-not (Test-Path -Path $scriptPath -PathType Leaf)) {
        throw "Expected script '$scriptPath' was not found."
    }

    & $scriptPath -ISO $ISO -SCRATCH $SCRATCH -Custom:$Custom
    return
}

if ($Core) {
    throw "The core image path is not yet available for Linux hosts. Please rerun without -Core."
}

function Assert-Tool {
    param([string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required dependency: '$Name'. Please install it and retry."
    }
}

function Invoke-External {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.ArgumentList.AddRange($Arguments)

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $null = $proc.Start()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    if ($proc.ExitCode -ne 0) {
        throw "Command '$FilePath $($Arguments -join ' ') failed with code $($proc.ExitCode): $stderr"
    }

    return $stdout
}

function Get-PackagePrefixes {
    $packageFile = Join-Path $PSScriptRoot 'removePackage.txt'
    if (Test-Path -Path $packageFile -PathType Leaf) {
        return Get-Content -Path $packageFile |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' } |
            Select-Object -Unique
    }

    return @()
}

function Select-ImageIndex {
    param(
        [string]$WimPath,
        [int]$ProvidedIndex
    )

    $info = Invoke-External -FilePath 'wimlib-imagex' -Arguments @('info', $WimPath)
    $indexes = @()

    foreach ($line in $info -split "`n") {
        if ($line -match 'Index:\s+(\d+)') {
            $indexes += [int]$Matches[1]
        }
    }

    if (-not $indexes) {
        throw "No image indexes found in $WimPath."
    }

    if ($ProvidedIndex -and $indexes -contains $ProvidedIndex) {
        return $ProvidedIndex
    }

    Write-Host "Available image indexes in $WimPath:"
    Write-Host $info
    $selection = Read-Host "Please enter the image index to process"

    $parsed = 0
    if (-not [int]::TryParse($selection, [ref]$parsed)) {
        throw "Invalid image index selection."
    }

    $selected = [int]$parsed
    if ($indexes -notcontains $selected) {
        throw "Image index $selected not found in $WimPath."
    }

    return $selected
}

function Mount-Wim {
    param(
        [string]$WimPath,
        [int]$Index,
        [string]$MountDir
    )

    if (-not (Test-Path -Path $MountDir)) {
        New-Item -ItemType Directory -Force -Path $MountDir | Out-Null
    }

    Invoke-External -FilePath 'wimlib-imagex' -Arguments @('mount', $WimPath, $Index, $MountDir, '--rw') | Out-Null
}

function Dismount-Wim {
    param(
        [string]$MountDir,
        [switch]$Commit
    )

    $args = @('unmount', $MountDir)
    if ($Commit) {
        $args += '--commit'
    }

    Invoke-External -FilePath 'wimlib-imagex' -Arguments $args | Out-Null
}

function Remove-LinuxPackages {
    param(
        [string]$MountDir,
        [string[]]$PackagePrefixes
    )

    if (-not $PackagePrefixes) {
        Write-Host "No package prefixes provided; skipping package removal."
        return
    }

    $targets = @(
        Join-Path $MountDir 'Program Files/WindowsApps',
        Join-Path $MountDir 'Windows/SystemApps',
        Join-Path $MountDir 'Windows/Provisioning/Packages'
    )

    foreach ($target in $targets) {
        if (-not (Test-Path -Path $target)) { continue }

        foreach ($prefix in $PackagePrefixes) {
            $matches = Get-ChildItem -Path $target -Filter "*$prefix*" -ErrorAction SilentlyContinue
            foreach ($match in $matches) {
                Write-Host "Removing package payload: $($match.FullName)"
                Remove-Item -Path $match.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Build-RegFileContent {
    param(
        [hashtable[]]$Entries
    )

    $builder = New-Object System.Text.StringBuilder
    $null = $builder.AppendLine('Windows Registry Editor Version 5.00')
    $null = $builder.AppendLine()

    $grouped = $Entries | Group-Object { $_.Key }
    foreach ($group in $grouped) {
        $deletesOnly = $group.Group | Where-Object { $_.Action -eq 'DeleteKey' }
        if ($deletesOnly.Count -eq $group.Count) {
            foreach ($entry in $deletesOnly) {
                $null = $builder.AppendLine("[-HKEY_LOCAL_MACHINE\$($group.Name)]")
            }
            $null = $builder.AppendLine()
            continue
        }

        $null = $builder.AppendLine("[HKEY_LOCAL_MACHINE\$($group.Name)]")
        foreach ($entry in $group.Group | Where-Object { $_.Action -ne 'DeleteKey' }) {
            switch ($entry.Type) {
                'dword' { $formatted = ('{0:x8}' -f [int]$entry.Value); $null = $builder.AppendLine("\"$($entry.Name)\"=dword:$formatted") }
                'string' { $escaped = $entry.Value -replace '"', '\"'; $null = $builder.AppendLine("\"$($entry.Name)\"=\"$escaped\"") }
                default { $null = $builder.AppendLine("\"$($entry.Name)\"=\"$($entry.Value)\"") }
            }
        }

        $null = $builder.AppendLine()
    }

    return $builder.ToString()
}

function Merge-OfflineRegistry {
    param(
        [string]$HivePath,
        [hashtable[]]$Entries
    )

    if (-not $Entries -or -not (Test-Path -Path $HivePath -PathType Leaf)) {
        return
    }

    $regFile = New-TemporaryFile
    $content = Build-RegFileContent -Entries $Entries
    Set-Content -Path $regFile -Value $content -Encoding ASCII

    $cmd = "hivexregedit --merge `"$HivePath`" < `"$regFile`""
    $bash = "/bin/bash"
    if (-not (Test-Path -Path $bash -PathType Leaf)) {
        throw "bash is required to run hivexregedit merge operations."
    }

    Invoke-External -FilePath $bash -Arguments @('-lc', $cmd) | Out-Null
    Remove-Item -Path $regFile -Force -ErrorAction SilentlyContinue
}

function Get-OfflineRegistryOperations {
    param(
        [switch]$IncludeConsumerRemovals
    )

    $entries = @(
        @{ Hive = 'DEFAULT'; Key = 'Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV1'; Type = 'dword'; Value = 0 },
        @{ Hive = 'DEFAULT'; Key = 'Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV2'; Type = 'dword'; Value = 0 },

        @{ Hive = 'NTUSER'; Key = 'Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV1'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV2'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'OemPreInstalledAppsEnabled'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'PreInstalledAppsEnabled'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SilentInstalledAppsEnabled'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'ContentDeliveryAllowed'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'FeatureManagementEnabled'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'PreInstalledAppsEverEnabled'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SoftLandingEnabled'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContentEnabled'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-310093Enabled'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338388Enabled'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338389Enabled'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338393Enabled'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353694Enabled'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353696Enabled'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SystemPaneSuggestionsEnabled'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy'; Name = 'TailoredExperiencesWithDiagnosticDataEnabled'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'; Name = 'HasAccepted'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Input\TIPC'; Name = 'Enabled'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\InputPersonalization'; Name = 'RestrictImplicitInkCollection'; Type = 'dword'; Value = 1 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\InputPersonalization'; Name = 'RestrictImplicitTextCollection'; Type = 'dword'; Value = 1 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\InputPersonalization\TrainedDataStore'; Name = 'HarvestContacts'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Personalization\Settings'; Name = 'AcceptedPrivacyPolicy'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarMn'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'RotatingLockScreenEnabled'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'RotatingLockScreenOverlayEnabled'; Type = 'dword'; Value = 0 },
        @{ Hive = 'NTUSER'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338387Enabled'; Type = 'dword'; Value = 0 },

        @{ Hive = 'SYSTEM'; Key = 'Setup\LabConfig'; Name = 'BypassCPUCheck'; Type = 'dword'; Value = 1 },
        @{ Hive = 'SYSTEM'; Key = 'Setup\LabConfig'; Name = 'BypassRAMCheck'; Type = 'dword'; Value = 1 },
        @{ Hive = 'SYSTEM'; Key = 'Setup\LabConfig'; Name = 'BypassSecureBootCheck'; Type = 'dword'; Value = 1 },
        @{ Hive = 'SYSTEM'; Key = 'Setup\LabConfig'; Name = 'BypassStorageCheck'; Type = 'dword'; Value = 1 },
        @{ Hive = 'SYSTEM'; Key = 'Setup\LabConfig'; Name = 'BypassTPMCheck'; Type = 'dword'; Value = 1 },
        @{ Hive = 'SYSTEM'; Key = 'Setup\MoSetup'; Name = 'AllowUpgradesWithUnsupportedTPMOrCPU'; Type = 'dword'; Value = 1 },
        @{ Hive = 'SYSTEM'; Key = 'ControlSet001\Control\BitLocker'; Name = 'PreventDeviceEncryption'; Type = 'dword'; Value = 1 },
        @{ Hive = 'SYSTEM'; Key = 'ControlSet001\Services\dmwappushservice'; Name = 'Start'; Type = 'dword'; Value = 4 },

        @{ Hive = 'SOFTWARE'; Key = 'Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures'; Type = 'dword'; Value = 1 },
        @{ Hive = 'SOFTWARE'; Key = 'Policies\Microsoft\Windows\CloudContent'; Name = 'DisableConsumerAccountStateContent'; Type = 'dword'; Value = 1 },
        @{ Hive = 'SOFTWARE'; Key = 'Policies\Microsoft\Windows\CloudContent'; Name = 'DisableCloudOptimizedContent'; Type = 'dword'; Value = 1 },
        @{ Hive = 'SOFTWARE'; Key = 'Microsoft\PolicyManager\current\device\Start'; Name = 'ConfigureStartPins'; Type = 'string'; Value = '{"pinnedList": [{}]}' },
        @{ Hive = 'SOFTWARE'; Key = 'Policies\Microsoft\PushToInstall'; Name = 'DisablePushToInstall'; Type = 'dword'; Value = 1 },
        @{ Hive = 'SOFTWARE'; Key = 'Policies\Microsoft\MRT'; Name = 'DontOfferThroughWUAU'; Type = 'dword'; Value = 1 },
        @{ Hive = 'SOFTWARE'; Key = 'Policies\Microsoft\Windows\OneDrive'; Name = 'DisableFileSyncNGSC'; Type = 'dword'; Value = 1 },
        @{ Hive = 'SOFTWARE'; Key = 'Microsoft\Windows\CurrentVersion\SearchSettings'; Name = 'IsDynamicSearchBoxEnabled'; Type = 'dword'; Value = 0 },
        @{ Hive = 'SOFTWARE'; Key = 'Microsoft\Windows\CurrentVersion\ReserveManager'; Name = 'ShippedWithReserves'; Type = 'dword'; Value = 0 },
        @{ Hive = 'SOFTWARE'; Key = 'Policies\Microsoft\Windows\Windows Chat'; Name = 'ChatIcon'; Type = 'dword'; Value = 3 },
        @{ Hive = 'SOFTWARE'; Key = 'Microsoft\Windows\CurrentVersion\OOBE'; Name = 'BypassNRO'; Type = 'dword'; Value = 1 },
        @{ Hive = 'SOFTWARE'; Key = 'Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; Type = 'dword'; Value = 0 },
        @{ Hive = 'SOFTWARE'; Key = 'Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Type = 'dword'; Value = 1 },
        @{ Hive = 'SOFTWARE'; Key = 'Policies\Microsoft\Edge'; Name = 'HubsSidebarEnabled'; Type = 'dword'; Value = 0 },
        @{ Hive = 'SOFTWARE'; Key = 'Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Type = 'dword'; Value = 1 },
        @{ Hive = 'SOFTWARE'; Key = 'Policies\WindowsNotepad'; Name = 'DisableAIFeatures'; Type = 'dword'; Value = 1 },
        @{ Hive = 'SOFTWARE'; Key = 'Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableAIDataAnalysis'; Type = 'dword'; Value = 1 },
        @{ Hive = 'SOFTWARE'; Key = 'Policies\Microsoft\Teams'; Name = 'DisableInstallation'; Type = 'dword'; Value = 1 },
        @{ Hive = 'SOFTWARE'; Key = 'Policies\Microsoft\Windows\Windows Mail'; Name = 'PreventRun'; Type = 'dword'; Value = 1 },
        @{ Hive = 'SOFTWARE'; Key = 'Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate'; Name = 'workCompleted'; Type = 'dword'; Value = 1 },
        @{ Hive = 'SOFTWARE'; Key = 'Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate'; Name = 'workCompleted'; Type = 'dword'; Value = 1 },
        @{ Hive = 'SOFTWARE'; Key = 'Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate'; Name = 'workCompleted'; Type = 'dword'; Value = 1 }
    )

    if ($IncludeConsumerRemovals) {
        $entries += @(
            @{ Hive = 'SOFTWARE'; Key = 'Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate'; Action = 'DeleteKey' },
            @{ Hive = 'SOFTWARE'; Key = 'Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate'; Action = 'DeleteKey' },
            @{ Hive = 'SOFTWARE'; Key = 'WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge'; Action = 'DeleteKey' },
            @{ Hive = 'SOFTWARE'; Key = 'WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update'; Action = 'DeleteKey' }
        )
    }

    return $entries
}

function Apply-OfflineRegistry {
    param(
        [string]$MountDir,
        [switch]$IncludeConsumerRemovals
    )

    $ops = Get-OfflineRegistryOperations -IncludeConsumerRemovals:$IncludeConsumerRemovals

    $hiveMap = @{
        'DEFAULT' = Join-Path $MountDir 'Windows/System32/config/default'
        'NTUSER'  = Join-Path $MountDir 'Users/Default/ntuser.dat'
        'SYSTEM'  = Join-Path $MountDir 'Windows/System32/config/SYSTEM'
        'SOFTWARE'= Join-Path $MountDir 'Windows/System32/config/SOFTWARE'
    }

    foreach ($hive in $hiveMap.Keys) {
        $entries = $ops | Where-Object { $_.Hive -eq $hive }
        Merge-OfflineRegistry -HivePath $hiveMap[$hive] -Entries $entries
    }
}

function Remove-ScheduledTasksFromImage {
    param([string]$MountDir)

    $tasksRoot = Join-Path $MountDir 'Windows/System32/Tasks'
    if (-not (Test-Path -Path $tasksRoot)) { return }

    $targets = @(
        'Microsoft/Windows/Application Experience/Microsoft Compatibility Appraiser',
        'Microsoft/Windows/Customer Experience Improvement Program',
        'Microsoft/Windows/Application Experience/ProgramDataUpdater',
        'Microsoft/Windows/Chkdsk/Proxy',
        'Microsoft/Windows/Windows Error Reporting/QueueReporting'
    )

    foreach ($target in $targets) {
        $full = Join-Path $tasksRoot $target
        if (Test-Path -Path $full) {
            Write-Host "Removing scheduled task definition: $full"
            Remove-Item -Path $full -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-TaskCacheEntries {
    param([string]$MountDir)

    $guids = @(
        '3047C197-66F1-4523-BA92-6C955FEF9E4E','A0C71CB8-E8F0-498A-901D-4EDA09E07FF4',
        '780E487D-C62F-4B55-AF84-0E38116AFE07','FD607F42-4541-418A-B812-05C32EBA8626',
        'E4FED5BC-D567-4044-9642-2EDADF7DE108','E292525C-72F1-482C-8F35-C513FAA98DAE',
        '30E6DB3D-C3AA-44DA-8E88-9DB52D84975E','7235AFD9-C139-458E-AA61-F6FD579A198F',
        '6FD85B93-7A13-4DCA-B793-1D7D18FEAC39',
        '0600DD45-FAF2-4131-A006-0B17509B9F78','4738DE7A-BCC1-4E2D-B1B0-CADB044BFA81',
        '6FAC31FA-4A85-4E64-BFD5-2154FF4594B3','FC931F16-B50A-472E-B061-B6F79A71EF59',
        '0671EB05-7D95-4153-A32B-1426B9FE61DB','87BF85F4-2CE1-4160-96EA-52F554AA28A2',
        '8A9C643C-3D74-4099-B6BD-9C6D170898B1','E3176A65-4E44-4ED3-AA73-3283660ACB9C'
    )

    $softwareHive = Join-Path $MountDir 'Windows/System32/config/SOFTWARE'
    $entries = foreach ($guid in $guids) {
        @{ Hive = 'SOFTWARE'; Key = "Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks\{$guid}"; Action = 'DeleteKey' }
    }

    Merge-OfflineRegistry -HivePath $softwareHive -Entries $entries
}

function Compress-Wim {
    param(
        [string]$Source,
        [string]$Destination,
        [int]$Index
    )

    if (Test-Path -Path $Destination) {
        Remove-Item -Path $Destination -Force
    }

    Invoke-External -FilePath 'wimlib-imagex' -Arguments @('export', $Source, $Index.ToString(), $Destination, '--compress=LZMS') | Out-Null
}

function New-IsoImage {
    param(
        [string]$SourceDir,
        [string]$OutputPath
    )

    $biosBoot = Join-Path $SourceDir 'boot/etfsboot.com'
    $efiBoot  = Join-Path $SourceDir 'efi/microsoft/boot/efisys.bin'

    if (-not (Test-Path -Path $biosBoot -PathType Leaf)) {
        throw "Could not find BIOS boot sector at $biosBoot"
    }
    if (-not (Test-Path -Path $efiBoot -PathType Leaf)) {
        throw "Could not find EFI boot sector at $efiBoot"
    }

    $args = @(
        '-as', 'mkisofs',
        '-iso-level', '3',
        '-udf',
        '-o', $OutputPath,
        '-full-iso9660-filenames',
        '-volid', 'tiny11',
        '-eltorito-boot', 'boot/etfsboot.com',
        '-no-emul-boot',
        '-boot-load-size', '8',
        '-boot-info-table',
        '-eltorito-alt-boot',
        '-e', 'efi/microsoft/boot/efisys.bin',
        '-no-emul-boot',
        $SourceDir
    )

    Invoke-External -FilePath 'xorriso' -Arguments $args | Out-Null
}

Write-Host "Running Linux tiny11 build flow..."

if (-not $ScratchPath) {
    $ScratchPath = $PSScriptRoot
}

if (-not (Test-Path -Path $ScratchPath)) {
    New-Item -ItemType Directory -Force -Path $ScratchPath | Out-Null
}

Assert-Tool -Name 'wimlib-imagex'
Assert-Tool -Name '7z'
Assert-Tool -Name 'hivexregedit'
Assert-Tool -Name 'xorriso'
Assert-Tool -Name 'bash'

$workDir = Join-Path $ScratchPath 'tiny11'
$mountDir = Join-Path $ScratchPath 'install_mount'
$bootMountDir = Join-Path $ScratchPath 'boot_mount'

if (Test-Path -Path $workDir) { Remove-Item -Path $workDir -Recurse -Force }
if (Test-Path -Path $mountDir) { Remove-Item -Path $mountDir -Recurse -Force }
if (Test-Path -Path $bootMountDir) { Remove-Item -Path $bootMountDir -Recurse -Force }

New-Item -ItemType Directory -Force -Path $workDir | Out-Null
New-Item -ItemType Directory -Force -Path $mountDir | Out-Null
New-Item -ItemType Directory -Force -Path $bootMountDir | Out-Null

Write-Host "Extracting ISO to $workDir ..."
Invoke-External -FilePath '7z' -Arguments @('x', $ISOPath, "-o$workDir", '-y') | Out-Null

$installEsd = Join-Path $workDir 'sources/install.esd'
$installWim = Join-Path $workDir 'sources/install.wim'
if (Test-Path -Path $installEsd) {
    Write-Host "Converting install.esd to install.wim..."
    Invoke-External -FilePath 'wimlib-imagex' -Arguments @('export', $installEsd, 'all', $installWim, '--compress=LZMS') | Out-Null
    Remove-Item -Path $installEsd -Force
}

if (-not (Test-Path -Path $installWim)) {
    throw "install.wim not found after extraction."
}

$selectedIndex = Select-ImageIndex -WimPath $installWim -ProvidedIndex $ImageIndex
Write-Host "Using image index $selectedIndex"

Write-Host "Mounting install.wim..."
Mount-Wim -WimPath $installWim -Index $selectedIndex -MountDir $mountDir

try {
    $prefixes = Get-PackagePrefixes
    if ($Custom -and $prefixes.Count -gt 0) {
        Write-Host "Custom mode selected. Type the package prefixes to keep (comma-separated). Leave blank to remove all configured packages."
        Write-Host ("Available prefixes: " + ($prefixes -join ', '))
        $keepInput = Read-Host "Enter prefixes to keep or press Enter to remove all"
        if ($keepInput) {
            $keep = $keepInput.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            $prefixes = $prefixes | Where-Object { $keep -notcontains $_ }
        }
    }

    Remove-LinuxPackages -MountDir $mountDir -PackagePrefixes $prefixes

    Write-Host "Removing Edge and OneDrive payloads..."
    $edgePaths = @(
        Join-Path $mountDir 'Program Files (x86)/Microsoft/Edge',
        Join-Path $mountDir 'Program Files (x86)/Microsoft/EdgeUpdate',
        Join-Path $mountDir 'Program Files (x86)/Microsoft/EdgeCore',
        Join-Path $mountDir 'Windows/System32/Microsoft-Edge-Webview'
    )
    foreach ($edgePath in $edgePaths) {
        if (Test-Path -Path $edgePath) {
            Remove-Item -Path $edgePath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $oneDriveSetup = Join-Path $mountDir 'Windows/System32/OneDriveSetup.exe'
    if (Test-Path -Path $oneDriveSetup) {
        Remove-Item -Path $oneDriveSetup -Force -ErrorAction SilentlyContinue
    }

    Write-Host "Copying autounattend.xml into offline image..."
    $unattendSource = Join-Path $PSScriptRoot 'autounattend.xml'
    $unattendDest = Join-Path $mountDir 'Windows/System32/Sysprep/autounattend.xml'
    if (Test-Path -Path $unattendSource) {
        New-Item -ItemType Directory -Force -Path (Split-Path $unattendDest -Parent) | Out-Null
        Copy-Item -Path $unattendSource -Destination $unattendDest -Force
    }

    Write-Host "Applying offline registry tweaks..."
    Apply-OfflineRegistry -MountDir $mountDir -IncludeConsumerRemovals

    Write-Host "Cleaning scheduled tasks..."
    Remove-ScheduledTasksFromImage -MountDir $mountDir
    Remove-TaskCacheEntries -MountDir $mountDir
}
finally {
    Write-Host "Unmounting install.wim..."
    Dismount-Wim -MountDir $mountDir -Commit
}

Write-Host "Compressing install.wim..."
$compressedWim = Join-Path $workDir 'sources/install_compressed.wim'
Compress-Wim -Source $installWim -Destination $compressedWim -Index $selectedIndex
Remove-Item -Path $installWim -Force
Rename-Item -Path $compressedWim -NewName 'install.wim'

Write-Host "Mounting boot.wim..."
$bootWim = Join-Path $workDir 'sources/boot.wim'
Mount-Wim -WimPath $bootWim -Index 2 -MountDir $bootMountDir

try {
    Apply-OfflineRegistry -MountDir $bootMountDir
}
finally {
    Write-Host "Unmounting boot.wim..."
    Dismount-Wim -MountDir $bootMountDir -Commit
}

Write-Host "Copying root-level autounattend.xml..."
if (Test-Path -Path $unattendSource) {
    Copy-Item -Path $unattendSource -Destination (Join-Path $workDir 'autounattend.xml') -Force
}

Write-Host "Building ISO image..."
$outputIso = Join-Path $PSScriptRoot 'tiny11.iso'
New-IsoImage -SourceDir $workDir -OutputPath $outputIso

Write-Host "Cleaning scratch directories..."
Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $mountDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $bootMountDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Done! Generated ISO at $outputIso"
