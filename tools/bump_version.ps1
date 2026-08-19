<#
.SYNOPSIS
    版本号自动递增工具（语义化版本 + 单调递增构建号），供构建脚本调用。

.DESCRIPTION
    解析 apps/mobile_web/pubspec.yaml 的 version: MAJOR.MINOR.PATCH[-SUFFIX]+BUILD，
    按模式递增：
      默认（每次构建）   : BUILD + 1
      -Patch（小修复）   : PATCH + 1, BUILD + 1
      -Minor（实质性更新）: MINOR + 1, PATCH = 0, BUILD + 1
      -Major（大版本更新）: MAJOR + 1, MINOR = 0, PATCH = 0, BUILD + 1

    BUILD 永不回退（Android versionCode 需单调递增），-SUFFIX（如有）原样保留。
    参考常见 Flutter 项目的语义化版本做法：构建号随每次构建自增，功能更新升次版本，
    大改版升主版本，且构建号不回退以免覆盖安装/商店审核出问题。

.PARAMETER PubspecPath
    pubspec.yaml 路径。缺省为 <仓库根>\apps\mobile_web\pubspec.yaml。

.PARAMETER Major
    大版本更新：主版本号 +1，次版本/修订归零，构建号 +1。

.PARAMETER Minor
    实质性更新（新功能）：次版本号 +1，修订归零，构建号 +1。

.PARAMETER Patch
    小修复：修订号 +1，构建号 +1。

.PARAMETER DryRun
    只打印将要写入的版本号，不修改文件。

.EXAMPLE
    .\tools\bump_version.ps1              # 0.1.1+5 -> 0.1.1+6
    .\tools\bump_version.ps1 -Minor       # 0.1.1+5 -> 0.2.0+6
    .\tools\bump_version.ps1 -Major       # 0.1.1+5 -> 1.0.0+6
    .\tools\bump_version.ps1 -Patch       # 0.1.1+5 -> 0.1.2+6
#>
param(
    [switch]$Major,
    [switch]$Minor,
    [switch]$Patch,
    [string]$PubspecPath = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# ---------- 定位 pubspec.yaml ----------
if (-not $PubspecPath) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $PubspecPath = Join-Path $repoRoot "apps\mobile_web\pubspec.yaml"
}
if (-not (Test-Path $PubspecPath)) {
    Write-Error "pubspec.yaml 未找到: $PubspecPath"
    exit 1
}

# ---------- 互斥校验：Major / Minor / Patch 只能指定一个 ----------
$bumpFlags = @($Major, $Minor, $Patch)
if (($bumpFlags | Where-Object { $_ }).Count -gt 1) {
    Write-Error "-Major / -Minor / -Patch 只能指定一个"
    exit 1
}

# ---------- 解析当前版本 ----------
$content = Get-Content $PubspecPath -Raw
$pattern = 'version:\s*(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z\.]+))?\+(\d+)'
if ($content -notmatch $pattern) {
    Write-Error "无法解析 version 行（期望格式 version: x.y.z[-suffix]+build）: $PubspecPath"
    exit 1
}

$major = [int]$Matches[1]
$minor = [int]$Matches[2]
$patch = [int]$Matches[3]
$suffix = $Matches[4]
$build = [int]$Matches[5]

# ---------- 按模式递增 ----------
if ($Major) {
    $major += 1; $minor = 0; $patch = 0
} elseif ($Minor) {
    $minor += 1; $patch = 0
} elseif ($Patch) {
    $patch += 1
}
# 构建号每次都 +1，永不回退（Android versionCode 单调递增）
$build += 1

# ---------- 写回 ----------
$suffixPart = if ($suffix) { "-$suffix" } else { "" }
$oldVersion = "$($Matches[1]).$($Matches[2]).$($Matches[3])$suffixPart+$($Matches[5])"
$newVersion = "$major.$minor.$patch$suffixPart+$build"
$oldLine = "version: $oldVersion"
$newLine = "version: $newVersion"

Write-Host "版本号: $oldVersion -> $newVersion" -ForegroundColor Magenta

if (-not $DryRun) {
    $newContent = $content.Replace($oldLine, $newLine)
    if ($newContent -eq $content) {
        Write-Error "版本行匹配失败（$oldLine 未在文件中找到），文件未修改"
        exit 1
    }
    # 以 UTF-8 无 BOM 写回，保留其余内容原样
    [System.IO.File]::WriteAllText(
        $PubspecPath,
        $newContent,
        (New-Object System.Text.UTF8Encoding($false))
    )
    Write-Host "已写入 $PubspecPath" -ForegroundColor Green
}
