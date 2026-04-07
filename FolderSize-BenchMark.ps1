# FolderSize-BenchMark.ps1
# Benchmarks different methods of calculating directory size

$targetPath = "C:\Users\"  # Change this to your target directory

Write-Host "=== Directory Size Benchmark ===" -ForegroundColor Cyan
Write-Host "Target: $targetPath"
Write-Host "Date:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ("=" * 50)
Write-Host ""

$results = @()

# ---------------------------------------------------------------------------
# Method 1: Get-ChildItem with Measure-Object
# ---------------------------------------------------------------------------
Write-Host "[1] Get-ChildItem + Measure-Object" -ForegroundColor Yellow

$timer = [System.Diagnostics.Stopwatch]::StartNew()
$size = (Get-ChildItem -Path $targetPath -Recurse -File -Force -ErrorAction SilentlyContinue |
    Measure-Object -Property Length -Sum).Sum
$timer.Stop()

Write-Host "    Size:  $([math]::Round($size / 1GB, 2)) GB"
Write-Host "    Time:  $($timer.Elapsed.TotalSeconds.ToString('F3')) seconds"
Write-Host ""

$results += [PSCustomObject]@{
    Method = "Get-ChildItem + Measure-Object"
    SizeGB = [math]::Round($size / 1GB, 2)
    Seconds = $timer.Elapsed.TotalSeconds
}

# ---------------------------------------------------------------------------
# Method 2: ComObject Scripting.FileSystemObject
# ---------------------------------------------------------------------------
Write-Host "[2] ComObject Scripting.FileSystemObject" -ForegroundColor Yellow

function Get-FSOFolderSize {
    param($fso, $path)
    $size = 0
    try {
        $folder = $fso.GetFolder($path)
        foreach ($file in $folder.Files) {
            try { $size += $file.Size } catch {}
        }
        foreach ($subfolder in $folder.SubFolders) {
            try { $size += Get-FSOFolderSize $fso $subfolder.Path } catch {}
        }
    } catch {}
    return $size
}

$timer = [System.Diagnostics.Stopwatch]::StartNew()
$fso = New-Object -ComObject Scripting.FileSystemObject
$size = Get-FSOFolderSize $fso $targetPath
$timer.Stop()

$null = [System.Runtime.InteropServices.Marshal]::ReleaseComObject($fso)

Write-Host "    Size:  $([math]::Round($size / 1GB, 2)) GB"
Write-Host "    Time:  $($timer.Elapsed.TotalSeconds.ToString('F3')) seconds"
Write-Host ""

$results += [PSCustomObject]@{
    Method = "ComObject Scripting.FileSystemObject"
    SizeGB = [math]::Round($size / 1GB, 2)
    Seconds = $timer.Elapsed.TotalSeconds
}

# ---------------------------------------------------------------------------
# Method 3: .NET EnumerateFiles (manual recursion)
# ---------------------------------------------------------------------------
Write-Host "[3] .NET EnumerateFiles (manual recursion)" -ForegroundColor Yellow

function Get-EnumerateFilesSize {
    param([string]$path)
    $size = [long]0
    try {
        foreach ($file in [System.IO.Directory]::EnumerateFiles($path)) {
            try { $size += ([System.IO.FileInfo]::new($file)).Length } catch {}
        }
        foreach ($dir in [System.IO.Directory]::EnumerateDirectories($path)) {
            try { $size += Get-EnumerateFilesSize $dir } catch {}
        }
    } catch {}
    return $size
}

$timer = [System.Diagnostics.Stopwatch]::StartNew()
$size = Get-EnumerateFilesSize $targetPath
$timer.Stop()

Write-Host "    Size:  $([math]::Round($size / 1GB, 2)) GB"
Write-Host "    Time:  $($timer.Elapsed.TotalSeconds.ToString('F3')) seconds"
Write-Host ""

$results += [PSCustomObject]@{
    Method = ".NET EnumerateFiles (manual recursion)"
    SizeGB = [math]::Round($size / 1GB, 2)
    Seconds = $timer.Elapsed.TotalSeconds
}

# ---------------------------------------------------------------------------
# Method 4: .NET DirectoryInfo (manual recursion)
# ---------------------------------------------------------------------------
Write-Host "[4] .NET DirectoryInfo (manual recursion)" -ForegroundColor Yellow

function Get-DirectoryInfoSize {
    param([System.IO.DirectoryInfo]$dir)
    $size = [long]0
    try {
        foreach ($file in $dir.EnumerateFiles()) {
            try { $size += $file.Length } catch {}
        }
        foreach ($subdir in $dir.EnumerateDirectories()) {
            try { $size += Get-DirectoryInfoSize $subdir } catch {}
        }
    } catch {}
    return $size
}

$timer = [System.Diagnostics.Stopwatch]::StartNew()
$size = Get-DirectoryInfoSize ([System.IO.DirectoryInfo]::new($targetPath))
$timer.Stop()

Write-Host "    Size:  $([math]::Round($size / 1GB, 2)) GB"
Write-Host "    Time:  $($timer.Elapsed.TotalSeconds.ToString('F3')) seconds"
Write-Host ""

$results += [PSCustomObject]@{
    Method = ".NET DirectoryInfo (manual recursion)"
    SizeGB = [math]::Round($size / 1GB, 2)
    Seconds = $timer.Elapsed.TotalSeconds
}

# ---------------------------------------------------------------------------
# Method 5: robocopy (list mode, no copy)
# ---------------------------------------------------------------------------
Write-Host "[5] robocopy /L (list-only mode)" -ForegroundColor Yellow

$timer = [System.Diagnostics.Stopwatch]::StartNew()
$output = robocopy $targetPath "C:\__NULL__" /L /S /NJH /BYTES /NFL /NDL /NC /NS /R:0 /W:0 2>&1
$bytesLine = $output | Where-Object { $_ -match "Bytes :" }
$size = 0
if ($bytesLine -match "Bytes :\s+([\d.]+)") {
    $size = [double]$Matches[1]
}
$timer.Stop()

Write-Host "    Size:  $([math]::Round($size / 1GB, 2)) GB"
Write-Host "    Time:  $($timer.Elapsed.TotalSeconds.ToString('F3')) seconds"
Write-Host ""

$results += [PSCustomObject]@{
    Method = "robocopy /L"
    SizeGB = [math]::Round($size / 1GB, 2)
    Seconds = $timer.Elapsed.TotalSeconds
}

# ---------------------------------------------------------------------------
# Method 6: CMD dir /s
# ---------------------------------------------------------------------------
Write-Host "[6] CMD dir /s" -ForegroundColor Yellow

$timer = [System.Diagnostics.Stopwatch]::StartNew()
$output = cmd /c "dir /s /a /-c `"$targetPath`"" 2>&1
$lastLines = $output | Select-Object -Last 3
$size = 0
foreach ($line in $lastLines) {
    if ($line -match "(\d+)\s+bytes$") {
        $size = [double]$Matches[1]
        break
    }
}
$timer.Stop()

Write-Host "    Size:  $([math]::Round($size / 1GB, 2)) GB"
Write-Host "    Time:  $($timer.Elapsed.TotalSeconds.ToString('F3')) seconds"
Write-Host ""

$results += [PSCustomObject]@{
    Method = "CMD dir /s"
    SizeGB = [math]::Round($size / 1GB, 2)
    Seconds = $timer.Elapsed.TotalSeconds
}

# ---------------------------------------------------------------------------
# Method 7: Win32 FindFirstFile/FindNextFile via P/Invoke
# ---------------------------------------------------------------------------
Write-Host "[7] Win32 FindFirstFile/FindNextFile (P/Invoke)" -ForegroundColor Yellow

if (-not ([System.Management.Automation.PSTypeName]'Win32FileSize').Type) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class Win32FileSize
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WIN32_FIND_DATA
    {
        public uint dwFileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftLastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftLastWriteTime;
        public uint nFileSizeHigh;
        public uint nFileSizeLow;
        public uint dwReserved0;
        public uint dwReserved1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string cFileName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)]
        public string cAlternateFileName;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr FindFirstFile(string lpFileName, out WIN32_FIND_DATA lpFindFileData);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool FindNextFile(IntPtr hFindFile, out WIN32_FIND_DATA lpFindFileData);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool FindClose(IntPtr hFindFile);

    private static readonly IntPtr INVALID_HANDLE = new IntPtr(-1);
    private const uint FILE_ATTRIBUTE_DIRECTORY = 0x10;

    public static long GetDirectorySize(string path)
    {
        long size = 0;
        WIN32_FIND_DATA findData;
        IntPtr handle = FindFirstFile(path + @"\*", out findData);
        if (handle == INVALID_HANDLE) return 0;

        try
        {
            do
            {
                if (findData.cFileName == "." || findData.cFileName == "..") continue;

                string fullPath = path + @"\" + findData.cFileName;

                if ((findData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0)
                {
                    size += GetDirectorySize(fullPath);
                }
                else
                {
                    size += ((long)findData.nFileSizeHigh << 32) | findData.nFileSizeLow;
                }
            } while (FindNextFile(handle, out findData));
        }
        finally
        {
            FindClose(handle);
        }
        return size;
    }
}
"@
}

$timer = [System.Diagnostics.Stopwatch]::StartNew()
$size = [Win32FileSize]::GetDirectorySize($targetPath)
$timer.Stop()

Write-Host "    Size:  $([math]::Round($size / 1GB, 2)) GB"
Write-Host "    Time:  $($timer.Elapsed.TotalSeconds.ToString('F3')) seconds"
Write-Host ""

$results += [PSCustomObject]@{
    Method = "Win32 FindFirstFile (P/Invoke)"
    SizeGB = [math]::Round($size / 1GB, 2)
    Seconds = $timer.Elapsed.TotalSeconds
}

# ---------------------------------------------------------------------------
# Method 8: .NET EnumerationOptions (IgnoreInaccessible)
# ---------------------------------------------------------------------------
Write-Host "[8] .NET EnumerationOptions (IgnoreInaccessible)" -ForegroundColor Yellow

$timer = [System.Diagnostics.Stopwatch]::StartNew()
$enumOpts = [System.IO.EnumerationOptions]::new()
$enumOpts.RecurseSubdirectories = $true
$enumOpts.IgnoreInaccessible = $true
$enumOpts.AttributesToSkip = [System.IO.FileAttributes]::ReparsePoint
$size = [long]0
foreach ($file in [System.IO.DirectoryInfo]::new($targetPath).EnumerateFiles("*", $enumOpts)) {
    $size += $file.Length
}
$timer.Stop()

Write-Host "    Size:  $([math]::Round($size / 1GB, 2)) GB"
Write-Host "    Time:  $($timer.Elapsed.TotalSeconds.ToString('F3')) seconds"
Write-Host ""

$results += [PSCustomObject]@{
    Method = ".NET EnumerationOptions"
    SizeGB = [math]::Round($size / 1GB, 2)
    Seconds = $timer.Elapsed.TotalSeconds
}

# ---------------------------------------------------------------------------
# Method 9: C# compiled inline (tight loop, no pipeline)
# ---------------------------------------------------------------------------
Write-Host "[9] C# compiled inline (no pipeline overhead)" -ForegroundColor Yellow

if (-not ([System.Management.Automation.PSTypeName]'ManagedDirSize').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.IO;

public class ManagedDirSize
{
    public static long Calculate(string path)
    {
        long size = 0;
        var opts = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,
            AttributesToSkip = FileAttributes.ReparsePoint
        };
        foreach (var fi in new DirectoryInfo(path).EnumerateFiles("*", opts))
        {
            size += fi.Length;
        }
        return size;
    }
}
"@
}

$timer = [System.Diagnostics.Stopwatch]::StartNew()
$size = [ManagedDirSize]::Calculate($targetPath)
$timer.Stop()

Write-Host "    Size:  $([math]::Round($size / 1GB, 2)) GB"
Write-Host "    Time:  $($timer.Elapsed.TotalSeconds.ToString('F3')) seconds"
Write-Host ""

$results += [PSCustomObject]@{
    Method = "C# compiled inline"
    SizeGB = [math]::Round($size / 1GB, 2)
    Seconds = $timer.Elapsed.TotalSeconds
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ("=" * 50)
Write-Host "Summary (sorted by speed)" -ForegroundColor Cyan
Write-Host ("=" * 50)
$results | Sort-Object Seconds | Format-Table -AutoSize -Property @(
    @{ Label = "Method"; Expression = { $_.Method }; Width = 45 }
    @{ Label = "Size (GB)"; Expression = { $_.SizeGB }; Alignment = "Right" }
    @{ Label = "Time (sec)"; Expression = { $_.Seconds.ToString("F3") }; Alignment = "Right" }
)
