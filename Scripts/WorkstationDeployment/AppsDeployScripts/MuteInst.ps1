#Requires -Version 5.1
<#
.SYNOPSIS
    Mutes system audio (sets Mute, doesn't toggle it) so the constant
    Windows notification pings during setup stop being annoying. Designed
    to run elevated (RWW WorkstationDeployment project -- see
    Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/MuteInst.ps1

    HONESTY FLAG -- THE LEAST-VERIFIED SCRIPT IN THIS PROJECT: there is no
    built-in PowerShell cmdlet for setting (not toggling) system mute, so
    this uses COM interop with the Windows Core Audio API
    (IAudioEndpointVolume) via a hand-written C# interface definition.
    This exact interface/vtable-slot pattern is widely circulated and is
    the same approach the popular "AudioDeviceCmdlets" PowerShell module
    uses -- reasonable confidence it's correct -- but unlike every other
    script in this project, it can't be compile-tested from a sandbox
    without a real Windows box, and COM interop mistakes (wrong vtable
    slot order) can misbehave in less predictable ways than a normal
    script error would. Watch this one closely on its first real test.

    Deliberately calls SetMute(true) rather than simulating the
    volume-mute key: a simulated keypress TOGGLES current state, so if
    the machine happened to already be muted, a toggle would actually
    UNMUTE it -- the opposite of what this is supposed to do. SetMute
    with an explicit value avoids that failure mode entirely.

    Purely cosmetic/non-critical -- a failure here doesn't affect any
    actual software installation, so this treats "no default audio
    endpoint" (plausible in some SYSTEM/RDP/no-active-session contexts)
    as a harmless skip rather than a failure.

.PARAMETER LogPath
    Where to write this script's own log file.

.EXITCODES
    0 = success -- audio was muted this run
    1 = the COM call failed unexpectedly
    3 = not running elevated
    4 = nothing to do -- no default audio endpoint found (or already muted)
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\MuteInst.log"
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($Global:RWWLogSink) {
        try { & $Global:RWWLogSink $line } catch {}
    } else {
        [Console]::WriteLine($line)
    }
    try {
        $dir = Split-Path -Path $LogPath -Parent
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        Add-Content -Path $LogPath -Value $line
    } catch {}
}

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or $identity.IsSystem
}

if (-not (Test-IsElevated)) {
    Write-Log "Not running elevated. Re-run as administrator." 'ERROR'
    exit 3
}

Write-Log "=== Install-Mute starting on $env:COMPUTERNAME ==="

try {
    if (-not ([System.Management.Automation.PSTypeName]'RWWAudio.Volume').Type) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace RWWAudio {
    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume {
        int RegisterControlChangeNotify(IntPtr pNotify);
        int UnregisterControlChangeNotify(IntPtr pNotify);
        int GetChannelCount(ref uint pnChannelCount);
        int SetMasterVolumeLevel(float fLevelDB, Guid pguidEventContext);
        int SetMasterVolumeLevelScalar(float fLevel, Guid pguidEventContext);
        int GetMasterVolumeLevel(ref float pfLevelDB);
        int GetMasterVolumeLevelScalar(ref float pfLevel);
        int SetChannelVolumeLevel(uint nChannel, float fLevelDB, Guid pguidEventContext);
        int SetChannelVolumeLevelScalar(uint nChannel, float fLevel, Guid pguidEventContext);
        int GetChannelVolumeLevel(uint nChannel, ref float pfLevelDB);
        int GetChannelVolumeLevelScalar(uint nChannel, ref float pfLevel);
        [PreserveSig]
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, Guid pguidEventContext);
        [PreserveSig]
        int GetMute(out bool pbMute);
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
    }

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        int NotUsed1();
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppEndpoint);
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    public class Volume {
        public static void SetMute(bool mute) {
            var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            IMMDevice dev;
            int hr = enumerator.GetDefaultAudioEndpoint(/*eRender*/0, /*eMultimedia*/1, out dev);
            if (hr != 0 || dev == null) {
                throw new InvalidOperationException("No default audio render endpoint (HRESULT " + hr + ")");
            }
            var iidEpv = typeof(IAudioEndpointVolume).GUID;
            object epvObj;
            Marshal.ThrowExceptionForHR(dev.Activate(ref iidEpv, 1 /*CLSCTX_INPROC_SERVER*/, IntPtr.Zero, out epvObj));
            var epv = (IAudioEndpointVolume)epvObj;
            Marshal.ThrowExceptionForHR(epv.SetMute(mute, Guid.Empty));
        }
    }
}
'@
    }

    [RWWAudio.Volume]::SetMute($true)
    Write-Log "System audio muted."
    Write-Log "=== Install-Mute finished. Overall success: True ==="
    exit 0
} catch {
    $msg = $_.Exception.Message
    if ($msg -match 'No default audio render endpoint') {
        Write-Log "No default audio endpoint found -- nothing to mute (common in a SYSTEM/RDP context with no active audio session)." 'WARN'
        exit 4
    }
    Write-Log "Muting failed: $msg" 'ERROR'
    Write-Log "=== Install-Mute finished. Overall success: False ==="
    exit 1
}
