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

# 兼容 DevEco Studio 6.x 与 5.x 的环境变量命名，并兜底查找常见安装路径
$candidateSdkHomes = @(
    $env:HOS_SDK_HOME,
    $env:DEVECO_SDK_HOME,
    (Join-Path $env:LOCALAPPDATA 'Huawei\Sdk'),
    'D:\REINs\Applications\DevEco Studio\sdk',
    'C:\Program Files\Huawei\DevEco Studio\sdk',
    'C:\Program Files (x86)\Huawei\DevEco Studio\sdk'
)
$sdkHome = $candidateSdkHomes | Where-Object { $_ -and (Test-Path $_) -and (Test-Path (Join-Path $_ 'default')) } | Select-Object -First 1
if (-not $sdkHome) {
    throw '未找到 HarmonyOS SDK。请设置 HOS_SDK_HOME 或 DEVECO_SDK_HOME 环境变量，指向 DevEco Studio 安装目录下的 sdk 文件夹。'
}
$env:HOS_SDK_HOME = $sdkHome
$env:DEVECO_SDK_HOME = $sdkHome

$signingPassword = 'GzusDebugSigningPassword20260620!X'
$signingDir = Join-Path $PSScriptRoot 'ohos' 'signing' 'debug'
$signedHap = Join-Path $PSScriptRoot 'build' 'ohos' 'outputs' 'default' 'entry-default-signed.hap'
$unsignedHap = Join-Path $PSScriptRoot 'ohos' 'entry' 'build' 'default' 'outputs' 'default' 'entry-default-unsigned.hap'
$verifyCertChain = Join-Path (Split-Path -Parent $signedHap) 'outCertChain.cer'
$verifyProfile = Join-Path (Split-Path -Parent $signedHap) 'outProfile.p7b'
$signTool = Join-Path $sdkHome 'default' 'openharmony' 'toolchains' 'lib' 'hap-sign-tool.jar'

# DevEco Studio 命令行工具路径
$devecoHome = Split-Path -Parent $sdkHome
$candidatePaths = @(
    (Join-Path $devecoHome 'tools' 'ohpm' 'bin'),
    (Join-Path $devecoHome 'tools' 'hvigor' 'bin'),
    (Join-Path $devecoHome 'tools' 'node' 'bin')
)
foreach ($p in $candidatePaths) {
    if (Test-Path $p) {
        $env:PATH = "$p;$env:PATH"
    }
}

function Get-JavaExecutable {
    $candidates = @(
        (Join-Path $devecoHome 'jbr' 'bin' 'java.exe'),
        (Join-Path $devecoHome 'jbr' 'bin' 'java'),
        'java'
    )
    foreach ($candidate in $candidates) {
        if ($candidate -eq 'java' -or (Test-Path $candidate)) {
            return $candidate
        }
    }
    throw '未找到 Java 运行时，无法调用 hap-sign-tool。'
}

$javaExe = Get-JavaExecutable

function Invoke-SignTool {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ToolArgs)

    if (-not (Test-Path $signTool)) {
        throw "未找到 hap-sign-tool.jar: $signTool"
    }

    & $javaExe -jar $signTool @ToolArgs
    if ($LASTEXITCODE -ne 0) {
        throw "hap-sign-tool 执行失败，退出码: $LASTEXITCODE"
    }
}

function Write-DebugProfile {
    param([string]$ProfilePath, [string]$AppCertPath)

    $certLines = @()
    foreach ($line in Get-Content -Path $AppCertPath) {
        $certLines += $line
        if ($line -eq '-----END CERTIFICATE-----') {
            break
        }
    }
    $cert = (($certLines -join "`n") + "`n") -replace "`n", "\n"
    $now = [DateTimeOffset]::Now.AddDays(-1).ToUnixTimeSeconds()
    $expires = [DateTimeOffset]::Now.AddYears(10).ToUnixTimeSeconds()
    $uuid = [guid]::NewGuid().ToString()
    $json = @"
{
  "version-name": "2.0.0",
  "version-code": 2,
  "uuid": "$uuid",
  "validity": {
    "not-before": $now,
    "not-after": $expires
  },
  "type": "debug",
  "bundle-info": {
    "developer-id": "GZUS",
    "development-certificate": "$cert",
    "bundle-name": "cn.gzus.pro.ohos",
    "apl": "normal",
    "app-feature": "hos_normal_app"
  },
  "acls": {
    "allowed-acls": []
  },
  "permissions": {
    "restricted-permissions": []
  },
  "debug-info": {
    "device-ids": [],
    "device-id-type": "udid"
  },
  "issuer": "pki_internal"
}
"@
    Set-Content -Path $ProfilePath -Value $json -Encoding ascii
}

function Ensure-LocalSigningMaterials {
    $required = @(
        'debug-app.p12',
        'app-debug-cert.cer',
        'debug-profile.p7b'
    )
    $hasAll = $true
    foreach ($name in $required) {
        if (-not (Test-Path (Join-Path $signingDir $name))) {
            $hasAll = $false
            break
        }
    }
    if ($hasAll) {
        return
    }

    Write-Host "==> 正在生成本地调试签名材料..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $signingDir | Out-Null

    $knownFiles = @(
        'debug-ca.p12', 'debug-app.p12', 'debug-profile.p12',
        'root-ca.cer', 'sub-app-ca.cer', 'sub-profile-ca.cer',
        'app-debug-cert.cer', 'profile-debug-cert.cer',
        'debug-profile.json', 'debug-profile.p7b',
        'verify-profile.json', 'outCertChain.cer', 'outProfile.p7b'
    )
    foreach ($name in $knownFiles) {
        $path = Join-Path $signingDir $name
        if (Test-Path $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }

    $rootSubject = 'C=CN,O=GZUS,OU=OneGZUS,CN=OneGZUS Debug Root CA'
    $appCaSubject = 'C=CN,O=GZUS,OU=OneGZUS,CN=Application Debug Signature Service CA'
    $profileCaSubject = 'C=CN,O=GZUS,OU=OneGZUS,CN=Provision Profile Debug Signature Service CA'
    $appSubject = 'C=CN,O=GZUS,OU=OneGZUS,CN=OneGZUS Debug'
    $profileSubject = 'C=CN,O=GZUS,OU=OneGZUS,CN=OneGZUS Debug Profile'
    $caStore = Join-Path $signingDir 'debug-ca.p12'
    $appStore = Join-Path $signingDir 'debug-app.p12'
    $profileStore = Join-Path $signingDir 'debug-profile.p12'
    $rootCert = Join-Path $signingDir 'root-ca.cer'
    $appCaCert = Join-Path $signingDir 'sub-app-ca.cer'
    $profileCaCert = Join-Path $signingDir 'sub-profile-ca.cer'
    $appCert = Join-Path $signingDir 'app-debug-cert.cer'
    $profileCert = Join-Path $signingDir 'profile-debug-cert.cer'
    $profileJson = Join-Path $signingDir 'debug-profile.json'
    $profileP7b = Join-Path $signingDir 'debug-profile.p7b'

    Invoke-SignTool generate-ca -keyAlias debug-root-ca-key -keyPwd $signingPassword -keyAlg ECC -keySize NIST-P-256 -subject $rootSubject -validity 3650 -signAlg SHA256withECDSA -keystoreFile $caStore -keystorePwd $signingPassword -outFile $rootCert
    Invoke-SignTool generate-ca -keyAlias debug-app-ca-key -keyPwd $signingPassword -keyAlg ECC -keySize NIST-P-256 -issuer $rootSubject -issuerKeyAlias debug-root-ca-key -issuerKeyPwd $signingPassword -subject $appCaSubject -validity 3650 -signAlg SHA256withECDSA -keystoreFile $caStore -keystorePwd $signingPassword -issuerKeystoreFile $caStore -issuerKeystorePwd $signingPassword -outFile $appCaCert
    Invoke-SignTool generate-ca -keyAlias debug-profile-ca-key -keyPwd $signingPassword -keyAlg ECC -keySize NIST-P-256 -issuer $rootSubject -issuerKeyAlias debug-root-ca-key -issuerKeyPwd $signingPassword -subject $profileCaSubject -validity 3650 -signAlg SHA256withECDSA -keystoreFile $caStore -keystorePwd $signingPassword -issuerKeystoreFile $caStore -issuerKeystorePwd $signingPassword -outFile $profileCaCert
    Invoke-SignTool generate-keypair -keyAlias debug-app-key -keyPwd $signingPassword -keyAlg ECC -keySize NIST-P-256 -keystoreFile $appStore -keystorePwd $signingPassword
    Invoke-SignTool generate-keypair -keyAlias debug-profile-key -keyPwd $signingPassword -keyAlg ECC -keySize NIST-P-256 -keystoreFile $profileStore -keystorePwd $signingPassword
    Invoke-SignTool generate-app-cert -keyAlias debug-app-key -keyPwd $signingPassword -issuer $appCaSubject -issuerKeyAlias debug-app-ca-key -issuerKeyPwd $signingPassword -subject $appSubject -validity 3650 -signAlg SHA256withECDSA -rootCaCertFile $rootCert -subCaCertFile $appCaCert -keystoreFile $appStore -keystorePwd $signingPassword -issuerKeystoreFile $caStore -issuerKeystorePwd $signingPassword -outForm certChain -outFile $appCert
    Invoke-SignTool generate-profile-cert -keyAlias debug-profile-key -keyPwd $signingPassword -issuer $profileCaSubject -issuerKeyAlias debug-profile-ca-key -issuerKeyPwd $signingPassword -subject $profileSubject -validity 3650 -signAlg SHA256withECDSA -rootCaCertFile $rootCert -subCaCertFile $profileCaCert -keystoreFile $profileStore -keystorePwd $signingPassword -issuerKeystoreFile $caStore -issuerKeystorePwd $signingPassword -outForm certChain -outFile $profileCert
    Write-DebugProfile -ProfilePath $profileJson -AppCertPath $appCert
    Invoke-SignTool sign-profile -mode localSign -keyAlias debug-profile-key -keyPwd $signingPassword -profileCertFile $profileCert -inFile $profileJson -signAlg SHA256withECDSA -keystoreFile $profileStore -keystorePwd $signingPassword -outFile $profileP7b
    Invoke-SignTool verify-profile -inFile $profileP7b -outFile (Join-Path $signingDir 'verify-profile.json')
}

function Sign-Hap {
    if (-not (Test-Path $unsignedHap)) {
        throw "未找到 unsigned HAP: $unsignedHap"
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $signedHap) | Out-Null
    foreach ($path in @($signedHap, $verifyCertChain, $verifyProfile)) {
        if (Test-Path $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }

    Write-Host "==> 正在签名 HAP..." -ForegroundColor Cyan
    Invoke-SignTool sign-app -mode localSign -keyAlias debug-app-key -keyPwd $signingPassword -appCertFile (Join-Path $signingDir 'app-debug-cert.cer') -profileFile (Join-Path $signingDir 'debug-profile.p7b') -inFile $unsignedHap -signAlg SHA256withECDSA -keystoreFile (Join-Path $signingDir 'debug-app.p12') -keystorePwd $signingPassword -outFile $signedHap -compatibleVersion 12 -signCode 1
    Invoke-SignTool verify-app -inFile $signedHap -outCertChain $verifyCertChain -outProfile $verifyProfile
}

Set-Location $PSScriptRoot

Ensure-LocalSigningMaterials

Write-Host "==> 正在获取 Flutter 依赖..." -ForegroundColor Cyan
flutter pub get
if ($LASTEXITCODE -ne 0) {
    Write-Warning "flutter pub get 在线模式失败，尝试使用本地 Pub 缓存重试..."
    flutter pub get --offline
    if ($LASTEXITCODE -ne 0) {
        throw "flutter pub get 失败，退出码: $LASTEXITCODE"
    }
}

Write-Host "==> 正在构建 HarmonyOS HAP ($Mode)..." -ForegroundColor Cyan
flutter build hap --$Mode --dart-define=API_BASE_URL=$ApiUrl
if ($LASTEXITCODE -ne 0) {
    if (-not (Test-Path $unsignedHap)) {
        throw "flutter build hap 失败且未生成 unsigned HAP，退出码: $LASTEXITCODE"
    }
    Write-Warning "flutter build hap 在 DevEco 签名阶段返回 $LASTEXITCODE；已生成 unsigned HAP，继续本地签名。"
}

Sign-Hap
$hap = Get-Item $signedHap

Write-Host "==> 构建完成: $($hap.FullName)" -ForegroundColor Green
