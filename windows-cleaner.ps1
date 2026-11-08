<#
  Windows Cleaner - free up disk space and RAM on Windows (made with developers in mind).
    * Clean caches: npm, Yarn, pnpm, Bun, Composer, pip, uv, Go, Gradle, Maven, Flutter,
      NuGet, Cargo, VS Code, browsers, Temp, crash dumps, Windows Update, Recycle Bin
    * Docker: pick containers, images, volumes, build cache or networks to remove,
      clean everything unused, do a full reset, or shrink the WSL / Docker Desktop disk
    * Find rarely used & large apps, and the largest folders / app data
    * Uninstall apps with their own uninstaller, then move leftover files to the Recycle Bin
    * Update apps with winget
    * RAM: see memory load and the apps using the most memory, quit them, or shut down WSL

  Interface: English or Bahasa Indonesia (follows your Windows display language,
  switchable from the menu or with -Lang en|id).

  Usage (PowerShell):
    .\windows-cleaner.ps1              # interactive menu
    .\windows-cleaner.ps1 -DryRun      # show what would be deleted, delete nothing
    .\windows-cleaner.ps1 -Lang id     # force Bahasa Indonesia (or: en)

  Works without admin rights. Run as administrator to also clean the Windows Update cache,
  Windows\Temp and Delivery Optimization files, and to shrink WSL disks.
  Everything is shown first and needs confirmation.
  Never touched: Desktop, Documents, Downloads, Pictures, Music, Videos, OneDrive, your code,
  Docker volumes (unless you pick them and type DELETE). Leftover files of uninstalled apps
  go to the Recycle Bin, so they can be restored.

  https://github.com/ahmadrio/windows-cleaner - MIT License
#>
param(
  [Alias('n')][switch]$DryRun,
  [string]$Lang = '',
  [Alias('h')][switch]$Help
)

$script:WC_VERSION = '1.0'
$script:UNUSED_DAYS = 90
$script:DRY = [bool]$DryRun
$script:SelfPath = $PSCommandPath
$script:IsWin = ($env:OS -eq 'Windows_NT')
$script:H = [Environment]::GetFolderPath('UserProfile')
$script:LA = [Environment]::GetFolderPath('LocalApplicationData')
$script:RA = [Environment]::GetFolderPath('ApplicationData')
$script:WINDIR = $env:windir
$script:ConfDir = Join-Path $script:RA 'windows-cleaner'
$script:LangFile = Join-Path $script:ConfDir 'lang'
$script:ANSWER = ''
$script:SEL = @()

$script:IsAdmin = $false
try {
  $wid = [Security.Principal.WindowsIdentity]::GetCurrent()
  $script:IsAdmin = (New-Object Security.Principal.WindowsPrincipal $wid).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $script:IsAdmin = $false }

# ------------------------------------------------------------------ language
$l = $Lang
if (-not $l) { $l = $env:WINDOWS_CLEANER_LANG }
if (-not $l -and (Test-Path -LiteralPath $script:LangFile)) {
  $l = [string](Get-Content -LiteralPath $script:LangFile -TotalCount 1 -ErrorAction SilentlyContinue)
}
if (-not $l) { try { $l = (Get-UICulture).Name } catch { $l = '' } }
if ($l -match '^(id|in)([-_]|$)|^indo') { $script:UiLang = 'id' } else { $script:UiLang = 'en' }

function T([string]$id, [string]$en) { if ($script:UiLang -eq 'id') { return $id } return $en }

function Save-Lang {
  try {
    if (-not (Test-Path -LiteralPath $script:ConfDir)) { [void](New-Item -ItemType Directory -Path $script:ConfDir -Force) }
    Set-Content -LiteralPath $script:LangFile -Value $script:UiLang -Encoding ASCII
  } catch { }
}

function Show-Usage {
  Write-Host "Windows Cleaner v$($script:WC_VERSION)"
  Write-Host 'Usage:  .\windows-cleaner.ps1 [-DryRun] [-Lang en|id]'
  Write-Host '  -DryRun, -n    Show what would be deleted without deleting anything'
  Write-Host '                 (Tampilkan yang akan dihapus tanpa menghapus apa pun)'
  Write-Host '  -Lang en|id    Interface language / Bahasa tampilan (default: Windows language)'
  Write-Host '  -Help, -h      This help / Bantuan ini'
}

# ------------------------------------------------------------------ output helpers
$script:IsTty = $true
try { $script:IsTty = -not [Console]::IsOutputRedirected } catch { }

function Say([string]$t = '') { Write-Host $t }
function Info([string]$t) { Write-Host '> ' -ForegroundColor Cyan -NoNewline; Write-Host $t }
function Ok([string]$t) { Write-Host '+ ' -ForegroundColor Green -NoNewline; Write-Host $t }
function Warn([string]$t) { Write-Host '! ' -ForegroundColor Yellow -NoNewline; Write-Host $t }
function Err([string]$t) { Write-Host 'x ' -ForegroundColor Red -NoNewline; Write-Host $t }
function Dim([string]$t) { Write-Host $t -ForegroundColor DarkGray }
function Seg([string]$t, [string]$color = '') {
  if ($color) { Write-Host $t -ForegroundColor $color -NoNewline } else { Write-Host $t -NoNewline }
}
function Bold([string]$t) { Write-Host $t -ForegroundColor White }

function Get-ConWidth { try { $w = [Console]::WindowWidth; if ($w -gt 20) { return $w } } catch { } return 100 }
function Show-Progress([string]$t) {
  if (-not $script:IsTty) { return }
  $w = Get-ConWidth
  $s = '  ' + $t
  if ($s.Length -gt $w - 1) { $s = $s.Substring(0, $w - 1) }
  [Console]::Write("`r" + $s.PadRight($w - 1))
}
function Clear-Progress {
  if (-not $script:IsTty) { return }
  $w = Get-ConWidth
  [Console]::Write("`r" + (' ' * ($w - 1)) + "`r")
}

function Cut([string]$s, [int]$n) {
  if ($null -eq $s) { return ''.PadRight($n) }
  if ($s.Length -gt $n) { return $s.Substring(0, $n - 1) + '~' }
  return $s.PadRight($n)
}

# ------------------------------------------------------------------ input helpers
function Read-Answer([string]$Prompt = '', [string]$Color = '') {
  if ($Prompt) { Seg $Prompt $Color }
  $a = [Console]::ReadLine()
  if ($null -eq $a) { Write-Host ''; $script:ANSWER = ''; return $false }
  $script:ANSWER = $a.Trim()
  return $true
}
function Confirm-Yes([string]$Prompt) {
  if (-not (Read-Answer "$Prompt [y/N] ")) { return $false }
  return ($script:ANSWER -match '^(y|ya|yes)$')
}
function Confirm-Word([string]$Word) {
  Seg ('  ' + (T 'Ketik ' 'Type '))
  Seg $Word 'White'
  if (-not (Read-Answer (T ' untuk lanjut (lainnya = batal): ' ' to continue (anything else cancels): '))) { return $false }
  return ($script:ANSWER -ceq $Word)
}
function Wait-Menu { [void](Read-Answer ('  ' + (T 'Enter untuk kembali ke menu...' 'Press Enter to return to the menu...')) 'DarkGray') }
function Show-Cancelled { Info (T 'Batal.' 'Cancelled.') }

function Test-Cmd([string]$n) { return [bool](Get-Command $n -ErrorAction SilentlyContinue) }

function Format-Size([double]$b) {
  if ($b -lt 0) { return '?' }
  if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
  if ($b -ge 1MB) { return ('{0:N0} MB' -f ($b / 1MB)) }
  return ('{0:N0} KB' -f ($b / 1KB))
}

function Format-Tilde([string]$p) {
  if ($p -and $script:H -and $p.StartsWith($script:H + '\', [StringComparison]::OrdinalIgnoreCase)) {
    return '~' + $p.Substring($script:H.Length)
  }
  return $p
}

# Picks like "1 3,5" or "2-6" -> $script:SEL (0-based indexes)
function Read-Selection([string]$s, [int]$max) {
  $list = New-Object System.Collections.Generic.List[int]
  foreach ($tok in ($s -split '[,\s]+')) {
    if (-not $tok) { continue }
    $from = 0; $to = 0
    if ($tok -match '^(\d{1,6})-(\d{1,6})$') { $from = [int]$matches[1]; $to = [int]$matches[2] }
    elseif ($tok -match '^\d{1,6}$') { $from = [int]$tok; $to = $from }
    else { Warn ((T 'Diabaikan: ' 'Ignored: ') + "'$tok'"); continue }
    if ($from -gt $to) { $x = $from; $from = $to; $to = $x }
    for ($i = $from; $i -le $to; $i++) {
      if ($i -lt 1 -or $i -gt $max) { Warn ((T 'Nomor di luar daftar: ' 'Not in the list: ') + $i); continue }
      if (-not $list.Contains($i - 1)) { $list.Add($i - 1) }
    }
  }
  $script:SEL = $list.ToArray()
}
function Select-All([int]$n) { $script:SEL = @(); if ($n -gt 0) { $script:SEL = @(0..($n - 1)) } }

# ------------------------------------------------------------------ fast file helpers (C#)
$wcCs = @'
using System;
using System.IO;
using System.Collections.Generic;
public static class WcFs {
  // Total size of a file or folder. Junctions/symlinks are not followed; unreadable parts are skipped.
  public static long Size(string path) {
    long total = 0;
    try { FileInfo f = new FileInfo(path); if (f.Exists) return f.Length; } catch { }
    if (!Directory.Exists(path)) return 0;
    Stack<string> st = new Stack<string>();
    st.Push(path);
    while (st.Count > 0) {
      string d = st.Pop();
      try {
        foreach (FileSystemInfo e in new DirectoryInfo(d).EnumerateFileSystemInfos()) {
          try {
            if ((e.Attributes & FileAttributes.Directory) != 0) {
              if ((e.Attributes & FileAttributes.ReparsePoint) == 0) st.Push(e.FullName);
            } else { total += ((FileInfo)e).Length; }
          } catch { }
        }
      } catch { }
    }
    return total;
  }
  static List<FileSystemInfo> List(DirectoryInfo d) {
    List<FileSystemInfo> l = new List<FileSystemInfo>();
    try { foreach (FileSystemInfo e in d.EnumerateFileSystemInfos()) l.Add(e); } catch { }
    return l;
  }
  // Deletes a file or folder. A junction/symlink is removed itself, never its target.
  // Returns how many items could not be deleted (in use, no permission).
  public static int Delete(string path) {
    try {
      FileAttributes a = File.GetAttributes(path);
      if ((a & FileAttributes.Directory) != 0) return DeleteEntry(new DirectoryInfo(path));
      return DeleteEntry(new FileInfo(path));
    } catch { return 1; }
  }
  public static int DeleteContents(string dir) {
    DirectoryInfo di = new DirectoryInfo(dir);
    if (!di.Exists) return 0;
    int fail = 0;
    foreach (FileSystemInfo e in List(di)) fail += DeleteEntry(e);
    return fail;
  }
  static int DeleteEntry(FileSystemInfo e) {
    try {
      if ((e.Attributes & FileAttributes.ReadOnly) != 0) e.Attributes = e.Attributes & ~FileAttributes.ReadOnly;
      if ((e.Attributes & FileAttributes.Directory) != 0) {
        if ((e.Attributes & FileAttributes.ReparsePoint) != 0) { Directory.Delete(e.FullName, false); return 0; }
        int f = 0;
        foreach (FileSystemInfo c in List((DirectoryInfo)e)) f += DeleteEntry(c);
        if (f == 0) Directory.Delete(e.FullName, false);
        return f;
      }
      File.Delete(e.FullName);
      return 0;
    } catch { return 1; }
  }
}
'@
$script:FsOk = $false
try {
  if (-not ('WcFs' -as [type])) { Add-Type -TypeDefinition $wcCs -Language CSharp -ErrorAction Stop }
  $script:FsOk = $true
} catch { $script:FsOk = $false }

function Get-PathSize([string]$p) {
  if (-not $p -or -not (Test-Path -LiteralPath $p)) { return [double]0 }
  if ($script:FsOk) { return [double][WcFs]::Size($p) }
  $s = (Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
  if ($s) { return [double]$s }
  return [double]0
}
function Get-PathsSize([string[]]$paths) {
  $t = [double]0
  foreach ($p in $paths) { if ($p) { $t += Get-PathSize $p } }
  return $t
}

# ------------------------------------------------------------------ guarded deletion
function Get-Full([string]$p) {
  if (-not $p) { return '' }
  try { return [IO.Path]::GetFullPath($p).TrimEnd('\') } catch { return '' }
}
function Test-Under([string]$p, [string]$root) {
  if (-not $p -or -not $root) { return $false }
  return $p.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)
}

$script:AllowedRoots = @()
foreach ($r in @($script:H, $script:LA, $script:RA, $env:TEMP, "$($script:WINDIR)\Temp", "$($script:WINDIR)\SoftwareDistribution\Download")) {
  $f = Get-Full $r
  if ($f) { $script:AllowedRoots += $f }
}
# Folders that are never deleted themselves (their contents may be, e.g. Temp).
$script:Protected = @()
foreach ($r in @($script:H, $script:LA, $script:RA, "$($script:H)\AppData", "$($script:H)\AppData\LocalLow",
    "$($script:LA)\Programs", "$($script:LA)\Microsoft", "$($script:RA)\Microsoft", "$($script:LA)\Packages",
    "$($script:H)\go", "$($script:H)\.config", "$($script:H)\.local", "$($script:H)\.cargo", "$($script:H)\.gradle",
    "$($script:H)\.m2", "$($script:H)\.nuget", "$($script:H)\.docker", "$($script:H)\.wsl", "$($script:H)\.vscode")) {
  $f = Get-Full $r
  if ($f) { $script:Protected += $f }
}
# Personal folders: nothing inside them is ever touched.
$script:Personal = @()
$pers = @("$($script:H)\Desktop", "$($script:H)\Documents", "$($script:H)\Downloads", "$($script:H)\Pictures",
  "$($script:H)\Music", "$($script:H)\Videos", "$($script:H)\Favorites", "$($script:H)\.ssh", "$($script:H)\.gnupg",
  $env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer)
foreach ($k in 'Desktop', 'MyDocuments', 'MyPictures', 'MyMusic', 'MyVideos') {
  try { $pers += [Environment]::GetFolderPath($k) } catch { }
}
if ($script:H -and (Test-Path -LiteralPath $script:H)) {
  $pers += @(Get-ChildItem -LiteralPath $script:H -Directory -Force -Filter 'OneDrive*' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}
foreach ($r in $pers) { $f = Get-Full $r; if ($f -and $script:Personal -notcontains $f) { $script:Personal += $f } }

function Test-SafePath([string]$p, [switch]$AllowRoot) {
  $f = Get-Full $p
  if (-not $f) { return $false }
  $ok = $false
  foreach ($r in $script:AllowedRoots) {
    if ((Test-Under $f $r) -or ($AllowRoot -and $f -ieq $r)) { $ok = $true; break }
  }
  if (-not $ok) { return $false }
  foreach ($x in $script:Protected) { if ($f -ieq $x) { return $false } }
  foreach ($x in $script:Personal) { if ($f -ieq $x -or (Test-Under $f $x)) { return $false } }
  return $true
}

function Test-ReparsePoint([string]$p) {
  try { $i = Get-Item -LiteralPath $p -Force -ErrorAction Stop; return [bool]($i.Attributes -band [IO.FileAttributes]::ReparsePoint) }
  catch { return $false }
}

function Remove-Entry([string]$p) {  # permanent delete of one file/folder, returns failures
  if ($script:FsOk) { return [WcFs]::Delete($p) }
  try {
    if (Test-Path -LiteralPath $p -PathType Container) {
      # rd /s never follows junctions, unlike Remove-Item -Recurse in Windows PowerShell 5.1
      & $env:ComSpec /d /c "rd /s /q `"$p`"" 2>$null
    } else { Remove-Item -LiteralPath $p -Force -ErrorAction Stop }
  } catch { }
  if (Test-Path -LiteralPath $p) { return 1 }
  return 0
}

function Clear-Folder([string]$d) {  # delete the CONTENTS of a folder (the folder itself stays)
  if (-not $d -or -not (Test-Path -LiteralPath $d -PathType Container)) { return }
  if (-not (Test-SafePath $d -AllowRoot) -or (Test-ReparsePoint $d)) {
    Warn ((T 'Dilewati (lokasi tidak diizinkan): ' 'Skipped (location not allowed): ') + $d); return
  }
  if ($script:DRY) { Dim ('  [dry-run] ' + (T 'hapus isi: ' 'delete contents of: ') + (Format-Tilde $d)); return }
  $fail = 0
  if ($script:FsOk) { $fail = [WcFs]::DeleteContents($d) }
  else {
    foreach ($c in @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue)) { $fail += Remove-Entry $c.FullName }
  }
  if ($fail -gt 0) { Dim ('  ' + (T "$fail item dilewati (sedang dipakai atau dikunci)." "$fail item(s) skipped (in use or locked).")) }
}

function Get-OldItems([string]$d, [int]$hours) {
  if (-not $d -or -not (Test-Path -LiteralPath $d -PathType Container)) { return @() }
  $cut = (Get-Date).AddHours(-$hours)
  return @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut })
}
function Clear-OldItems([string]$d, [int]$hours) {  # temp folders: only items not changed for $hours
  if (-not (Test-SafePath $d -AllowRoot)) { Warn ((T 'Dilewati (lokasi tidak diizinkan): ' 'Skipped (location not allowed): ') + $d); return }
  $items = Get-OldItems $d $hours
  if ($script:DRY) { Dim ('  [dry-run] ' + (T "hapus $($items.Count) item lama di: " "delete $($items.Count) old item(s) in: ") + (Format-Tilde $d)); return }
  $fail = 0
  foreach ($i in $items) { $fail += Remove-Entry $i.FullName }
  if ($fail -gt 0) { Dim ('  ' + (T "$fail item dilewati (sedang dipakai atau dikunci)." "$fail item(s) skipped (in use or locked).")) }
}

function Move-ToRecycleBin([string[]]$Paths) {  # recoverable delete. Returns $false if something failed.
  $paths2 = @($Paths | Where-Object { $_ })
  if ($paths2.Count -eq 0) { return $true }
  if ($script:DRY) {
    foreach ($p in $paths2) { Dim ('  [dry-run] ' + (T 'pindah ke Recycle Bin: ' 'move to Recycle Bin: ') + (Format-Tilde $p)) }
    return $true
  }
  try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop } catch { Err (T 'Recycle Bin tidak tersedia.' 'The Recycle Bin is not available.'); return $false }
  $ui = [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs
  $rb = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
  $fail = $false
  foreach ($p in $paths2) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    if (-not (Test-SafePath $p)) { Warn ((T 'Dilewati (lokasi tidak diizinkan): ' 'Skipped (location not allowed): ') + $p); $fail = $true; continue }
    try {
      if (Test-Path -LiteralPath $p -PathType Container) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($p, $ui, $rb) }
      else { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, $ui, $rb) }
    } catch {
      Err ((T 'Gagal memindahkan: ' "Couldn't move: ") + (Format-Tilde $p)); $fail = $true
    }
  }
  if ($fail) { Dim ('  ' + (T 'Item yang gagal mungkin sedang dipakai - tutup aplikasinya lalu ulangi.' 'Failed items may be in use - close the app and try again.')) }
  return (-not $fail)
}

function Invoke-Step([string]$Label, [scriptblock]$Block) {  # runs a command, or only shows it in dry-run
  if ($script:DRY) { Dim "  [dry-run] $Label"; return }
  try { & $Block | Out-Host } catch { Err $_.Exception.Message }
}

# ------------------------------------------------------------------ disk
function Get-SysDrive {
  try { $n = $env:SystemDrive; if (-not $n) { $n = 'C:' }; return (New-Object IO.DriveInfo $n) } catch { return $null }
}
function Get-FreeBytes { $d = Get-SysDrive; if ($d) { try { return [double]$d.AvailableFreeSpace } catch { } }; return [double]0 }

function Show-Freed([double]$before) {
  if ($script:DRY) { Info (T 'Dry-run: tidak ada yang dihapus.' 'Dry run: nothing was deleted.'); return }
  Start-Sleep -Milliseconds 800
  $after = Get-FreeBytes
  $diff = $after - $before
  if ($diff -gt 1MB) {
    Ok ((T 'Ruang kosong bertambah ' 'Freed ') + (Format-Size $diff) + (T " (sekarang $(Format-Size $after) kosong)." " (now $(Format-Size $after) free)."))
  } else {
    Ok (T "Selesai. Ruang kosong sekarang $(Format-Size $after)." "Done. Free space is now $(Format-Size $after).")
  }
}

# ================================================================== 1. CACHES
# kind: safe = rebuilt automatically, heavy = re-downloaded on next build, permanent = no undo
function New-Cache([string]$Id, [string]$Label, [string]$Kind, [string[]]$Paths, [bool]$Admin = $false) {
  return [pscustomobject]@{ Id = $Id; Label = $Label; Kind = $Kind; Paths = @($Paths | Where-Object { $_ }); Admin = $Admin; Size = [double]0 }
}

function Get-BrowserCachePaths {
  $out = @()
  foreach ($b in @("$($script:LA)\Google\Chrome\User Data", "$($script:LA)\Microsoft\Edge\User Data",
      "$($script:LA)\BraveSoftware\Brave-Browser\User Data", "$($script:LA)\Vivaldi\User Data")) {
    if (-not (Test-Path -LiteralPath $b)) { continue }
    $profiles = @(Get-ChildItem -LiteralPath $b -Directory -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' -or $_.Name -eq 'Guest Profile' })
    foreach ($pr in $profiles) {
      foreach ($c in 'Cache', 'Code Cache', 'GPUCache') { $out += Join-Path $pr.FullName $c }
    }
    $out += Join-Path $b 'ShaderCache'
    $out += Join-Path $b 'GrShaderCache'
  }
  $ff = "$($script:LA)\Mozilla\Firefox\Profiles"
  if (Test-Path -LiteralPath $ff) {
    foreach ($pr in @(Get-ChildItem -LiteralPath $ff -Directory -Force -ErrorAction SilentlyContinue)) { $out += Join-Path $pr.FullName 'cache2' }
  }
  return $out
}

function Get-RecycleBinPaths {
  $out = @()
  try {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
      if ($d.DriveType -ne 'Fixed' -or -not $d.IsReady) { continue }
      $p = $d.Name + '$Recycle.Bin\' + $sid
      if (Test-Path -LiteralPath $p) { $out += $p }
    }
  } catch { }
  return $out
}

function Get-CacheDefs {
  $H = $script:H; $LA = $script:LA; $RA = $script:RA; $W = $script:WINDIR
  $goCache = "$LA\go-build"; $goMod = "$H\go\pkg\mod"; $pnpm = @("$LA\pnpm\store", "$LA\pnpm-store")
  if (Test-Cmd go) {
    $v = [string](& go env GOCACHE 2>$null); if ($v) { $goCache = $v.Trim() }
    $v = [string](& go env GOMODCACHE 2>$null); if ($v) { $goMod = $v.Trim() }
  }
  if (Test-Cmd pnpm) {
    Push-Location -LiteralPath $H
    $v = @(& pnpm store path 2>$null) | Select-Object -Last 1
    Pop-Location
    if ($v -and (Test-Path -LiteralPath ([string]$v).Trim())) { $pnpm = @(([string]$v).Trim()) }
  }
  $editors = @()
  foreach ($e in 'Code', 'Code - Insiders', 'Cursor', 'Windsurf') {
    foreach ($c in 'Cache', 'CachedData', 'CachedExtensionVSIXs', 'Code Cache', 'GPUCache', 'logs') { $editors += "$RA\$e\$c" }
  }
  $list = @(
    (New-Cache 'npm' 'npm / npx cache' 'safe' @("$LA\npm-cache\_cacache", "$LA\npm-cache\_npx", "$LA\npm-cache\_logs")),
    (New-Cache 'yarn' 'Yarn cache' 'safe' @("$LA\Yarn\Cache", "$H\.yarn\berry\cache")),
    (New-Cache 'pnpm' ('pnpm store (' + (T 'paket tak terpakai' 'unused packages') + ')') 'safe' $pnpm),
    (New-Cache 'bun' 'Bun cache' 'safe' @("$H\.bun\install\cache")),
    (New-Cache 'composer' 'Composer cache' 'safe' @("$LA\Composer")),
    (New-Cache 'pip' 'pip cache' 'safe' @("$LA\pip\Cache")),
    (New-Cache 'uv' 'uv cache (Python)' 'safe' @("$LA\uv\cache")),
    (New-Cache 'gobuild' 'Go build cache' 'safe' @($goCache)),
    (New-Cache 'editors' ('VS Code / Cursor: ' + (T 'cache & log' 'caches & logs')) 'safe' $editors),
    (New-Cache 'browsers' (T 'Cache browser (Chrome, Edge, Brave, Firefox)' 'Browser caches (Chrome, Edge, Brave, Firefox)') 'safe' (Get-BrowserCachePaths)),
    (New-Cache 'temp' (T 'File sementara (%TEMP%, > 1 hari)' 'Temporary files (%TEMP%, > 1 day old)') 'safe' @($env:TEMP)),
    (New-Cache 'dumps' (T 'Crash dump & laporan error' 'Crash dumps & error reports') 'safe' @("$LA\CrashDumps", "$LA\Microsoft\Windows\WER\ReportArchive", "$LA\Microsoft\Windows\WER\ReportQueue")),
    (New-Cache 'gradle' 'Gradle caches & wrapper' 'heavy' @("$H\.gradle\caches", "$H\.gradle\wrapper\dists")),
    (New-Cache 'maven' 'Maven repository (~\.m2)' 'heavy' @("$H\.m2\repository")),
    (New-Cache 'gomod' 'Go module cache' 'heavy' @($goMod)),
    (New-Cache 'pub' 'Dart/Flutter pub cache' 'heavy' @("$LA\Pub\Cache\hosted", "$LA\Pub\Cache\git")),
    (New-Cache 'nuget' 'NuGet packages & cache' 'heavy' @("$H\.nuget\packages", "$LA\NuGet\v3-cache", "$LA\NuGet\plugins-cache")),
    (New-Cache 'cargo' 'Cargo registry (Rust)' 'heavy' @("$H\.cargo\registry\cache", "$H\.cargo\registry\src")),
    (New-Cache 'dotcache' ('Playwright, ~\.cache (Puppeteer, ' + (T 'dll' 'etc.') + ')') 'heavy' @("$LA\ms-playwright", "$H\.cache")),
    (New-Cache 'winupdate' (T 'Download Windows Update' 'Windows Update downloads') 'safe' @("$W\SoftwareDistribution\Download") $true),
    (New-Cache 'wintemp' (T 'Windows\Temp (> 1 hari)' 'Windows\Temp (> 1 day old)') 'safe' @("$W\Temp") $true),
    (New-Cache 'delivery' 'Delivery Optimization' 'safe' @("$W\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache") $true),
    (New-Cache 'recycle' 'Recycle Bin' 'permanent' (Get-RecycleBinPaths))
  )
  return $list
}

function Get-CacheSize($c) {
  switch ($c.Id) {
    'temp' { return Get-PathsSize @(Get-OldItems $c.Paths[0] 24 | ForEach-Object { $_.FullName }) }
    'wintemp' { return Get-PathsSize @(Get-OldItems $c.Paths[0] 24 | ForEach-Object { $_.FullName }) }
    default { return Get-PathsSize $c.Paths }
  }
}

function Invoke-CacheClean($c) {
  if ($c.Admin -and -not $script:IsAdmin) {
    Warn ($c.Label + ': ' + (T 'butuh "Run as administrator", dilewati.' 'needs "Run as administrator", skipped.')); return
  }
  switch ($c.Id) {
    'pnpm' {
      if (Test-Cmd pnpm) { Push-Location -LiteralPath $script:H; Invoke-Step 'pnpm store prune' { & pnpm store prune }; Pop-Location }
      else { Warn (T 'pnpm tidak ditemukan, dilewati.' 'pnpm not found, skipped.') }
    }
    'gomod' {
      if (Test-Cmd go) { Invoke-Step 'go clean -modcache' { & go clean -modcache } }
      else { foreach ($p in $c.Paths) { Clear-Folder $p } }
    }
    'temp' { Clear-OldItems $c.Paths[0] 24 }
    'wintemp' { Clear-OldItems $c.Paths[0] 24 }
    'winupdate' {
      Invoke-Step 'Stop-Service wuauserv, bits' { Stop-Service -Name wuauserv, bits -Force -ErrorAction SilentlyContinue }
      Clear-Folder $c.Paths[0]
      Invoke-Step 'Start-Service wuauserv, bits' { Start-Service -Name wuauserv, bits -ErrorAction SilentlyContinue }
    }
    'delivery' {
      if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
        Invoke-Step 'Delete-DeliveryOptimizationCache -Force' { Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue }
      } else { Warn (T 'Perintah Delivery Optimization tidak tersedia di Windows ini.' 'The Delivery Optimization command is not available on this Windows.') }
    }
    'recycle' { Invoke-Step 'Clear-RecycleBin -Force' { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } }
    default { foreach ($p in $c.Paths) { Clear-Folder $p } }
  }
}

function Write-KindTag([string]$kind) {
  switch ($kind) {
    'safe' { Seg (T 'aman' 'safe') 'Green' }
    'heavy' { Seg (T 'berat' 'heavy') 'Yellow' }
    default { Seg (T 'permanen' 'permanent') 'Red' }
  }
}

function Show-CacheMenu {
  Info (T 'Menghitung ukuran cache... (bisa 10-60 detik)' 'Measuring caches... (may take 10-60 seconds)')
  $shown = New-Object System.Collections.Generic.List[object]
  $tSafe = [double]0; $tHeavy = [double]0
  foreach ($c in (Get-CacheDefs)) {
    Show-Progress $c.Label
    $c.Size = Get-CacheSize $c
    if ($c.Id -eq 'recycle') { if ($c.Size -le 0) { continue } }
    elseif ($c.Size -lt 1MB) { continue }   # hide anything under 1 MB
    $shown.Add($c)
    if ($c.Kind -eq 'safe') { $tSafe += $c.Size } elseif ($c.Kind -eq 'heavy') { $tHeavy += $c.Size }
  }
  Clear-Progress
  $n = $shown.Count
  if ($n -eq 0) { Ok (T 'Tidak ada cache berarti yang perlu dibersihkan.' 'No significant caches to clean.'); return }

  Say
  Bold ('  {0,3}  {1,9}  {2} {3}' -f 'No', (T 'Ukuran' 'Size'), (Cut 'Item' 46), (T 'Jenis' 'Type'))
  $anyAdmin = $false
  for ($i = 0; $i -lt $n; $i++) {
    $c = $shown[$i]
    Seg ('  {0,3}  {1,9}  {2} ' -f ($i + 1), (Format-Size $c.Size), (Cut $c.Label 46))
    Write-KindTag $c.Kind
    if ($c.Admin) { $anyAdmin = $true; Seg ' (admin)' 'DarkGray' }
    Say
  }
  Say
  Say ('  ' + (T 'Total aman' 'Total safe') + ': ' + (Format-Size $tSafe) + '   |   ' + (T 'berat' 'heavy') + ': ' + (Format-Size $tHeavy))
  Dim ('  ' + (T 'aman = dibuat ulang otomatis | berat = di-download ulang saat build berikutnya' 'safe = rebuilt automatically | heavy = re-downloaded on the next build'))
  Dim ('  ' + (T 'permanen = tidak bisa dikembalikan' 'permanent = cannot be undone'))
  if ($anyAdmin -and -not $script:IsAdmin) {
    Dim ('  ' + (T '(admin) = hanya dibersihkan kalau Windows Cleaner dijalankan sebagai administrator (menu a)' '(admin) = only cleaned when Windows Cleaner runs as administrator (menu a)'))
  }
  Warn (T 'Tutup IDE, browser & aplikasi lain dulu supaya cache-nya terhapus bersih.' 'Quit your IDE, browser and other apps first so their caches clear completely.')
  Say
  if (-not (Read-Answer ('  ' + (T "Pilih nomor (mis. 1 3 5), a = semua 'aman', s = 'aman' + 'berat', Enter = batal: " "Pick numbers (e.g. 1 3 5), a = all 'safe', s = 'safe' + 'heavy', Enter = cancel: ")))) { return }
  $a = $script:ANSWER
  if (-not $a) { Show-Cancelled; return }
  if ($a -eq 'a' -or $a -eq 's') {
    $sel = @()
    for ($i = 0; $i -lt $n; $i++) {
      $c = $shown[$i]
      if ($c.Admin -and -not $script:IsAdmin) { continue }
      if ($c.Kind -eq 'safe' -or ($a -eq 's' -and $c.Kind -eq 'heavy')) { $sel += $i }
    }
    $script:SEL = $sel
  } else { Read-Selection $a $n }
  if ($script:SEL.Count -eq 0) { Info (T 'Tidak ada yang dipilih.' 'Nothing selected.'); return }

  Say; Say ('  ' + (T 'Akan dibersihkan:' 'Will clean:'))
  $sum = [double]0
  foreach ($i in $script:SEL) { Say ('    - ' + $shown[$i].Label + '  (' + (Format-Size $shown[$i].Size) + ')'); $sum += $shown[$i].Size }
  if (-not (Confirm-Yes ('  ' + (T "Lanjut? (perkiraan +-$(Format-Size $sum))" "Continue? (about $(Format-Size $sum))")))) { Show-Cancelled; return }

  $before = Get-FreeBytes
  foreach ($i in $script:SEL) {
    Info ((T 'Membersihkan ' 'Cleaning ') + $shown[$i].Label + '...')
    Invoke-CacheClean $shown[$i]
  }
  Show-Freed $before
}

# ================================================================== 2. DOCKER & WSL
function Invoke-Docker([string[]]$DockerArgs) {  # docker command that is only shown in dry-run
  if ($script:DRY) { Dim ('  [dry-run] docker ' + ($DockerArgs -join ' ')); return }
  & docker @DockerArgs | Out-Host
}
function Invoke-DockerQuiet([string[]]$DockerArgs) {
  if ($script:DRY) { Dim ('  [dry-run] docker ' + ($DockerArgs -join ' ')); return }
  & docker @DockerArgs | Out-Null
}
function Get-DockerLines([string[]]$DockerArgs) { return @(& docker @DockerArgs 2>$null | Where-Object { $_ }) }

function Show-DkContainers {
  $rows = @(Get-DockerLines @('ps', '-a', '-s', '--format', '{{.ID}}\t{{.State}}\t{{.Size}}\t{{.Names}}\t{{.Image}}') | ForEach-Object {
      $f = $_ -split "`t"; [pscustomobject]@{ Id = $f[0]; State = $f[1]; Size = $f[2]; Name = $f[3]; Image = $f[4] } })
  if ($rows.Count -eq 0) { Ok (T 'Tidak ada container.' 'No containers.'); return }
  Say
  Bold ('  {0,3}  {1}  {2,9}  {3}  {4}' -f 'No', (Cut 'Status' 8), (T 'Ukuran' 'Size'), (Cut (T 'Nama' 'Name') 28), 'Image')
  for ($i = 0; $i -lt $rows.Count; $i++) {
    $r = $rows[$i]
    Seg ('  {0,3}  ' -f ($i + 1))
    if ($r.State -eq 'running') { Seg (Cut $r.State 8) 'Green' } else { Seg (Cut $r.State 8) 'DarkGray' }
    Say ('  {0,9}  {1}  {2}' -f (($r.Size -split ' ')[0]), (Cut $r.Name 28), $r.Image)
  }
  Say
  if (-not (Read-Answer ('  ' + (T 'Pilih nomor (mis. 1 3), s = semua yang berhenti, Enter = kembali: ' 'Pick numbers (e.g. 1 3), s = all stopped, Enter = back: ')))) { return }
  $a = $script:ANSWER
  if (-not $a) { return }
  if ($a -eq 's') { $script:SEL = @(for ($i = 0; $i -lt $rows.Count; $i++) { if ($rows[$i].State -ne 'running') { $i } }) }
  else { Read-Selection $a $rows.Count }
  if ($script:SEL.Count -eq 0) { Info (T 'Tidak ada yang dipilih.' 'Nothing selected.'); return }
  Say ('  ' + (T 'Akan dihapus:' 'Will remove:'))
  $running = 0
  foreach ($i in $script:SEL) { Say ('    - ' + $rows[$i].Name + '  (' + $rows[$i].State + ')'); if ($rows[$i].State -eq 'running') { $running++ } }
  if ($running -gt 0) { Warn (T "$running container sedang berjalan dan akan dihentikan dulu." "$running running container(s) will be stopped first.") }
  Warn (T 'File di dalam container (bukan di volume) ikut hilang. Volume tidak disentuh.' 'Files inside these containers (not in volumes) are lost. Volumes are not touched.')
  if (-not (Confirm-Yes ('  ' + (T 'Lanjut?' 'Continue?')))) { Show-Cancelled; return }
  $before = Get-FreeBytes
  foreach ($i in $script:SEL) { Invoke-DockerQuiet @('rm', '-f', $rows[$i].Id) }
  Show-Freed $before
}

function Show-DkImages {
  $ids = Get-DockerLines @('ps', '-aq')
  $used = @{}
  if ($ids.Count -gt 0) { foreach ($u in (Get-DockerLines (@('inspect', '--format', '{{.Image}}') + $ids))) { $used[$u] = $true } }
  $rows = @(Get-DockerLines @('images', '--no-trunc', '--format', '{{.ID}}\t{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}') | ForEach-Object {
      $f = $_ -split "`t"; $st = 'unused'
      if ($used.ContainsKey($f[0])) { $st = 'use' } elseif ($f[1] -eq '<none>:<none>') { $st = 'dang' }
      $ref = $f[1]
      if ($ref -eq '<none>:<none>') { $ref = ($f[0] -replace '^sha256:', '').Substring(0, 12) }
      [pscustomobject]@{ Ref = $ref; Size = $f[2]; Created = $f[3]; St = $st } })
  if ($rows.Count -eq 0) { Ok (T 'Tidak ada image.' 'No images.'); return }
  Say
  Bold ('  {0,3}  {1,9}  {2}  {3}  {4}' -f 'No', (T 'Ukuran' 'Size'), (Cut 'Status' 11), (Cut (T 'Dibuat' 'Created') 16), 'Image')
  for ($i = 0; $i -lt $rows.Count; $i++) {
    $r = $rows[$i]
    Seg ('  {0,3}  {1,9}  ' -f ($i + 1), $r.Size)
    switch ($r.St) {
      'use' { Seg (Cut (T 'dipakai' 'in use') 11) 'Green' }
      'dang' { Seg (Cut 'dangling' 11) 'Yellow' }
      default { Seg (Cut (T 'tak dipakai' 'unused') 11) 'Yellow' }
    }
    Say ('  {0}  {1}' -f (Cut $r.Created 16), $r.Ref)
  }
  Say
  if (-not (Read-Answer ('  ' + (T 'Pilih nomor, u = semua yang tak dipakai, d = dangling saja, Enter = kembali: ' 'Pick numbers, u = all unused, d = dangling only, Enter = back: ')))) { return }
  $a = $script:ANSWER
  if (-not $a) { return }
  if ($a -eq 'u') {
    if (-not (Confirm-Yes ('  ' + (T 'Hapus semua image yang tidak dipakai container?' 'Remove every image not used by a container?')))) { Show-Cancelled; return }
    $before = Get-FreeBytes; Invoke-Docker @('image', 'prune', '-af'); Show-Freed $before; return
  }
  if ($a -eq 'd') { $before = Get-FreeBytes; Invoke-Docker @('image', 'prune', '-f'); Show-Freed $before; return }
  Read-Selection $a $rows.Count
  if ($script:SEL.Count -eq 0) { Info (T 'Tidak ada yang dipilih.' 'Nothing selected.'); return }
  $pick = @($script:SEL | Where-Object { $rows[$_].St -ne 'use' })
  $skip = $script:SEL.Count - $pick.Count
  if ($skip -gt 0) { Warn (T "$skip image dilewati karena masih dipakai container - hapus containernya dulu (menu 1)." "$skip image(s) skipped because a container uses them - remove the container first (option 1).") }
  if ($pick.Count -eq 0) { return }
  Say ('  ' + (T 'Akan dihapus:' 'Will remove:'))
  foreach ($i in $pick) { Say ('    - ' + $rows[$i].Ref) }
  if (-not (Confirm-Yes ('  ' + (T 'Lanjut?' 'Continue?')))) { Show-Cancelled; return }
  $before = Get-FreeBytes
  foreach ($i in $pick) { Invoke-DockerQuiet @('rmi', $rows[$i].Ref) }
  Show-Freed $before
}

function Show-DkVolumes {
  $rows = @(); $in = $false
  foreach ($line in (& docker system df -v 2>$null)) {
    if ($line -match '^VOLUME NAME') { $in = $true; continue }
    if ($in -and -not $line.Trim()) { break }
    if ($in) { $f = @($line -split '\s+' | Where-Object { $_ }); if ($f.Count -ge 3) { $rows += [pscustomobject]@{ Name = $f[0]; Links = $f[1]; Size = $f[-1] } } }
  }
  if ($rows.Count -eq 0) {   # fallback without sizes
    $dang = @{}; foreach ($v in (Get-DockerLines @('volume', 'ls', '-q', '-f', 'dangling=true'))) { $dang[$v] = $true }
    $rows = @(Get-DockerLines @('volume', 'ls', '-q') | ForEach-Object { $lk = '1'; if ($dang.ContainsKey($_)) { $lk = '0' }; [pscustomobject]@{ Name = $_; Links = $lk; Size = '?' } })
  }
  if ($rows.Count -eq 0) { Ok (T 'Tidak ada volume.' 'No volumes.'); return }
  Say
  Bold ('  {0,3}  {1,9}  {2}  {3}' -f 'No', (T 'Ukuran' 'Size'), (Cut (T 'Dipakai oleh' 'Used by') 24), 'Volume')
  for ($i = 0; $i -lt $rows.Count; $i++) {
    $r = $rows[$i]
    Seg ('  {0,3}  {1,9}  ' -f ($i + 1), $r.Size)
    if ($r.Links -eq '0') { Seg (Cut (T 'tak dipakai' 'unused') 24) 'Yellow' }
    else {
      $who = @(Get-DockerLines @('ps', '-a', '--filter', "volume=$($r.Name)", '--format', '{{.Names}}'))
      $txt = '?'; if ($who.Count -gt 0) { $txt = $who[0]; if ($who.Count -gt 1) { $txt += " +$($who.Count - 1)" } }
      Seg (Cut $txt 24) 'Green'
    }
    Say ('  ' + $r.Name)
  }
  Say
  if (-not (Read-Answer ('  ' + (T 'Pilih nomor, u = semua yang tak dipakai, Enter = kembali: ' 'Pick numbers, u = all unused, Enter = back: ')))) { return }
  $a = $script:ANSWER
  if (-not $a) { return }
  if ($a -eq 'u') { Select-All $rows.Count } else { Read-Selection $a $rows.Count }
  $pick = @($script:SEL | Where-Object { $rows[$_].Links -eq '0' })
  $skip = $script:SEL.Count - $pick.Count
  if ($skip -gt 0 -and $a -ne 'u') { Warn (T "$skip volume dilewati karena masih dipakai container - hapus containernya dulu (menu 1)." "$skip volume(s) skipped because a container uses them - remove the container first (option 1).") }
  if ($pick.Count -eq 0) { Info (T 'Tidak ada volume yang bisa dihapus.' 'No volumes to remove.'); return }
  Say ('  ' + (T 'Akan dihapus:' 'Will remove:'))
  foreach ($i in $pick) { Say ('    - ' + $rows[$i].Name) }
  Warn (T 'Data di volume ini (mis. database) hilang permanen.' 'The data in these volumes (e.g. databases) is gone for good.')
  if (-not (Confirm-Word (T 'HAPUS' 'DELETE'))) { Show-Cancelled; return }
  $before = Get-FreeBytes
  foreach ($i in $pick) { Invoke-DockerQuiet @('volume', 'rm', $rows[$i].Name) }
  Show-Freed $before
}

function Show-DkBuildCache {
  $size = '?'
  foreach ($line in (& docker system df 2>$null)) {
    if ($line -match '^Build Cache') { $f = @($line -split '\s+' | Where-Object { $_ }); if ($f.Count -ge 5) { $size = $f[4] } }
  }
  Say ('  Build cache: ' + $size)
  if (-not (Read-Answer ('  ' + (T 'a = hapus semua, o = hanya yang lebih lama dari 7 hari, Enter = batal: ' 'a = remove all, o = only older than 7 days, Enter = cancel: ')))) { return }
  switch ($script:ANSWER) {
    'a' { $before = Get-FreeBytes; Invoke-Docker @('builder', 'prune', '-af'); Show-Freed $before }
    'o' { $before = Get-FreeBytes; Invoke-Docker @('builder', 'prune', '-af', '--filter', 'until=168h'); Show-Freed $before }
    default { Show-Cancelled }
  }
}

function Show-DkNetworks {
  Say ('  ' + (T 'Network buatan sendiri yang tidak dipakai container akan dihapus (bridge/host/none aman).' 'Custom networks not used by any container will be removed (bridge/host/none are kept).'))
  if (-not (Confirm-Yes ('  ' + (T 'Lanjut?' 'Continue?')))) { Show-Cancelled; return }
  Invoke-Docker @('network', 'prune', '-f')
}

function Invoke-DkSafe {
  $stopped = @(Get-DockerLines @('ps', '-a', '--filter', 'status=exited', '--filter', 'status=created', '--filter', 'status=dead', '--format', '{{.Names}}  ({{.Image}}, {{.Status}})'))
  if ($stopped.Count -gt 0) {
    Say ('  ' + (T 'Container berhenti yang akan dihapus:' 'Stopped containers that will be removed:'))
    foreach ($s in $stopped) { Say "    - $s" }
    Warn (T 'File yang ditulis di dalam container (bukan di volume) ikut hilang. Volume TIDAK disentuh.' 'Files written inside these containers (not in volumes) will be lost. Volumes are NOT touched.')
  }
  if (-not (Confirm-Yes ('  ' + (T 'Lanjut bersihkan?' 'Go ahead?')))) { Show-Cancelled; return }
  $before = Get-FreeBytes
  Invoke-Docker @('container', 'prune', '-f')
  Invoke-Docker @('network', 'prune', '-f')
  Invoke-Docker @('image', 'prune', '-f')
  Invoke-Docker @('builder', 'prune', '-af')
  Show-Freed $before
}

function Invoke-DkAllUnused {
  Say ('  ' + (T 'Akan dihapus: container yang berhenti, SEMUA image tak dipakai, network tak dipakai,' 'Will remove: stopped containers, ALL unused images, unused networks,'))
  Say ('  ' + (T 'build cache, dan SEMUA volume yang tidak dipakai container.' 'build cache and ALL volumes not used by a container.'))
  Warn ((T "Termasuk data database proyek yang container-nya sudah 'docker compose down'. " "This includes database data of projects stopped with 'docker compose down'. ") + (T 'Tidak bisa dikembalikan.' 'This cannot be undone.'))
  if (-not (Confirm-Word (T 'HAPUS' 'DELETE'))) { Show-Cancelled; return }
  $before = Get-FreeBytes
  Invoke-Docker @('system', 'prune', '-af')
  Invoke-Docker @('volume', 'prune', '-af')   # Docker 23+: -a also removes named volumes
  Show-Freed $before
}

function Invoke-DkWipeAll {
  $nc = (Get-DockerLines @('ps', '-aq')).Count; $nr = (Get-DockerLines @('ps', '-q')).Count
  $ni = @(Get-DockerLines @('images', '-q') | Sort-Object -Unique).Count; $nv = (Get-DockerLines @('volume', 'ls', '-q')).Count
  Warn (T "Ini menghapus SEMUA data Docker: $nc container ($nr berjalan), $ni image, $nv volume, network & build cache." "This deletes ALL Docker data: $nc containers ($nr running), $ni images, $nv volumes, networks & build cache.")
  Warn (T 'Pastikan database/volume penting sudah di-backup.' 'Make sure important databases/volumes are backed up.')
  if (-not (Confirm-Word 'RESET')) { Show-Cancelled; return }
  $before = Get-FreeBytes
  $ids = Get-DockerLines @('ps', '-aq')
  if ($ids.Count -gt 0) { Invoke-DockerQuiet (@('rm', '-f') + $ids) }
  $vols = Get-DockerLines @('volume', 'ls', '-q')
  Invoke-Docker @('system', 'prune', '-af')
  if ($vols.Count -gt 0) { Invoke-DockerQuiet (@('volume', 'rm', '-f') + $vols) }
  Invoke-Docker @('builder', 'prune', '-af')
  Show-Freed $before
}

# WSL 2 and Docker Desktop keep their data in .vhdx files that grow but never shrink by themselves.
function Get-WslDisks {
  $list = New-Object System.Collections.Generic.List[object]
  $seen = @{}
  $base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
  if (Test-Path $base) {
    foreach ($k in @(Get-ChildItem -Path $base -ErrorAction SilentlyContinue)) {
      $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
      if (-not $p -or -not $p.BasePath) { continue }
      $vhd = 'ext4.vhdx'; if ($p.VhdFileName) { $vhd = [string]$p.VhdFileName }
      $f = Join-Path (([string]$p.BasePath) -replace '^\\\\\?\\', '') $vhd
      if ((Test-Path -LiteralPath $f) -and -not $seen.ContainsKey($f.ToLower())) {
        $seen[$f.ToLower()] = $true
        $list.Add([pscustomobject]@{ Name = [string]$p.DistributionName; Path = $f; Size = (Get-Item -LiteralPath $f -Force).Length })
      }
    }
  }
  foreach ($f in @("$($script:LA)\Docker\wsl\disk\docker_data.vhdx", "$($script:LA)\Docker\wsl\data\ext4.vhdx", "$($script:LA)\Docker\wsl\main\ext4.vhdx")) {
    if ((Test-Path -LiteralPath $f) -and -not $seen.ContainsKey($f.ToLower())) {
      $seen[$f.ToLower()] = $true
      $list.Add([pscustomobject]@{ Name = 'Docker Desktop'; Path = $f; Size = (Get-Item -LiteralPath $f -Force).Length })
    }
  }
  return , $list.ToArray()
}

function Invoke-WslCompact {
  $disks = Get-WslDisks
  if ($disks.Count -eq 0) { Info (T 'Tidak ada disk WSL / Docker Desktop yang ditemukan.' 'No WSL / Docker Desktop disks found.'); return }
  Say
  Bold ('  {0,3}  {1,9}  {2}  {3}' -f 'No', (T 'Ukuran' 'Size'), (Cut 'Distro' 22), (T 'File' 'File'))
  for ($i = 0; $i -lt $disks.Count; $i++) {
    Say ('  {0,3}  {1,9}  {2}  {3}' -f ($i + 1), (Format-Size $disks[$i].Size), (Cut $disks[$i].Name 22), (Format-Tilde $disks[$i].Path))
  }
  Say
  Dim ('  ' + (T 'Disk virtual WSL membesar sendiri tapi tidak pernah mengecil. Compact mengembalikan ruang' "WSL virtual disks grow on their own but never shrink. Compacting gives back the space"))
  Dim ('  ' + (T 'yang sudah kosong di dalamnya - jalankan pembersihan Docker (6/7) dulu supaya hasilnya maksimal.' 'that is already free inside them - run a Docker cleanup (6/7) first for the best result.'))
  if (-not $script:IsAdmin) {
    Warn (T 'Compact disk butuh hak administrator. Pilih menu "a" di menu utama, atau jalankan PowerShell sebagai Administrator.' 'Compacting needs administrator rights. Use "a" in the main menu, or run PowerShell as Administrator.')
    return
  }
  if (-not (Read-Answer ('  ' + (T 'Pilih nomor, a = semua, Enter = kembali: ' 'Pick numbers, a = all, Enter = back: ')))) { return }
  $a = $script:ANSWER
  if (-not $a) { return }
  if ($a -eq 'a') { Select-All $disks.Count } else { Read-Selection $a $disks.Count }
  if ($script:SEL.Count -eq 0) { Info (T 'Tidak ada yang dipilih.' 'Nothing selected.'); return }
  Warn (T 'Semua distro WSL dan Docker akan dimatikan dulu (wsl --shutdown). Simpan pekerjaan di WSL.' 'All WSL distros and Docker will be shut down first (wsl --shutdown). Save your work in WSL.')
  if (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue) {
    Warn (T 'Docker Desktop sedang berjalan. Tutup dulu: ikon Docker di taskbar > Quit Docker Desktop.' 'Docker Desktop is running. Quit it first: Docker icon in the taskbar > Quit Docker Desktop.')
    [void](Read-Answer ('  ' + (T 'Enter kalau Docker Desktop sudah ditutup...' 'Press Enter once Docker Desktop has quit...')))
    if (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue) { Err (T 'Docker Desktop masih berjalan - dibatalkan.' 'Docker Desktop is still running - cancelled.'); return }
  }
  if (-not (Confirm-Yes ('  ' + (T 'Lanjut compact? (bisa beberapa menit per disk)' 'Go ahead and compact? (may take a few minutes per disk)')))) { Show-Cancelled; return }
  $before = Get-FreeBytes
  if ($script:DRY) { Dim '  [dry-run] wsl --shutdown' } else { & wsl.exe --shutdown | Out-Null; Start-Sleep -Seconds 3 }
  $useHyperV = [bool](Get-Command Optimize-VHD -ErrorAction SilentlyContinue)
  foreach ($i in $script:SEL) {
    $d = $disks[$i]
    Info ((T 'Compact ' 'Compacting ') + $d.Name + '...')
    if ($script:DRY) { Dim ('  [dry-run] compact ' + (Format-Tilde $d.Path)); continue }
    $old = $d.Size
    if ($useHyperV) {
      try { Optimize-VHD -Path $d.Path -Mode Full -ErrorAction Stop } catch { Err $_.Exception.Message; continue }
    } else {
      $tmp = Join-Path $env:TEMP ('wc-diskpart-' + [guid]::NewGuid().ToString('N') + '.txt')
      $dp = "select vdisk file=`"$($d.Path)`"`r`nattach vdisk readonly`r`ncompact vdisk`r`ndetach vdisk`r`n"
      Set-Content -LiteralPath $tmp -Value $dp -Encoding ASCII
      & diskpart.exe /s $tmp | Out-Null
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    $new = (Get-Item -LiteralPath $d.Path -Force).Length
    Ok ($d.Name + ': ' + (Format-Size $old) + ' -> ' + (Format-Size $new))
  }
  Show-Freed $before
}

function Test-DockerUp { & docker info *> $null; return ($LASTEXITCODE -eq 0) }

function Show-DockerMenu {
  $hasDocker = Test-Cmd docker
  $up = $false
  if ($hasDocker) {
    $up = Test-DockerUp
    if (-not $up) {
      Warn (T 'Docker belum berjalan.' 'Docker is not running.')
      $dd = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
      if (Test-Path -LiteralPath $dd) {
        if (Confirm-Yes ('  ' + (T 'Buka Docker Desktop?' 'Open Docker Desktop?'))) {
          Start-Process -FilePath $dd
          Info (T 'Tunggu sampai Docker siap, lalu buka menu ini lagi.' 'Wait until Docker is ready, then open this menu again.')
          Wait-Menu; return
        }
      }
    }
  } else {
    Warn (T 'Perintah docker tidak ditemukan - hanya compact disk WSL yang tersedia.' 'docker command not found - only WSL disk compacting is available.')
  }
  while ($true) {
    Say
    Bold '  Docker & WSL'
    if ($up) {
      foreach ($line in (& docker system df 2>$null)) { Say "  $line" }
      Say
      Dim ('  ' + (T 'Pilih per jenis:' 'Pick by type:'))
      Say ('  1) Container     - ' + (T 'pilih container yang dihapus' 'choose which containers to remove'))
      Say ('  2) Image         - ' + (T 'pilih image, atau semua yang tak dipakai' 'choose images, or all unused ones'))
      Seg ('  3) Volume        - ' + (T 'pilih volume ' 'choose volumes ')); Seg (T '(data ikut hilang)' '(data is lost)') 'Red'; Say
      Say ('  4) Build cache   - ' + (T 'semua, atau yang lebih lama dari 7 hari' 'all, or only older than 7 days'))
      Say ('  5) Network       - ' + (T 'network yang tidak dipakai' 'unused networks'))
      Dim ('  ' + (T 'Sekaligus:' 'All at once:'))
      Say ('  6) ' + (T 'Bersihkan cepat (aman) - container berhenti, image dangling, network, build cache' 'Quick clean (safe) - stopped containers, dangling images, networks, build cache'))
      Seg ('  7) ' + (T 'Hapus semua yang tak dipakai - + semua image & volume tak dipakai ' 'Remove everything unused - + all unused images & volumes ')); Seg '(data)' 'Red'; Say
      Seg ('  8) ' + (T 'Hapus SEMUA data Docker - termasuk yang sedang berjalan ' 'Delete ALL Docker data - including running containers ')); Seg '(reset)' 'Red'; Say
    } elseif ($hasDocker) {
      Dim ('  ' + (T 'Docker belum berjalan - menu 1-8 muncul setelah Docker siap.' 'Docker is not running - options 1-8 appear once it is ready.'))
    }
    Seg ('  9) ' + (T 'Kecilkan disk WSL / Docker Desktop (compact .vhdx) ' 'Shrink the WSL / Docker Desktop disk (compact .vhdx) ')); Seg '(admin)' 'DarkGray'; Say
    Dim ('  ' + (T 'Reset Docker Desktop sepenuhnya: Docker Desktop > Troubleshoot > Clean / Purge data' 'Full Docker Desktop reset: Docker Desktop > Troubleshoot > Clean / Purge data'))
    Say ('  b) ' + (T 'Kembali' 'Back'))
    if (-not (Read-Answer ('  ' + (T 'Pilih: ' 'Choose: ')))) { return }
    $a = $script:ANSWER
    if ($a -eq 'b' -or -not $a) { return }
    if ($a -eq '9') { Invoke-WslCompact; continue }
    if (-not $up) { continue }
    switch ($a) {
      '1' { Show-DkContainers }
      '2' { Show-DkImages }
      '3' { Show-DkVolumes }
      '4' { Show-DkBuildCache }
      '5' { Show-DkNetworks }
      '6' { Invoke-DkSafe }
      '7' { Invoke-DkAllUnused }
      '8' { Invoke-DkWipeAll }
    }
  }
}

# ================================================================== 3/4. APPS
$script:UserBases = @($script:LA, $script:RA, "$($script:H)\AppData\LocalLow", "$($script:LA)\Programs")
# Folder names that are shared by many apps, so they are never treated as one app's leftovers.
$script:GenericNames = @('microsoft', 'windows', 'programs', 'packages', 'temp', 'google', 'mozilla', 'apple', 'adobe',
  'intel', 'nvidia', 'nvidia corporation', 'amd', 'common files', 'package cache', 'installer', 'crashdumps', 'd3dscache',
  'npm', 'npm-cache', 'pip', 'python', 'java', 'oracle', 'jetbrains', 'docker', 'github', 'nodejs', 'node', 'git',
  'updater', 'update', 'cache', 'caches', 'logs', 'app', 'apps', 'data', 'bin', 'tools', 'software', 'system')

function Get-CleanName([string]$n) {
  $s = $n -replace '\s*\((x64|x86|arm64|64-bit|32-bit|user|machine|[^)]*bit)\)', ''
  $s = $s -replace '\s+v?\d+(\.\d+)+.*$', ''
  $s = $s -replace '\s+(x64|x86|arm64|64-bit|32-bit)$', ''
  return $s.Trim()
}
function Get-ExeFromCommand([string]$cmd) {  # "C:\x\uninst.exe" /S -> @(exe, args)
  $c = $cmd.Trim()
  if ($c.StartsWith('"')) {
    $e = $c.IndexOf('"', 1)
    if ($e -gt 1) { return @($c.Substring(1, $e - 1), $c.Substring($e + 1).Trim()) }
    return $null
  }
  if ($c -match '^(.+?\.exe)(\s+(.*))?$') { return @($matches[1], [string]$matches[3]) }
  return $null
}
function Test-GoodLocation([string]$d) {  # an app's own folder, never a shared one
  $f = Get-Full $d
  if (-not $f) { return $false }
  if ($f -match '(?i)\\(Package Cache|Installer|system32|SysWOW64|Common Files)(\\|$)') { return $false }
  foreach ($x in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $script:WINDIR, $script:LA, $script:RA, "$($script:LA)\Programs", $env:ProgramData, $script:H)) {
    if ($x -and $f -ieq (Get-Full $x)) { return $false }
  }
  return $true
}
function Get-AppLocation($p) {
  $loc = ([string]$p.InstallLocation).Trim().Trim('"').TrimEnd('\')
  if ($loc -and (Test-Path -LiteralPath $loc -PathType Container) -and (Test-GoodLocation $loc)) { return $loc }
  $icon = [string]$p.DisplayIcon
  if ($icon) {
    $icon = ($icon -split ',')[0].Trim().Trim('"')
    if ($icon -match '(?i)\.exe$' -and (Test-Path -LiteralPath $icon)) { $d = Split-Path -Parent $icon; if (Test-GoodLocation $d) { return $d } }
  }
  $ex = Get-ExeFromCommand ([string]$p.UninstallString)
  if ($ex -and $ex[0] -notmatch '(?i)msiexec' -and (Test-Path -LiteralPath $ex[0])) {
    $d = Split-Path -Parent $ex[0]; if (Test-GoodLocation $d) { return $d }
  }
  return ''
}

function Get-InstalledApps {
  $roots = @(
    @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; S = 'machine' },
    @{ P = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; S = 'machine' },
    @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; S = 'user' })
  $apps = New-Object System.Collections.Generic.List[object]
  $seen = @{}
  foreach ($r in $roots) {
    if (-not (Test-Path $r.P)) { continue }
    foreach ($k in @(Get-ChildItem -Path $r.P -ErrorAction SilentlyContinue)) {
      $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
      if (-not $p -or -not $p.DisplayName -or -not $p.UninstallString) { continue }
      if ($p.SystemComponent -eq 1 -or $p.ParentKeyName -or ([string]$p.ReleaseType) -match 'Update|Hotfix') { continue }
      $name = ([string]$p.DisplayName).Trim()
      $id = $name.ToLower() + '|' + [string]$p.DisplayVersion
      if ($seen.ContainsKey($id)) { continue }
      $seen[$id] = $true
      $est = [double]0
      try { if ($p.EstimatedSize) { $est = [double]$p.EstimatedSize * 1KB } } catch { }
      $apps.Add([pscustomobject]@{
          Name = $name; Clean = (Get-CleanName $name); Version = [string]$p.DisplayVersion; Publisher = ([string]$p.Publisher).Trim()
          Location = (Get-AppLocation $p); Uninstall = [string]$p.UninstallString; Key = $k.PSPath; Scope = $r.S
          Size = $est; LastUsed = $null })
    }
  }
  return , @($apps | Sort-Object Name)
}

function Get-OtherNames($apps, $app) {  # names and folders of every OTHER installed app
  $names = @{}; $locs = @()
  foreach ($o in $apps) {
    if ($o -eq $app -or ($app.Clean -and $o.Clean -ieq $app.Clean)) { continue }
    foreach ($n in @($o.Clean, $o.Name)) { if ($n) { $names[$n.ToLower()] = $true } }
    if ($o.Location) { $names[(Split-Path -Leaf $o.Location).ToLower()] = $true; $locs += (Get-Full $o.Location) }
  }
  return @{ Names = $names; Locs = $locs }
}

function Find-Leftovers($app, $others, [string[]]$bases) {
  $names = @()
  foreach ($n in @($app.Clean, $app.Name)) { if ($n) { $names += $n.ToLower() } }
  if ($app.Location) {
    $leaf = Split-Path -Leaf $app.Location
    if ($leaf -and $leaf -notmatch '^(?i)(bin|app|application|current|x64|x86)$') { $names += $leaf.ToLower() }
  }
  $names = @($names | Sort-Object -Unique | Where-Object { $_.Length -ge 3 -and $script:GenericNames -notcontains $_ })
  $pub = ($app.Publisher -replace '(?i)[,.]?\s+(inc|llc|ltd|corp|corporation|gmbh|co|limited)\.?$', '').Trim()
  $out = @()
  foreach ($b in $bases) {
    if (-not $b -or -not (Test-Path -LiteralPath $b)) { continue }
    $dirs = @($b)
    if ($pub -and $script:GenericNames -notcontains $pub.ToLower()) {
      $pd = Join-Path $b $pub; if (Test-Path -LiteralPath $pd -PathType Container) { $dirs += $pd }   # e.g. AppData\<Publisher>\<App>
    }
    foreach ($d in $dirs) {
      foreach ($c in @(Get-ChildItem -LiteralPath $d -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($c.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $cn = $c.Name.ToLower()
        if ($names -notcontains $cn -or $others.Names.ContainsKey($cn)) { continue }
        $out += $c.FullName
      }
    }
  }
  if ($app.Location -and (Test-Path -LiteralPath $app.Location)) { $out += (Get-Full $app.Location) }   # install folder left behind
  $res = @()
  foreach ($p in ($out | Sort-Object -Unique)) {
    $f = Get-Full $p
    $shared = $false
    foreach ($l in $others.Locs) { if ($l -ieq $f -or (Test-Under $l $f)) { $shared = $true; break } }
    if (-not $shared) { $res += $f }
  }
  return , $res
}

function Start-Uninstaller($app) {
  $cmd = $app.Uninstall.Trim(); $file = ''; $arg = ''
  if ($cmd -match '(?i)msiexec(\.exe)?"?\s+.*?/[IX]\s*(\{[0-9A-F-]+\})') { $file = 'msiexec.exe'; $arg = "/x $($matches[2])" }
  else {
    $ex = Get-ExeFromCommand $cmd
    if ($ex) { $file = $ex[0]; $arg = $ex[1] } else { $file = $env:ComSpec; $arg = "/d /s /c `"$cmd`"" }
  }
  if ($script:DRY) { Dim "  [dry-run] $file $arg"; return $true }
  try {
    if ($arg) { Start-Process -FilePath $file -ArgumentList $arg } else { Start-Process -FilePath $file }
    return $true
  } catch { Err ((T 'Uninstaller tidak bisa dijalankan: ' "Couldn't start the uninstaller: ") + $_.Exception.Message); return $false }
}

function Invoke-Uninstall($app, $apps) {
  Say; Info (T "Mencari file sisa $($app.Name)..." "Looking for $($app.Name)'s leftover files...")
  $dup = @($apps | Where-Object { $_ -ne $app -and $app.Clean -and $_.Clean -ieq $app.Clean }).Count -gt 0
  $others = Get-OtherNames $apps $app
  $user = @(); $adminOnly = @()
  if (-not $dup) {
    foreach ($p in (Find-Leftovers $app $others $script:UserBases)) { if ($p -ine (Get-Full $app.Location)) { $user += $p } }
    foreach ($p in (Find-Leftovers $app $others @($env:ProgramData))) { if ($p -ine (Get-Full $app.Location)) { $adminOnly += $p } }
  }
  Bold ('  ' + $app.Name)
  Dim ('  ' + ((@($app.Version, $app.Publisher) | Where-Object { $_ }) -join ' | '))
  $sz = '?'; if ($app.Size -gt 0) { $sz = Format-Size $app.Size }
  $where = $app.Location; if (-not $where) { $where = T '(lokasi tidak diketahui)' '(location unknown)' }
  Say ('  {0,9}  {1}' -f $sz, (Format-Tilde $where))
  foreach ($p in $user) { Say ('  {0,9}  {1}' -f (Format-Size (Get-PathSize $p)), (Format-Tilde $p)) }
  if ($user.Count -eq 0) { Dim ('  ' + (T 'Tidak ada file sisa di AppData.' 'No leftover files in AppData.')) }
  if ($dup) { Warn (T 'Ada salinan lain aplikasi ini yang terpasang, jadi file sisanya tidak disentuh.' 'Another copy of this app is installed, so its files are kept.') }
  if ($adminOnly.Count -gt 0) {
    Dim ('  ' + (T 'Juga ada di ProgramData (butuh admin, tidak dihapus):' 'Also found in ProgramData (needs admin, not removed):'))
    foreach ($p in $adminOnly) { Dim "             $p" }
  }
  if ($user.Count -gt 0) { $q = T 'y = jalankan uninstaller + file sisa ke Recycle Bin, a = uninstaller saja, Enter = batal: ' 'y = run the uninstaller + leftovers to the Recycle Bin, a = uninstaller only, Enter = cancel: ' }
  else { $q = T 'y = jalankan uninstaller, Enter = batal: ' 'y = run the uninstaller, Enter = cancel: ' }
  if (-not (Read-Answer "  $q")) { return }
  $withLeft = $false
  if ($script:ANSWER -match '^(y|ya|yes)$') { $withLeft = ($user.Count -gt 0) }
  elseif ($script:ANSWER -eq 'a' -and $user.Count -gt 0) { $withLeft = $false }
  else { Show-Cancelled; return }

  if (-not (Start-Uninstaller $app)) { return }
  if ($script:DRY) { if ($withLeft) { [void](Move-ToRecycleBin $user) }; return }
  Info (T 'Uninstaller dibuka - ikuti langkahnya (Windows mungkin meminta izin admin).' 'The uninstaller is open - follow its steps (Windows may ask for admin permission).')
  [void](Read-Answer ('  ' + (T 'Enter kalau uninstaller sudah selesai...' 'Press Enter once the uninstaller has finished...')))
  if (Test-Path -LiteralPath $app.Key) {
    Warn (T "$($app.Name) masih terdaftar (uninstall dibatalkan atau belum selesai?). File sisa tidak disentuh." "$($app.Name) is still installed (cancelled, or not finished yet?). Leftover files were not touched.")
    return
  }
  Ok (T "$($app.Name) sudah di-uninstall." "$($app.Name) uninstalled.")
  if (-not $withLeft) { return }
  $left = Find-Leftovers $app $others $script:UserBases   # look again: some may be gone, the install folder may remain
  if ($left.Count -eq 0) { Info (T 'Tidak ada file sisa yang tertinggal.' 'No leftover files remained.'); return }
  $total = Get-PathsSize $left
  if (Move-ToRecycleBin $left) { Ok (T "$(Format-Size $total) file sisa dipindah ke Recycle Bin." "$(Format-Size $total) of leftover files moved to the Recycle Bin.") }
}

# When was an app last opened? Windows keeps this for programs started from the Start menu,
# taskbar or Explorer (UserAssist), and - readable as administrator - in Prefetch.
function Convert-Rot13([string]$s) {
  $sb = New-Object System.Text.StringBuilder $s.Length
  foreach ($ch in $s.ToCharArray()) {
    $c = [int]$ch
    if ($c -ge 65 -and $c -le 90) { $c = (($c - 65 + 13) % 26) + 65 }
    elseif ($c -ge 97 -and $c -le 122) { $c = (($c - 97 + 13) % 26) + 97 }
    [void]$sb.Append([char]$c)
  }
  return $sb.ToString()
}

function Get-UsageIndex {
  $kf = @{
    '{6D809377-6AF0-444B-8957-A3773F02200E}' = $env:ProgramW6432
    '{7C5A40EF-A0FB-4BFC-874A-C0F2E0B9FA8E}' = ${env:ProgramFiles(x86)}
    '{F38BF404-1D43-42F2-9305-67DE0B28FC23}' = $script:WINDIR
    '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}' = "$($script:WINDIR)\System32"
    '{A77F5D77-2E2B-44C3-A6A2-ABA601054A51}' = "$($script:RA)\Microsoft\Windows\Start Menu\Programs"
    '{0139D44E-6AFE-49F2-8690-3DAFCAE6FFB8}' = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"
    '{9E3995AB-1F9C-4F13-B827-48B24B6C7174}' = "$($script:RA)\Microsoft\Internet Explorer\Quick Launch\User Pinned"
  }
  if (-not $kf['{6D809377-6AF0-444B-8957-A3773F02200E}']) { $kf['{6D809377-6AF0-444B-8957-A3773F02200E}'] = $env:ProgramFiles }
  $ua = New-Object System.Collections.Generic.List[object]
  $wsh = $null
  try { $wsh = New-Object -ComObject WScript.Shell } catch { }
  $base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist'
  foreach ($g in @(Get-ChildItem -Path $base -ErrorAction SilentlyContinue)) {
    $key = $null
    try { $key = Get-Item -LiteralPath (Join-Path $g.PSPath 'Count') -ErrorAction Stop } catch { continue }
    foreach ($vn in $key.GetValueNames()) {
      $data = $key.GetValue($vn)
      if (-not ($data -is [byte[]]) -or $data.Length -lt 68) { continue }
      $ft = [BitConverter]::ToInt64($data, 60)
      if ($ft -le 0) { continue }
      $t = $null
      try { $t = [DateTime]::FromFileTime($ft) } catch { continue }
      $name = Convert-Rot13 $vn
      if ($name -match '^(\{[0-9A-Fa-f-]{36}\})(.*)$') {
        $g2 = $matches[1].ToUpper()
        if ($kf.ContainsKey($g2) -and $kf[$g2]) { $name = $kf[$g2] + $matches[2] }
      }
      if ($name -like '*.lnk') {
        if (-not $wsh -or -not (Test-Path -LiteralPath $name)) { continue }
        try { $name = [string]$wsh.CreateShortcut($name).TargetPath } catch { continue }
      }
      if ($name -match '^[A-Za-z]:\\') { $ua.Add([pscustomobject]@{ Path = $name; Time = $t }) }
    }
  }
  $pf = @{}
  if ($script:IsAdmin) {
    foreach ($f in @(Get-ChildItem -LiteralPath "$($script:WINDIR)\Prefetch" -Filter '*.pf' -ErrorAction SilentlyContinue)) {
      $exe = ($f.Name -replace '-[0-9A-Fa-f]{8}\.pf$', '').ToUpper()
      if (-not $pf.ContainsKey($exe) -or $pf[$exe] -lt $f.LastWriteTime) { $pf[$exe] = $f.LastWriteTime }
    }
  }
  return @{ UA = $ua.ToArray(); PF = $pf }
}

function Get-LastUsed($app, $idx) {
  $loc = $app.Location
  if (-not $loc) { return $null }
  $best = $null
  foreach ($u in $idx.UA) { if ((Test-Under $u.Path $loc) -and ($null -eq $best -or $u.Time -gt $best)) { $best = $u.Time } }
  if ($idx.PF.Count -gt 0) {
    $exes = @(Get-ChildItem -LiteralPath $loc -Filter '*.exe' -Recurse -Depth 1 -Force -ErrorAction SilentlyContinue |
      ForEach-Object { $_.Name.ToUpper() } | Where-Object { $_ -notmatch '^(UNINS|UNINSTALL|SETUP)' })
    foreach ($e in $exes) { if ($idx.PF.ContainsKey($e) -and ($null -eq $best -or $idx.PF[$e] -gt $best)) { $best = $idx.PF[$e] } }
  }
  return $best
}

function Show-AppsMenu {
  if (-not (Read-Answer ('  ' + (T "Anggap 'jarang dipakai' kalau tidak dibuka lebih dari berapa hari? [$($script:UNUSED_DAYS)] " "Treat an app as 'rarely used' after how many days unopened? [$($script:UNUSED_DAYS)] ")))) { return }
  $thr = $script:UNUSED_DAYS
  if ($script:ANSWER) {
    if ($script:ANSWER -match '^\d{1,5}$') { $thr = [int]$script:ANSWER }
    else { Warn (T "Bukan angka, pakai $thr hari." "Not a number, using $thr days.") }
  }
  $apps = Get-InstalledApps
  if ($apps.Count -eq 0) { Warn (T 'Tidak ada aplikasi ditemukan.' 'No apps found.'); return }
  Info (T "Memindai $($apps.Count) aplikasi... (ukuran + kapan terakhir dibuka)" "Scanning $($apps.Count) apps... (size + last opened)")
  $idx = Get-UsageIndex
  $now = Get-Date
  for ($i = 0; $i -lt $apps.Count; $i++) {
    $a = $apps[$i]
    Show-Progress ("[$($i + 1)/$($apps.Count)] " + $a.Name)
    if ($a.Size -le 0) { if ($a.Location) { $a.Size = Get-PathSize $a.Location }; if ($a.Size -le 0) { $a.Size = [double]-1 } }
    $a.LastUsed = Get-LastUsed $a $idx
  }
  Clear-Progress
  $sorted = @($apps | Sort-Object Size -Descending)
  $list = @(); $rank = 0; $rareN = 0; $rareSize = [double]0
  Say
  Bold ('  ' + (T "Aplikasi jarang dipakai (> $thr hari) + 10 terbesar, urut dari yang terbesar:" "Rarely used apps (> $thr days) + 10 largest, largest first:"))
  Bold ('  {0,3}  {1,9}  {2}  {3}  {4}' -f 'No', (T 'Ukuran' 'Size'), (Cut 'Status' 7), (Cut (T 'Terakhir dibuka' 'Last opened') 18), (T 'Nama' 'Name'))
  foreach ($a in $sorted) {
    $rank++
    $days = -1
    if ($a.LastUsed) { $days = [int][Math]::Floor(($now - $a.LastUsed).TotalDays); if ($days -lt 0) { $days = 0 } }
    $rare = ($days -lt 0 -or $days -gt $thr)
    if ($rare) { $rareN++; if ($a.Size -gt 0) { $rareSize += $a.Size } }
    if (-not $rare -and $rank -gt 10) { continue }
    $list += $a
    if ($days -lt 0) { $when = T 'tidak tercatat' 'never recorded' }
    elseif ($days -eq 0) { $when = T 'hari ini' 'today' }
    else { $when = "$days " + (T 'hari lalu' 'days ago') }
    Seg ('  {0,3}  {1,9}  ' -f $list.Count, (Format-Size $a.Size))
    if ($rare) { Seg (Cut (T 'jarang' 'rare') 7) 'Yellow' } else { Seg (Cut (T 'aktif' 'active') 7) 'DarkGray' }
    Say ('  {0}  {1}' -f (Cut $when 18), $a.Name)
  }
  Say
  Bold ('  ' + (T "$rareN aplikasi jarang dipakai, total $(Format-Size $rareSize)." "$rareN rarely used apps, $(Format-Size $rareSize) in total."))
  Dim ('  ' + (T "'tidak tercatat' = Windows tidak punya catatan aplikasi ini dibuka dari Start, taskbar, atau Explorer" "'never recorded' = Windows has no record of the app being opened from Start, the taskbar or Explorer"))
  Dim ('  ' + (T '(belum pernah dibuka, hanya lewat terminal, atau dijalankan aplikasi lain).' '(never opened, only started from a terminal, or launched by another program).'))
  if (-not $script:IsAdmin) { Dim ('  ' + (T 'Jalankan sebagai administrator (menu a) supaya data "terakhir dibuka" lebih lengkap.' 'Run as administrator (menu a) for more complete "last opened" data.')) }
  Say
  if (-not (Read-Answer ('  ' + (T 'Uninstall? Masukkan nomor (mis. 2 5), Enter = lewati: ' 'Uninstall? Enter numbers (e.g. 2 5), Enter = skip: ')))) { return }
  if (-not $script:ANSWER) { return }
  Read-Selection $script:ANSWER $list.Count
  if ($script:SEL.Count -eq 0) { Info (T 'Tidak ada yang dipilih.' 'Nothing selected.'); return }
  foreach ($i in @($script:SEL)) { Invoke-Uninstall $list[$i] $apps }
  Say; Show-RecycleHint
}

function Show-RecycleHint {
  if ($script:DRY) { return }
  Dim ('  ' + (T 'Ruang disk baru lega setelah Recycle Bin dikosongkan (menu 1 > Recycle Bin).' 'Disk space is freed once the Recycle Bin is emptied (menu 1 > Recycle Bin).'))
}

function Show-UninstallMenu {
  $apps = Get-InstalledApps
  if ($apps.Count -eq 0) { Warn (T 'Tidak ada aplikasi ditemukan.' 'No apps found.'); Wait-Menu; return }
  if (-not (Read-Answer ('  ' + (T 'Cari aplikasi (sebagian nama), Enter = tampilkan semua: ' 'Search apps (part of the name), Enter = show all: ')))) { return }
  $q = $script:ANSWER
  $shown = @($apps | Where-Object { -not $q -or $_.Name.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
  if ($shown.Count -eq 0) { Warn (T "Tidak ada aplikasi yang cocok dengan '$q'." "No app matches '$q'."); Wait-Menu; return }
  Say
  for ($i = 0; $i -lt $shown.Count; $i++) {
    Seg ('  {0,3}  {1} ' -f ($i + 1), (Cut $shown[$i].Name 52))
    Write-Host $shown[$i].Version -ForegroundColor DarkGray
  }
  Dim ('  ' + (T 'Aplikasi Microsoft Store: Settings > Apps > Installed apps.' 'Microsoft Store apps: Settings > Apps > Installed apps.'))
  Say
  if (-not (Read-Answer ('  ' + (T 'Nomor aplikasi yang mau di-uninstall (mis. 3 atau 2 5), Enter = kembali: ' 'App number(s) to uninstall (e.g. 3 or 2 5), Enter = back: ')))) { return }
  if (-not $script:ANSWER) { return }
  Read-Selection $script:ANSWER $shown.Count
  if ($script:SEL.Count -eq 0) { Wait-Menu; return }
  foreach ($i in @($script:SEL)) { Invoke-Uninstall $shown[$i] $apps }
  Say; Show-RecycleHint
  Wait-Menu
}

# ================================================================== 5. LARGEST FOLDERS
function Show-BigData {
  Info (T 'Mengukur folder & data aplikasi terbesar... (bisa 1-3 menit)' 'Measuring the largest folders & app data... (may take 1-3 minutes)')
  $cands = @()
  foreach ($c in @(Get-ChildItem -LiteralPath $script:H -Force -ErrorAction SilentlyContinue)) {
    if ($c.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }   # old "My Documents"-style junctions
    if ($c.Name -eq 'AppData' -or $c.Name -like 'OneDrive*' -or $c.Name -like 'ntuser*') { continue }
    $cands += $c.FullName
  }
  foreach ($b in @($script:LA, $script:RA, "$($script:H)\AppData\LocalLow")) {
    foreach ($c in @(Get-ChildItem -LiteralPath $b -Directory -Force -ErrorAction SilentlyContinue)) {
      if (-not ($c.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $cands += $c.FullName }
    }
  }
  $rows = @()
  $i = 0
  foreach ($p in $cands) {
    $i++; Show-Progress ("[$i/$($cands.Count)] " + (Format-Tilde $p))
    $rows += [pscustomobject]@{ Path = $p; Size = (Get-PathSize $p) }
  }
  Clear-Progress
  $top = @($rows | Sort-Object Size -Descending | Select-Object -First 25)
  Say
  Bold ('  {0,3}  {1,9}  {2}' -f 'No', (T 'Ukuran' 'Size'), (T 'Lokasi' 'Location'))
  for ($i = 0; $i -lt $top.Count; $i++) { Say ('  {0,3}  {1,9}  {2}' -f ($i + 1), (Format-Size $top[$i].Size), (Format-Tilde $top[$i].Path)) }
  Say
  Dim ('  ' + (T 'OneDrive tidak dihitung (file-nya bisa hanya ada di cloud).' 'OneDrive is skipped (its files may only be in the cloud).'))
  # Big system files at the root of the Windows drive
  $sys = @(Get-ChildItem -LiteralPath ("$env:SystemDrive" + '\') -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -in 'hiberfil.sys', 'pagefile.sys', 'swapfile.sys' })
  if ($sys.Count -gt 0) {
    Dim ('  ' + (T 'File sistem: ' 'System files: ') + (($sys | ForEach-Object { $_.Name + ' ' + (Format-Size $_.Length) }) -join ' | '))
    if ($sys | Where-Object { $_.Name -eq 'hiberfil.sys' -and $_.Length -gt 1GB }) {
      Dim ('  ' + (T "Tidak pakai Hibernate? 'powercfg /h off' (sebagai admin) menghapus hiberfil.sys (Fast Startup ikut mati)." "Don't use Hibernate? 'powercfg /h off' (as admin) removes hiberfil.sys (also turns off Fast Startup)."))
    }
  }
  if ($top.Count -eq 0) { Wait-Menu; return }
  Say
  while ($true) {
    if (-not (Read-Answer ('  ' + (T 'Tampilkan di Explorer? Masukkan nomor, Enter = kembali: ' 'Show in Explorer? Enter a number, Enter = back: ')))) { return }
    if (-not $script:ANSWER) { return }
    Read-Selection $script:ANSWER $top.Count
    foreach ($i in @($script:SEL)) {
      if ($script:IsWin) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $top[$i].Path + '"') } else { Say ('  ' + $top[$i].Path) }
    }
  }
}

# ================================================================== 6. UPDATES (winget)
# Reads the table printed by "winget upgrade". Column positions come from the header line,
# so it works whatever language winget prints in.
function Get-WingetUpgrades {
  $old = $null
  try { $old = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
  $lines = @(& winget upgrade --accept-source-agreements 2>$null)
  try { if ($old) { [Console]::OutputEncoding = $old } } catch { }
  $sep = -1
  for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*-{10,}\s*$') { $sep = $i; break } }
  if ($sep -lt 1) { return , @() }
  $hdr = ([string]$lines[$sep - 1] -split "`r")[-1]
  $starts = @([regex]::Matches($hdr, '\S+') | ForEach-Object { $_.Index })
  if ($starts.Count -lt 4) { return , @() }
  $out = @()
  for ($i = $sep + 1; $i -lt $lines.Count; $i++) {
    $l = [string]$lines[$i]
    if (-not $l.Trim() -or $l.Length -le $starts[3]) { break }   # blank line or summary ends the table
    $cols = @()
    for ($c = 0; $c -lt $starts.Count; $c++) {
      $s = $starts[$c]
      if ($s -ge $l.Length) { $cols += ''; continue }
      if ($c + 1 -lt $starts.Count) { $e = [Math]::Min($starts[$c + 1], $l.Length) } else { $e = $l.Length }
      $cols += $l.Substring($s, $e - $s).Trim()
    }
    if (-not $cols[1] -or $cols[1] -match '\s') { continue }
    $src = ''; if ($cols.Count -ge 5) { $src = $cols[4] }
    $out += [pscustomobject]@{ Name = $cols[0]; Id = $cols[1]; From = $cols[2]; To = $cols[3]; Source = $src }
  }
  return , $out
}

function Show-UpdateMenu {
  if (-not (Test-Cmd winget)) {
    Warn (T "winget tidak ditemukan. Pasang 'App Installer' dari Microsoft Store, lalu coba lagi." "winget not found. Install 'App Installer' from the Microsoft Store, then try again.")
  }
  $ups = @()
  if (Test-Cmd winget) {
    Info (T 'Mengecek update lewat winget... (bisa 1 menit)' 'Checking for updates with winget... (may take a minute)')
    $ups = Get-WingetUpgrades
    Say
    if ($ups.Count -eq 0) { Ok (T 'Semua aplikasi yang dikenali winget sudah versi terbaru.' 'Every app winget recognises is up to date.') }
    else {
      Bold ('  {0,3}  {1}  {2}  {3}  {4}' -f 'No', (Cut (T 'Nama' 'Name') 30), (Cut (T 'Terpasang' 'Installed') 16), (Cut (T 'Terbaru' 'Latest') 16), (T 'Sumber' 'Source'))
      for ($i = 0; $i -lt $ups.Count; $i++) {
        $u = $ups[$i]
        Seg ('  {0,3}  {1}  {2}  ' -f ($i + 1), (Cut $u.Name 30), (Cut $u.From 16))
        Seg (Cut $u.To 16) 'Green'
        Say ('  ' + $u.Source)
      }
    }
  }
  Say
  Dim ('  ' + (T 's = buka update Microsoft Store, w = buka Windows Update' 's = open Microsoft Store updates, w = open Windows Update'))
  if ($ups.Count -gt 0) { $q = T 'Pilih nomor, a = semua, s, w, Enter = kembali: ' 'Pick numbers, a = all, s, w, Enter = back: ' }
  else { $q = T 's, w, Enter = kembali: ' 's, w, Enter = back: ' }
  if (-not (Read-Answer "  $q")) { return }
  $a = $script:ANSWER
  if (-not $a) { return }
  if ($a -eq 's') { if (-not $script:DRY) { Start-Process 'ms-windows-store://downloadsandupdates' } else { Dim '  [dry-run] ms-windows-store://downloadsandupdates' }; Wait-Menu; return }
  if ($a -eq 'w') { if (-not $script:DRY) { Start-Process 'ms-settings:windowsupdate' } else { Dim '  [dry-run] ms-settings:windowsupdate' }; Wait-Menu; return }
  if ($ups.Count -eq 0) { return }
  if ($a -eq 'a') { Select-All $ups.Count } else { Read-Selection $a $ups.Count }
  if ($script:SEL.Count -eq 0) { Info (T 'Tidak ada yang dipilih.' 'Nothing selected.'); Wait-Menu; return }
  Say ('  ' + (T 'Akan diupdate:' 'Will update:'))
  foreach ($i in $script:SEL) { Say ('    - ' + $ups[$i].Name + '  ' + $ups[$i].From + ' -> ' + $ups[$i].To) }
  Dim ('  ' + (T 'winget mungkin menampilkan lisensi aplikasi atau meminta izin admin untuk beberapa aplikasi.' 'winget may show an app licence or ask for admin permission for some apps.'))
  Warn (T 'Tutup aplikasi yang mau diupdate dulu.' 'Close the apps you are updating first.')
  if (-not (Confirm-Yes ('  ' + (T 'Lanjut?' 'Continue?')))) { Show-Cancelled; Wait-Menu; return }
  foreach ($i in @($script:SEL)) {
    $u = $ups[$i]
    Info ((T 'Mengupdate ' 'Updating ') + $u.Name + '...')
    if ($script:DRY) { Dim "  [dry-run] winget upgrade --id $($u.Id) --exact"; continue }
    & winget upgrade --id $u.Id --exact
    if ($LASTEXITCODE -ne 0) { Warn (T "$($u.Name): winget selesai dengan kode $LASTEXITCODE." "$($u.Name): winget finished with code $LASTEXITCODE.") }
  }
  Say; Ok (T 'Selesai.' 'Done.')
  Wait-Menu
}

# ================================================================== 7. RAM
function Get-MemStats {
  $m = @{ Total = [double]0; Avail = [double]0; Used = [double]0; Standby = [double]0; Commit = [double]0; Limit = [double]0; Comp = [double]0; Level = 0 }
  try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $m.Total = [double]$os.TotalVisibleMemorySize * 1KB
    $m.Avail = [double]$os.FreePhysicalMemory * 1KB
  } catch { return $m }
  try {
    $pm = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
    $m.Avail = [double]$pm.AvailableBytes
    $m.Standby = [double]$pm.StandbyCacheCoreBytes + [double]$pm.StandbyCacheNormalPriorityBytes + [double]$pm.StandbyCacheReserveBytes
    $m.Commit = [double]$pm.CommittedBytes
    $m.Limit = [double]$pm.CommitLimit
  } catch { }
  try {
    $mc = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -Filter "Name='MemCompression'" -ErrorAction Stop
    if ($mc) { $m.Comp = [double]$mc.WorkingSetPrivate }
  } catch { }
  $m.Used = $m.Total - $m.Avail
  $availPct = 100; if ($m.Total -gt 0) { $availPct = $m.Avail * 100 / $m.Total }
  $commitPct = 0; if ($m.Limit -gt 0) { $commitPct = $m.Commit * 100 / $m.Limit }
  if ($availPct -lt 5 -or $commitPct -gt 90) { $m.Level = 4 }
  elseif ($availPct -lt 15 -or $commitPct -gt 80) { $m.Level = 2 }
  else { $m.Level = 1 }
  return $m
}

function Show-Mem($m) {
  $pct = 0; if ($m.Total -gt 0) { $pct = [int]($m.Used * 100 / $m.Total) }
  Seg ('  RAM: ' + (Format-Size $m.Used) + (T ' terpakai dari ' ' used of ') + (Format-Size $m.Total) + " ($pct%)  |  " + (T 'Beban memori: ' 'Memory load: '))
  switch ($m.Level) {
    1 { Seg 'normal' 'Green' }
    2 { Seg (T 'peringatan' 'warning') 'Yellow' }
    4 { Seg (T 'kritis' 'critical') 'Red' }
    default { Seg '?' 'DarkGray' }
  }
  Say
  Dim ('  ' + (T 'Tersedia ' 'Available ') + (Format-Size $m.Avail) + ' | Cache (standby) ' + (Format-Size $m.Standby) + ' | ' + (T 'Terkompresi ' 'Compressed ') + (Format-Size $m.Comp) + ' | Commit ' + (Format-Size $m.Commit) + ' / ' + (Format-Size $m.Limit))
}

function Get-HostPaths {  # the terminal this script runs in, so it's never offered for quitting
  $set = @{}
  try {
    $procs = @{}
    foreach ($p in @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, ExecutablePath -ErrorAction Stop)) { $procs[[int]$p.ProcessId] = $p }
    $id = $PID; $n = 0
    while ($id -and $procs.ContainsKey($id) -and $n -lt 20) {
      $e = $procs[$id].ExecutablePath
      if ($e) { $set[$e.ToLower()] = $true }
      $id = [int]$procs[$id].ParentProcessId; $n++
    }
  } catch { }
  return $set
}

function Get-MemByApp {
  $ws = @{}
  try {
    foreach ($x in @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -Property IDProcess, WorkingSetPrivate -ErrorAction Stop)) {
      if ($x.IDProcess -gt 0) { $ws[[int]$x.IDProcess] = [double]$x.WorkingSetPrivate }
    }
  } catch { }
  $mySession = 0; try { $mySession = (Get-Process -Id $PID).SessionId } catch { }
  $groups = @{}
  foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
    $mem = [double]$p.WorkingSet64
    if ($ws.ContainsKey($p.Id)) { $mem = $ws[$p.Id] }
    $path = $null; try { $path = $p.Path } catch { }
    $vm = ($p.ProcessName -like 'vmmem*')
    if ($p.SessionId -ne $mySession -and -not $vm) { continue }   # services and other users
    if ($path) { $key = $path.ToLower() } else { $key = 'proc:' + $p.ProcessName.ToLower() }
    if (-not $groups.ContainsKey($key)) {
      $name = $null
      try { $name = $p.Description } catch { }
      if (-not $name) { try { $name = $p.Product } catch { } }
      if (-not $name) { $name = $p.ProcessName }
      $groups[$key] = [pscustomobject]@{ Key = $key; Name = [string]$name; Path = $path; Mem = [double]0; Window = $false; Vm = $vm
        System = ([bool]$path -and $script:WINDIR -and $path.StartsWith($script:WINDIR + '\', [StringComparison]::OrdinalIgnoreCase)) }
    }
    $g = $groups[$key]
    $g.Mem += $mem
    if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $g.Window = $true }
  }
  return , @($groups.Values | Sort-Object Mem -Descending)
}

function Stop-AppGroup($g) {  # asks the app to close normally, like clicking X
  foreach ($p in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -eq $g.Path } catch { $false } })) {
    if ($p.MainWindowHandle -ne [IntPtr]::Zero) { [void]$p.CloseMainWindow() }
  }
  for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 1
    $left = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -eq $g.Path -and $_.MainWindowHandle -ne [IntPtr]::Zero } catch { $false } })
    if ($left.Count -eq 0) { return $true }
  }
  return $false
}

function Show-RamMenu {
  $hostPaths = Get-HostPaths
  while ($true) {
    Say; $m = Get-MemStats; Show-Mem $m
    Dim ('  ' + (T 'Windows sengaja memakai RAM kosong sebagai cache (standby) - yang penting beban memori.' 'Windows uses free RAM as cache (standby) on purpose - what matters is memory load.'))
    Dim ('  ' + (T 'Kalau kuning atau merah, tutup aplikasi yang paling berat.' "If it's yellow or red, quit the heaviest apps."))
    $all = Get-MemByApp
    $apps = @(); $vmMem = [double]0
    Say
    Bold ('  {0,3}  {1,9}  {2}' -f 'No', (T 'Memori' 'Memory'), (T 'Aplikasi' 'App'))
    foreach ($g in $all) {
      if (-not $g.Window -or $g.System -or $g.Vm -or -not $g.Path) { continue }
      if ($apps.Count -ge 12) { break }
      if ($hostPaths.ContainsKey($g.Path.ToLower())) {
        Seg ('  {0,3}  {1,9}  {2} ' -f '', (Format-Size $g.Mem), $g.Name); Dim (T '(terminal ini)' '(this terminal)'); continue
      }
      $apps += $g
      Seg ('  {0,3}  {1,9}  {2}' -f $apps.Count, (Format-Size $g.Mem), $g.Name)
      if ($g.Name -like 'Docker*') { Dim (T ' (menghentikan container)' ' (stops containers)') } else { Say }
    }
    Say
    Dim ('  ' + (T 'Proses lain (hentikan dari tempat Anda menjalankannya):' 'Other processes (stop them where you started them):'))
    $shown = 0
    foreach ($g in $all) {
      if ($shown -ge 5) { break }
      if ($g.Vm) { $vmMem += $g.Mem }
      if (($g.Window -and -not $g.Vm) -or ($g.System -and -not $g.Vm) -or $g.Mem -lt 100MB) { continue }
      $note = ''; if ($g.Vm) { $note = T ' (VM WSL/Docker - w = wsl --shutdown)' ' (WSL/Docker VM - w = wsl --shutdown)' }
      Dim ('  {0,3}  {1,9}  {2}{3}' -f '', (Format-Size $g.Mem), $g.Name, $note)
      $shown++
    }
    if ($shown -eq 0) { Dim '       -' }
    Say
    $hasWsl = Test-Cmd wsl
    $q = T 'Tutup aplikasi (mis. 1 3)' 'Quit apps (e.g. 1 3)'
    if ($hasWsl) { $q += T ', w = matikan WSL' ', w = shut down WSL' }
    if (-not (Read-Answer ("  $q" + (T ', Enter = kembali: ' ', Enter = back: ')))) { return }
    $a = $script:ANSWER
    if (-not $a) { return }
    if ($a -eq 'w' -and $hasWsl) {
      Say ('  ' + (T 'Semua distro WSL dan engine Docker Desktop dimatikan; RAM VM-nya (vmmem) dikembalikan ke Windows.' "All WSL distros and Docker Desktop's engine are shut down; the VM's RAM (vmmem) goes back to Windows."))
      if (-not (Confirm-Yes ('  ' + (T 'Jalankan wsl --shutdown?' 'Run wsl --shutdown?')))) { Show-Cancelled; continue }
      $before = $m.Used
      if ($script:DRY) { Dim '  [dry-run] wsl --shutdown'; continue }
      & wsl.exe --shutdown | Out-Null
      Start-Sleep -Seconds 3; $m2 = Get-MemStats
      Ok ((T 'RAM terpakai: ' 'RAM used: ') + (Format-Size $before) + ' -> ' + (Format-Size $m2.Used))
      continue
    }
    Read-Selection $a $apps.Count
    if ($script:SEL.Count -eq 0) { continue }
    Say ('  ' + (T 'Akan ditutup:' 'Will quit:'))
    foreach ($i in $script:SEL) { Say ('    - ' + $apps[$i].Name) }
    Dim ('  ' + (T 'Aplikasi ditutup secara normal - kalau ada pekerjaan yang belum disimpan, aplikasinya akan bertanya dulu.' "Apps quit normally - if there's unsaved work, the app asks you first."))
    if (-not (Confirm-Yes ('  ' + (T 'Lanjut?' 'Continue?')))) { Show-Cancelled; continue }
    $before = $m.Used
    foreach ($i in @($script:SEL)) {
      $g = $apps[$i]
      if ($script:DRY) { Dim ('  [dry-run] ' + (T 'tutup ' 'quit ') + $g.Name); continue }
      if (Stop-AppGroup $g) { Ok ($g.Name + (T ' ditutup.' ' quit.')) }
      else { Warn (T "$($g.Name) masih berjalan (mungkin menunggu Anda menyimpan). Paksa tutup lewat Task Manager (Ctrl+Shift+Esc) kalau perlu." "$($g.Name) is still running (maybe waiting for you to save). End it in Task Manager (Ctrl+Shift+Esc) if needed.") }
    }
    if (-not $script:DRY) {
      Start-Sleep -Seconds 2; $m2 = Get-MemStats
      Ok ((T 'RAM terpakai: ' 'RAM used: ') + (Format-Size $before) + ' -> ' + (Format-Size $m2.Used))
    }
  }
}

# ================================================================== MAIN MENU
function Show-Header {
  Say
  Seg '  Windows Cleaner ' 'White'; Seg "v$($script:WC_VERSION)" 'DarkGray'
  if ($script:IsAdmin) { Seg '  (Administrator)' 'Yellow' }
  Say
  if ($script:DRY) { Write-Host ('  ' + (T 'DRY-RUN: tidak ada yang benar-benar dihapus' 'DRY RUN: nothing will actually be deleted')) -ForegroundColor Yellow }
  $d = Get-SysDrive
  if ($d -and $d.IsReady) {
    $total = [double]$d.TotalSize; $free = [double]$d.AvailableFreeSpace
    $pct = 0; if ($total -gt 0) { $pct = [int](($total - $free) * 100 / $total) }
    Say ('  Disk ' + $d.Name.TrimEnd('\') + ' ' + (Format-Size $free) + (T ' kosong dari ' ' free of ') + (Format-Size $total) + " ($pct% " + (T 'terpakai' 'used') + ')')
  }
  Say
}

function Start-AsAdmin {
  if (-not $script:SelfPath) {
    Info (T 'Buka PowerShell sebagai Administrator (klik kanan Start > Terminal (Admin)), lalu jalankan perintahnya lagi.' 'Open PowerShell as Administrator (right-click Start > Terminal (Admin)), then run the command again.')
    return $false
  }
  $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$($script:SelfPath)`" -Lang $($script:UiLang)"
  if ($script:DRY) { $argList += ' -DryRun' }
  try {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -ErrorAction Stop
    Ok (T 'Windows Cleaner dibuka di jendela Administrator.' 'Windows Cleaner opened in an Administrator window.')
    return $true
  } catch {
    Warn (T 'Dibatalkan.' 'Cancelled.')
    return $false
  }
}

function Start-Main {
  if (-not $script:IsWin) {
    Warn (T 'Script ini dibuat untuk Windows - sebagian fitur tidak akan jalan di sistem ini.' "This script is made for Windows - some features won't work on this system.")
  }
  :menu while ($true) {
    Show-Header
    Say ('  1) ' + (T 'Bersihkan cache (dev tools, browser, Temp, Recycle Bin)' 'Clean caches (dev tools, browsers, Temp, Recycle Bin)'))
    Say ('  2) ' + (T 'Docker & WSL: bersihkan / reset / kecilkan disk' 'Docker & WSL: clean up / reset / shrink disk'))
    Say ('  3) ' + (T 'Cek aplikasi jarang dipakai & paling besar' 'Find rarely used & largest apps'))
    Say ('  4) ' + (T 'Uninstall aplikasi (beserta file sisanya)' 'Uninstall an app (with its leftover files)'))
    Say ('  5) ' + (T 'Cek folder & data aplikasi terbesar' 'Find the largest folders & app data'))
    Say ('  6) ' + (T 'Update aplikasi (winget, Microsoft Store)' 'Update apps (winget, Microsoft Store)'))
    Say ('  7) ' + (T 'RAM: cek pemakaian & tutup aplikasi yang berat' 'RAM: check usage & quit heavy apps'))
    if (-not $script:IsAdmin -and $script:IsWin) {
      Seg ('  a) ' + (T 'Jalankan sebagai administrator ' 'Run as administrator ')); Dim (T '(Windows Update, Windows\Temp, disk WSL)' '(Windows Update, Windows\Temp, WSL disks)')
    }
    Seg ('  l) ' + (T 'Bahasa: Indonesia ' 'Language: English ')); Dim (T '(switch to English)' '(ganti ke Bahasa Indonesia)')
    Say ('  q) ' + (T 'Keluar' 'Quit'))
    Say
    if (-not (Read-Answer ('  ' + (T 'Pilih: ' 'Choose: ')))) { break menu }
    switch ($script:ANSWER) {
      '1' { Show-CacheMenu; Wait-Menu }
      '2' { Show-DockerMenu }
      '3' { Show-AppsMenu; Wait-Menu }
      '4' { Show-UninstallMenu }
      '5' { Show-BigData }
      '6' { Show-UpdateMenu }
      '7' { Show-RamMenu }
      'a' { if (-not $script:IsAdmin -and (Start-AsAdmin)) { break menu } }
      'l' {
        if ($script:UiLang -eq 'id') { $script:UiLang = 'en' } else { $script:UiLang = 'id' }
        Save-Lang
        Ok (T 'Bahasa diganti ke Indonesia.' 'Language switched to English.')
      }
      'q' { break menu }
    }
  }
  Say; Say ('  ' + (T 'Selesai.' 'Bye.'))
}

if ($Help) { Show-Usage } else { Start-Main }
