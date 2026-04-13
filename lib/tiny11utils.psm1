function Set-RegistryValue {
    param (
        [string]$path,
        [string]$name,
        [string]$type,
        [string]$value
    )
    try {
        & 'reg' 'add' $path '/v' $name '/t' $type '/d' $value '/f' | Out-Null
        Write-Output "Set registry value: $path\$name"
    } catch {
        Write-Output "Error setting registry value: $_"
    }
}

function Remove-RegistryValue {
    param (
        [string]$path
    )
    try {
        & 'reg' 'delete' $path '/f' | Out-Null
        Write-Output "Removed registry value: $path"
    } catch {
        Write-Output "Error removing registry value: $_"
    }
}

function Enable-Privilege {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Privilege
    )

    if (-not ('AdjPriv' -as [type])) {
        $source = @"
using System;
using System.Runtime.InteropServices;

public static class AdjPriv
{
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    internal struct TokPriv1Luid
    {
        public int Count;
        public long Luid;
        public int Attr;
    }

    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
    internal static extern bool OpenProcessToken(IntPtr h, int acc, ref IntPtr phtok);

    [DllImport("advapi32.dll", SetLastError = true)]
    internal static extern bool LookupPrivilegeValue(string host, string name, ref long pluid);

    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
    internal static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall, ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr relen);

    [DllImport("kernel32.dll", ExactSpelling = true)]
    internal static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", ExactSpelling = true)]
    internal static extern bool CloseHandle(IntPtr h);

    internal const int SE_PRIVILEGE_ENABLED = 0x00000002;
    internal const int TOKEN_QUERY = 0x00000008;
    internal const int TOKEN_ADJUST_PRIVILEGES = 0x00000020;

    public static bool EnablePrivilege(string privilege)
    {
        IntPtr htok = IntPtr.Zero;
        TokPriv1Luid tp;
        long luid = 0;

        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref htok))
        {
            return false;
        }

        if (!LookupPrivilegeValue(null, privilege, ref luid))
        {
            CloseHandle(htok);
            return false;
        }

        tp.Count = 1;
        tp.Luid = luid;
        tp.Attr = SE_PRIVILEGE_ENABLED;

        bool retVal = AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        CloseHandle(htok);
        return retVal;
    }
}
"@

        Add-Type -TypeDefinition $source -ErrorAction Stop | Out-Null
    }

    [AdjPriv]::EnablePrivilege($Privilege) | Out-Null
}

function Enable-TaskCacheWriteAccess {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Principal.NTAccount]$AdminGroup,
        [string]$OfflineTaskKey = 'zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks'
    )

    try {
        Enable-Privilege -Privilege 'SeTakeOwnershipPrivilege'
        Enable-Privilege -Privilege 'SeBackupPrivilege'
        Enable-Privilege -Privilege 'SeRestorePrivilege'
    } catch {
        Write-Warning "Could not enable all required privileges for TaskCache ACL handling: $_"
    }

    try {
        $ownershipKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $OfflineTaskKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::TakeOwnership
        )

        if (-not $ownershipKey) {
            Write-Warning "TaskCache key not found for ownership update: $OfflineTaskKey"
            return $false
        }

        $ownershipAcl = $ownershipKey.GetAccessControl()
        $ownershipAcl.SetOwner($AdminGroup)
        $ownershipKey.SetAccessControl($ownershipAcl)
        $ownershipKey.Close()

        $permissionKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $OfflineTaskKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::ChangePermissions
        )

        if (-not $permissionKey) {
            Write-Warning "TaskCache key not found for permission update: $OfflineTaskKey"
            return $false
        }

        $permissionAcl = $permissionKey.GetAccessControl()
        $permissionAcl.SetAccessRuleProtection($false, $false)

        $allowRule = New-Object System.Security.AccessControl.RegistryAccessRule(
            $AdminGroup,
            [System.Security.AccessControl.RegistryRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )

        $permissionAcl.SetAccessRule($allowRule)
        $permissionKey.SetAccessControl($permissionAcl)
        $permissionKey.Close()

        return $true
    } catch {
        Write-Warning "Failed to grant TaskCache write access: $_"
        return $false
    }
}

function Remove-TaskCacheEntries {
    param(
        [string[]]$TaskGuids,
        [string]$TaskCacheRoot = 'HKEY_LOCAL_MACHINE\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks'
    )

    foreach ($taskGuid in $TaskGuids) {
        if ([string]::IsNullOrWhiteSpace($taskGuid)) {
            continue
        }

        $taskPath = "$TaskCacheRoot\{$taskGuid}"
        & 'reg' 'delete' $taskPath '/f' | Out-Null

        if ($LASTEXITCODE -eq 0) {
            Write-Output "Removed TaskCache entry: $taskGuid"
        } else {
            Write-Warning "Could not remove TaskCache entry (may not exist): $taskGuid"
        }
    }
}

function Invoke-SafeOfflineRegistryUnload {
    param(
        [string[]]$Hives = @('zCOMPONENTS', 'zDEFAULT', 'zNTUSER', 'zSOFTWARE', 'zSYSTEM')
    )

    foreach ($hive in $Hives) {
        & 'reg' 'unload' "HKLM\$hive" | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Output "Unloaded registry hive: HKLM\$hive"
        } else {
            Write-Warning "Could not unload HKLM\$hive (it may already be unloaded)."
        }
    }
}

function Invoke-SafeDismountImage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [switch]$Save
    )

    if (-not (Test-Path -Path $Path)) {
        return $false
    }

    try {
        if ($Save) {
            Dismount-WindowsImage -Path $Path -Save -ErrorAction Stop
        } else {
            Dismount-WindowsImage -Path $Path -Discard -ErrorAction Stop
        }

        return $true
    } catch {
        Write-Warning "Failed to dismount image at $Path: $_"
        return $false
    }
}

Export-ModuleMember -Function Set-RegistryValue
Export-ModuleMember -Function Remove-RegistryValue
Export-ModuleMember -Function Enable-Privilege
Export-ModuleMember -Function Enable-TaskCacheWriteAccess
Export-ModuleMember -Function Remove-TaskCacheEntries
Export-ModuleMember -Function Invoke-SafeOfflineRegistryUnload
Export-ModuleMember -Function Invoke-SafeDismountImage
