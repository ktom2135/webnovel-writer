#Requires -Version 5.1
<#
.SYNOPSIS
    从安卓手机复制照片到本地目录（跳过重复，MTP 模式）
.DESCRIPTION
    通过 MTP 连接安卓手机，扫描相机、截图、微信等目录，
    按文件名去重后复制到指定目录。
.PARAMETER DestPath
    保存目录，默认 C:\pic
#>

param(
    [string]$DestPath = "C:\pic",
    [string]$LogPath  = "C:\pic\copy_log.txt"
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
chcp 65001 | Out-Null

function Write-Log {
    param([string]$Msg)
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] $Msg" -ForegroundColor Cyan
    Add-Content -Path $LogPath -Value "[$ts] $Msg" -ErrorAction SilentlyContinue
}

function List-FolderItems {
    param([object]$Folder)
    try {
        $f = if ($Folder.GetFolder) { $Folder.GetFolder() } elseif ($Folder.Items) { $Folder } else { return @() }
        return @($f.Items())
    } catch {
        return @()
    }
}

function Copy-FileViaMTP {
    param([object]$Item, [string]$DestFile, [string]$FileName)
    $tempDir = Join-Path $env:TEMP "mtp_$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        $sh = New-Object -ComObject Shell.Application
        $ns = $sh.Namespace($tempDir)
        # 0x10 = 静默模式，0x04 = 不显示进度
        $ns.CopyHere($Item, 0x14)
        Start-Sleep -Milliseconds 500
        $tmp = Join-Path $tempDir $Item.Name
        if (Test-Path $tmp) {
            Move-Item -Path $tmp -Destination $DestFile -Force
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Copy-Photos-MTP-Folder {
    param(
        [object]$Folder, [string]$RelPath, [hashtable]$Copied,
        [string]$DestBase, [ref]$CopiedCount, [ref]$SkippedCount, [ref]$ErrorCount, [int]$Depth = 0
    )
    if ($Depth -gt 5) { return }
    $exts = @('.jpg','.jpeg','.png','.gif','.bmp','.webp','.heic','.heif')

    Write-Host "  [扫描] $RelPath" -ForegroundColor DarkGray
    $items = List-FolderItems -Folder $Folder

    foreach ($item in $items) {
        if ($item.IsFolder) {
            Copy-Photos-MTP-Folder -Folder $item -RelPath "$RelPath\$($item.Name)" `
                -Copied $Copied -DestBase $DestBase `
                -CopiedCount $CopiedCount -SkippedCount $SkippedCount -ErrorCount $ErrorCount -Depth ($Depth + 1)
        } else {
            $ext = [System.IO.Path]::GetExtension($item.Name).ToLower()
            if ($exts -notcontains $ext) { continue }

            $name = $item.Name

            # 跳过已复制的（进程内缓存）
            if ($Copied.ContainsKey($name)) { $SkippedCount.Value++; continue }

            $destDir = Join-Path $DestBase $RelPath
            $destFile = Join-Path $destDir $name

            # 跳过已存在的（文件系统检查）
            if (Test-Path -LiteralPath $destFile) {
                $Copied[$name] = $destFile
                $SkippedCount.Value++
                continue
            }

            if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

            Write-Host "    [$($CopiedCount.Value + 1)] [复制] $name" -ForegroundColor Green
            if (Copy-FileViaMTP -Item $item -DestFile $destFile -FileName $name) {
                $Copied[$name] = $destFile
                $CopiedCount.Value++
            } else {
                $ErrorCount.Value++
                Write-Log "  [!] $name - 复制失败"
            }
        }
    }
}

function Nav-MTP($root, $path) {
    $p = $path -split '\\' | Where-Object { $_ }
    $c = $root
    foreach ($x in $p) {
        $n = $null
        foreach ($s in (List-FolderItems -Folder $c)) {
            if ($s.IsFolder -and $s.Name -eq $x) { $n = $s; break }
        }
        if (-not $n) { return $null }
        $c = $n
    }
    return $c
}

# ── 主逻辑 ────────────────────────────────────────────────
Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host "  安卓手机照片复制工具 (MTP模式)" -ForegroundColor Yellow
Write-Host "========================================`n" -ForegroundColor Yellow

if (-not (Test-Path $DestPath)) { New-Item -ItemType Directory -Path $DestPath -Force | Out-Null }
if (Test-Path $LogPath) { Remove-Item $LogPath -Force }

# 加载已有文件到去重表
$copiedFiles = @{}
if (Test-Path $DestPath) {
    Get-ChildItem -Path $DestPath -Recurse -File | ForEach-Object {
        $copiedFiles[$_.Name] = $_.FullName
    }
}
Write-Log "目标目录已有 $($copiedFiles.Count) 个文件"

# 扫描 MTP 设备
$shell = New-Object -ComObject Shell.Application
$ns = $shell.Namespace(0x11)

Write-Host "正在扫描此电脑..." -ForegroundColor Yellow
$devices = @($ns.Items())
if ($devices.Count -eq 0) { Write-Host "[错误] 未检测到设备！" -ForegroundColor Red; exit }

$totalCopied = 0; $totalSkipped = 0; $totalErrors = 0

foreach ($device in $devices) {
    Write-Host "`n设备: $($device.Name)" -ForegroundColor Green

    # 查找内部存储
    $storage = $null
    foreach ($sub in (List-FolderItems -Folder $device)) {
        if ($sub.IsFolder -and $sub.Name -match "内部|Internal|Phone|手机|存储|Storage|shared|sdcard") { $storage = $sub; break }
    }
    if (-not $storage) {
        $folders = @(List-FolderItems -Folder $device | Where-Object { $_.IsFolder })
        if ($folders.Count -eq 1) { $storage = $folders[0] }
        else { Write-Log "  跳过设备: $($device.Name)"; continue }
    }
    Write-Log "  存储: $($storage.Name)"

    foreach ($p in @("DCIM\Camera", "DCIM\Screenshots", "DCIM\100MEDIA", "Pictures\Screenshots", "Pictures\WeChat", "Download\WeChat")) {
        $d = Nav-MTP $storage $p
        if ($d) {
            $c = [ref]0; $s = [ref]0; $e = [ref]0
            Copy-Photos-MTP-Folder -Folder $d -RelPath $p -Copied $copiedFiles -DestBase $DestPath -CopiedCount $c -SkippedCount $s -ErrorCount $e
            $totalCopied += $c.Value; $totalSkipped += $s.Value; $totalErrors += $e.Value
        }
        else { Write-Log "  跳过: $p (不存在)" }
    }
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  完成!" -ForegroundColor Green
Write-Host "  已复制: $totalCopied | 跳过: $totalSkipped | 失败: $totalErrors" -ForegroundColor $(if ($totalErrors -gt 0) { "Yellow" } else { "Green" })
Write-Host "  位置: $DestPath" -ForegroundColor Green
Write-Host "  日志: $LogPath" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green