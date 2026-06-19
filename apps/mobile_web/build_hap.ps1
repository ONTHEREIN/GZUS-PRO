# 软帮手 HarmonyOS HAP 构建脚本
# 前置条件：安装 DevEco Studio 并配置好 HOS_SDK_HOME / DEVECO_SDK_HOME 环境变量

param(
    [ValidateSet('debug', 'release')]
    [string]$Mode = 'release',
    [string]$ApiUrl = 'https://onegzus.cc.cd/api,https://onegzus-onweb.pages.dev/api'
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$flutterOhos = Join-Path $repoRoot 'tools' 'flutter_ohos_3.22.0'

if (-not (Test-Path $flutterOhos)) {
    throw "鸿蒙版 Flutter SDK 未找到: $flutterOhos。请先运行 tools/setup_flutter_ohos.ps1 或手动克隆。"
}

$env:FLUTTER_HOME = $flutterOhos
$env:PATH = "$flutterOhos\bin;$env:PATH"
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:FLUTTER_OHOS_STORAGE_BASE_URL = 'https://flutter-ohos.obs.cn-south-1.myhuaweicloud.com'
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:FLUTTER_GIT_URL = 'https://gitcode.com/openharmony-tpc/flutter_flutter.git'

# 兼容 DevEco Studio 6.x 与 5.x 的环境变量命名
$sdkHome = $env:HOS_SDK_HOME, $env:DEVECO_SDK_HOME | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $sdkHome) {
    throw '未找到 HarmonyOS SDK。请设置 HOS_SDK_HOME 或 DEVECO_SDK_HOME 环境变量，指向 DevEco Studio 安装目录下的 sdk 文件夹。'
}

# DevEco Studio 命令行工具路径
$candidatePaths = @(
    (Join-Path $sdkHome '..' 'tools' 'ohpm' 'bin'),
    (Join-Path $sdkHome '..' 'tools' 'hvigor' 'bin'),
    (Join-Path $sdkHome '..' 'tools' 'node' 'bin')
)
foreach ($p in $candidatePaths) {
    if (Test-Path $p) {
        $env:PATH = "$p;$env:PATH"
    }
}

Set-Location $PSScriptRoot

Write-Host "==> 正在获取 Flutter 依赖..." -ForegroundColor Cyan
flutter pub get

Write-Host "==> 正在构建 HarmonyOS HAP ($Mode)..." -ForegroundColor Cyan
flutter build hap --$Mode --dart-define=API_BASE_URL=$ApiUrl

Write-Host "==> 构建完成，产物位于 build/ohos/outputs/default/" -ForegroundColor Green
