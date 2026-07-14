#Requires -Version 5.1
<#
.SYNOPSIS
    从安卓手机复制照片到本地目录（跳过重复）
.DESCRIPTION
    通过 MTP 连接安卓手机，扫描微信、相机等多个照片目录，
    按文件大小+名称去重后复制到 C:\pic
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
    } catch { return @() }
}

function Copy-FileViaMTP {
    param([object]$Item, [string]$DestFile)
    # 用 Shell.CopyHere 复制到本地临时目录再移动
    $tempDir = Join-Path $env:TEMP "mtp_$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        $shell = New-Object -ComObject Shell.Application
        $tempFolder = $shell.Namespace($tempDir)
        $tempFolder.CopyHere($Item, 0x14) # 0x10=yesToAll, 0x04=noProgress
        Start-Sleep -Milliseconds 300
        $tempFile = Join-Path $tempDir $Item.Name
        if (Test-Path $tempFile) {
            Move-Item -Path $tempFile -Destination $DestFile -Force
            return $true
        }
        return $false
    } finally {
        if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Copy-PhotosFromFolder {
    param(
        [object]$Folder,
        [string]$RelPath,
        [hashtable]$CopiedFiles,
        [string]$DestBase,
        [ref]$CopiedCount,
        [ref]$SkippedCount,
        [ref]$ErrorCount,
        [int]$Depth = 0
    )
    if ($Depth -gt 5) { return }
    $exts = @('.jpg','.jpeg','.png','.gif','.bmp','.webp','.heic','.heif')

    $items = List-FolderItems -Folder $Folder
    foreach ($item in $items) {
        if (-not $item.IsFolder) {
            $ext = [System.IO.Path]::GetExtension($item.Name).ToLower()
            if ($exts -notcontains $ext) { continue }
            $key = "$($item.Size)_$($item.Name)"
            if ($CopiedFiles.ContainsKey($key)) { $SkippedCount.Value++; continue }

            $destDir = Join-Path $DestBase $RelPath
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

            $destFile = Join-Path $destDir $item.Name
            $i = 1
            while (Test-Path $destFile) {
                $base = [System.IO.Path]::GetFileNameWithoutExtension($item.Name)
                $destFile = Join-Path $destDir "${base}_${i}${ext}"; $i++
            }

            if (Copy-FileViaMTP -Item $item -DestFile $destFile) {
                $CopiedFiles[$key] = $destFile
                $CopiedCount.Value++
            } else {
                $ErrorCount.Value++
                Write-Log "  [!] $($item.Name) - 复制失败"
            }
        } else {
            Copy-PhotosFromFolder -Folder $item -RelPath "$RelPath\$($item.Name)" `
                -CopiedFiles $CopiedFiles -DestBase $DestBase `
                -CopiedCount $CopiedCount -SkippedCount $SkippedCount -ErrorCount $ErrorCount `
                -Depth ($Depth + 1)
        }
    }
}

function Navigate-To {
    param([object]$Root, [string]$Path)
    $parts = $Path -split '\\' | Where-Object { $_ }
    $cur = $Root
    foreach ($p in $parts) {
        $next = $null
        foreach ($s in (List-FolderItems -Folder $cur)) {
            if ($s.IsFolder -and $s.Name -eq $p) { $next = $s; break }
        }
        if (-not $next) { return $null }
        $cur = $next
    }
    return $cur
}

# ── 主逻辑 ────────────────────────────────────────────────
Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host "  安卓手机照片复制工具" -ForegroundColor Yellow
Write-Host "========================================`n" -ForegroundColor Yellow

if (-not (Test-Path $DestPath)) { New-Item -ItemType Directory -Path $DestPath -Force | Out-Null }
if (Test-Path $LogPath) { Remove-Item $LogPath -Force }

$shell     = New-Object -ComObject Shell.Application
$namespace = $shell.Namespace(0x11)

# 找到 MTP 设备
Write-Host "正在扫描此电脑..." -ForegroundColor Yellow
$devices = @()
foreach ($item in $namespace.Items()) {
    Write-Host "  发现: $($item.Name) (类型: $($item.Type))" -ForegroundColor Gray
    $devices += $item
}

if ($devices.Count -eq 0) {
    Write-Host "`n[错误] 未检测到设备！" -ForegroundColor Red; exit 1
}

$totalCopied = 0; $totalSkipped = 0; $totalErrors = 0
$copiedFiles = @{}

foreach ($device in $devices) {
    Write-Host "`n设备: $($device.Name)" -ForegroundColor Green
    Write-Log "设备: $($device.Name)"

    # 查找内部存储
    $storage = $null
    foreach ($sub in (List-FolderItems -Folder $device)) {
        if ($sub.IsFolder) {
            if ($sub.Name -match "内部|Internal|Phone|手机|存储|Storage|shared|sdcard") {
                $storage = $sub; break
            }
        }
    }
    if (-not $storage) {
        $folders = @(List-FolderItems -Folder $device | Where-Object { $_.IsFolder })
        if ($folders.Count -eq 1) { $storage = $folders[0] }
        else {
            Write-Log "  设备内容:"
            foreach ($f in $folders) { Write-Log "    $($f.Name)" }
            continue
        }
    }
    Write-Log "  存储: $($storage.Name)"

    # 扫描相机关联目录
    $paths = @(
        "DCIM\Camera", "DCIM\Screenshots", "DCIM\100MEDIA"
        "Download", "Pictures\Screenshots", "Pictures\WeChat"
        "Download\WeChat", "Download\weixin", "Download\weixin_image"
    )
    foreach ($p in $paths) {
        $d = Navigate-To -Root $storage -Path $p
        if ($d) {
            Write-Log "  扫描: $p"
            $c = [ref]0; $s = [ref]0; $e = [ref]0
            Copy-PhotosFromFolder -Folder $d -RelPath $p -CopiedFiles $copiedFiles -DestBase $DestPath `
                -CopiedCount $c -SkippedCount $s -ErrorCount $e
            $totalCopied += $c.Value; $totalSkipped += $s.Value; $totalErrors += $e.Value
        }
    }

    # 微信目录（含随机哈希）
    foreach ($base in @("Android\data\com.tencent.mm\MicroMsg", "tencent\MicroMsg")) {
        $wcRoot = Navigate-To -Root $storage -Path $base
        if (-not $wcRoot) { continue }
        foreach ($sub in (List-FolderItems -Folder $wcRoot)) {
            if (-not $sub.IsFolder) { continue }
            foreach ($sfx in @("camera", "Image2", "Video", "Download")) {
                $wcDir = Navigate-To -Root $sub -Path $sfx
                if ($wcDir) {
                    $fullPath = "$base\$($sub.Name)\$sfx"
                    Write-Log "  微信: $fullPath"
                    $c = [ref]0; $s = [ref]0; $e = [ref]0
                    Copy-PhotosFromFolder -Folder $wcDir -RelPath $fullPath -CopiedFiles $copiedFiles -DestBase $DestPath `
                        -CopiedCount $c -SkippedCount $s -ErrorCount $e
                    $totalCopied += $c.Value; $totalSkipped += $s.Value; $totalErrors += $e.Value
                }
            }
        }
    }
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  完成!" -ForegroundColor Green
Write-Host "  已复制: $totalCopied | 跳过: $totalSkipped | 失败: $totalErrors" -ForegroundColor $(if ($totalErrors -gt 0) { "Yellow" } else { "Green" })
Write-Host "  位置: $DestPath" -ForegroundColor Green
Write-Host "  日志: $LogPath" -ForegroundColor Green