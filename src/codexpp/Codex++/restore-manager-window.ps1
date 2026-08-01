[CmdletBinding()]
param(
    [ValidateRange(250, 5000)]
    [int]$TimeoutMs = 1200,

    [ValidateRange(50, 500)]
    [int]$PollMs = 100,

    [switch]$WaitForProcess,

    [string]$ProcessName = 'codex-plus-plus-manager'
)

$ErrorActionPreference = 'Stop'

try {
    if (-not ('CodexManagerWindowApi' -as [type])) {
        Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class CodexManagerWindowApi
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int command);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);

    public static IntPtr[] GetWindowsForProcess(int processId)
    {
        var handles = new List<IntPtr>();
        EnumWindows(delegate (IntPtr hWnd, IntPtr lParam)
        {
            uint ownerPid;
            GetWindowThreadProcessId(hWnd, out ownerPid);
            if (ownerPid == (uint)processId)
            {
                handles.Add(hWnd);
            }
            return true;
        }, IntPtr.Zero);
        return handles.ToArray();
    }
}
'@
    }

    function Get-WindowSnapshot {
        param(
            [IntPtr]$Handle,
            [int]$ProcessId
        )

        $rect = [CodexManagerWindowApi+RECT]::new()
        if (-not [CodexManagerWindowApi]::GetWindowRect($Handle, [ref]$rect)) {
            return $null
        }

        $title = [Text.StringBuilder]::new(256)
        [void][CodexManagerWindowApi]::GetWindowText($Handle, $title, $title.Capacity)
        [pscustomobject]@{
            Handle = $Handle
            ProcessId = $ProcessId
            Title = $title.ToString()
            Visible = [CodexManagerWindowApi]::IsWindowVisible($Handle)
            Minimized = [CodexManagerWindowApi]::IsIconic($Handle)
            Left = $rect.Left
            Top = $rect.Top
            Right = $rect.Right
            Bottom = $rect.Bottom
            Width = $rect.Right - $rect.Left
            Height = $rect.Bottom - $rect.Top
            Area = [math]::Max(0, $rect.Right - $rect.Left) * [math]::Max(0, $rect.Bottom - $rect.Top)
        }
    }

    function Get-ManagerState {
        $processes = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
        $windows = @()
        foreach ($process in $processes) {
            $handles = @([CodexManagerWindowApi]::GetWindowsForProcess($process.Id))
            if ($handles.Count -eq 0 -and $process.MainWindowHandle -ne [IntPtr]::Zero) {
                $handles = @($process.MainWindowHandle)
            }
            foreach ($handle in $handles) {
                if ($handle -eq [IntPtr]::Zero) {
                    continue
                }
                $snapshot = Get-WindowSnapshot -Handle $handle -ProcessId $process.Id
                if ($null -ne $snapshot) {
                    $windows += $snapshot
                }
            }
        }
        [pscustomobject]@{
            ProcessFound = $processes.Count -gt 0
            Processes = $processes
            Windows = $windows
        }
    }

    function Test-NormalWindow {
        param([object]$Window)

        return ($null -ne $Window -and $Window.Visible -and (-not $Window.Minimized) -and $Window.Width -ge 300 -and $Window.Height -ge 300 -and -not [string]::IsNullOrWhiteSpace($Window.Title))
    }

    function Select-ManagerWindow {
        param([object[]]$Windows)

        @($Windows | Where-Object { Test-NormalWindow -Window $_ } | Sort-Object @{ Expression = { -1 * $_.Area } } | Select-Object -First 1)
    }

    function Restore-ManagerWindow {
        param([object]$Window)

        if (-not (Test-NormalWindow -Window $Window)) {
            return $false
        }

        [void][CodexManagerWindowApi]::ShowWindow($Window.Handle, 9)
        $foreground = [CodexManagerWindowApi]::SetForegroundWindow($Window.Handle)
        $topMost = [CodexManagerWindowApi]::BringWindowToTop($Window.Handle)
        $after = Get-WindowSnapshot -Handle $Window.Handle -ProcessId $Window.ProcessId
        return (Test-NormalWindow -Window $after)
    }

    function Close-InvalidManagerProcesses {
        param(
            [object[]]$Processes,
            [ValidateRange(250, 1500)]
            [int]$WaitMs = 1000
        )

        $deadline = [Environment]::TickCount64 + $WaitMs
        foreach ($process in $Processes) {
            try {
                [void]$process.Refresh()
                if (-not $process.HasExited) {
                    [void]$process.CloseMainWindow()
                }
            }
            catch {
            }
        }

        do {
            $alive = @()
            foreach ($process in $Processes) {
                try {
                    [void]$process.Refresh()
                    if (-not $process.HasExited) {
                        $alive += $process
                    }
                }
                catch {
                }
            }
            if ($alive.Count -eq 0) {
                return [pscustomobject]@{ AllExited = $true; Alive = @() }
            }
            if ([Environment]::TickCount64 -ge $deadline) {
                return [pscustomobject]@{ AllExited = $false; Alive = $alive }
            }
            Start-Sleep -Milliseconds ([math]::Min($PollMs, 100))
        } while ($true)
    }

    $deadline = [Environment]::TickCount64 + $TimeoutMs
    do {
        $state = Get-ManagerState
        $candidate = Select-ManagerWindow -Windows $state.Windows
        if ($null -ne $candidate) {
            if (Restore-ManagerWindow -Window $candidate) {
                exit 0
            }
            exit 2
        }

        if ([Environment]::TickCount64 -ge $deadline) {
            break
        }
        Start-Sleep -Milliseconds ([math]::Min($PollMs, [math]::Max(1, $TimeoutMs)))
    } while ($true)

    $finalState = Get-ManagerState
    if (-not $finalState.ProcessFound) {
        exit 1
    }

    $closeResult = Close-InvalidManagerProcesses -Processes $finalState.Processes -WaitMs ([math]::Min(1000, [math]::Max(250, $TimeoutMs)))
    if ($closeResult.AllExited) {
        exit 1
    }

    $afterCloseState = Get-ManagerState
    $candidate = Select-ManagerWindow -Windows $afterCloseState.Windows
    if ($null -ne $candidate) {
        if (Restore-ManagerWindow -Window $candidate) {
            exit 0
        }
    }
    if ($afterCloseState.ProcessFound) {
        exit 2
    }
    exit 1
}
catch {
    exit 3
}
