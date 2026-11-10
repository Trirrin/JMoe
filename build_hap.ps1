# HAP 构建脚本（Windows / PowerShell）
#
# 一键构建 HarmonyOS 的 .hap 包。
#
# 前置条件（仓库里已记录详细说明见 PLATFORMS.md）：
#   1. Flutter OHOS SDK       → F:\_sdk\flutter-ohos-new   (Flutter 3.47.7 / Dart 3.13.5)
#   2. HarmonyOS 命令行工具   → F:\_sdk\ohos-win-cmdline\cmdline-win\command-line-tools
#      （必须是 **Windows 版**：含 sdk\default\hms\toolchains\lib\*.dll）
#
# 用法：
#   cd F:\_jm3\app
#   .\build_hap.ps1
#   .\build_hap.ps1 -Mode debug
#
# 产物：ohos\entry\build\default\outputs\default\entry-default-unsigned.hap
# 签名：默认未签名。要出可安装包，见 docs/SIGNING.md 的鸿蒙章节。

param(
    [string]$CmdLineTools = 'F:\_sdk\ohos-win-cmdline\cmdline-win\command-line-tools',
    [string]$FlutterOhos  = 'F:\_sdk\flutter-ohos-new',
    [string]$ProjectRoot  = 'F:\_jm3\app',
    [string]$TargetPlatform = 'ohos-arm64',
    [ValidateSet('release', 'debug', 'profile')]
    [string]$Mode = 'release',
    [string]$OutDir = 'G:\Downloads\test\jmoe-apk'
)

$ErrorActionPreference = 'Stop'

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

Step '1. 校验工具链'

$hvigorw = Join-Path $CmdLineTools 'bin\hvigorw.bat'
$ohpmDir = Join-Path $CmdLineTools 'ohpm\bin'
$sdkDir  = Join-Path $CmdLineTools 'sdk'
$nodeDir = Join-Path $CmdLineTools 'tool\node'

if (-not (Test-Path $hvigorw)) {
    Write-Host "找不到 hvigorw：$hvigorw" -ForegroundColor Red
    Write-Host '请用 -CmdLineTools 指定 Windows 版命令行工具的 command-line-tools 目录。'
    exit 1
}

# 关键：确认是 Windows 版 SDK（Linux 版缺这个 DLL，构建会在 CompileResource 失败）
$transcoder = Get-ChildItem -Path $sdkDir -Recurse -Filter 'libimage_transcoder_shared.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $transcoder) {
    Write-Host '未找到 libimage_transcoder_shared.dll' -ForegroundColor Red
    Write-Host '  说明当前 SDK 是 Linux 版或组件不全，请下载 Windows 版命令行工具。'
    exit 1
}
Write-Host "  SDK: $sdkDir"
Write-Host "  transcoder: $transcoder"

if (-not (Test-Path $nodeDir)) {
    $sysNode = (Get-Command node -ErrorAction SilentlyContinue).Source
    if ($sysNode) { $nodeDir = Split-Path $sysNode }
    else { Write-Host '找不到 node' -ForegroundColor Red; exit 1 }
}

# flutter.har：ohos/har 必须非空，否则 ArkTS 报 @ohos/flutter_ohos 无法解析
$harDst = Join-Path $ProjectRoot 'ohos\har\flutter.har'
if (-not (Test-Path $harDst) -or (Get-Item $harDst).Length -lt 1MB) {
    Step '2. 补齐 flutter.har'
    $harSrc = Join-Path $FlutterOhos 'bin\cache\artifacts\engine\ohos-arm64-release\flutter.har'
    if (-not (Test-Path $harSrc)) {
        Write-Host "找不到 flutter.har：$harSrc" -ForegroundColor Red
        Write-Host '请先运行一次 flutter --version 让 OHOS SDK 下载引擎产物。'
        exit 1
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $harDst) | Out-Null
    Copy-Item $harSrc $harDst -Force
    Write-Host "  已复制: $harDst"
} else {
    Write-Host "  flutter.har 已存在"
}

Step '3. 配置环境变量'

$env:DEVECO_SDK_HOME = $sdkDir
$env:HOS_SDK_HOME    = $sdkDir
$env:NODE_HOME       = $nodeDir
$env:PATH = "$ohpmDir;$CmdLineTools\bin;$nodeDir;$FlutterOhos\bin;$env:PATH"

Write-Host "  DEVECO_SDK_HOME = $env:DEVECO_SDK_HOME"
Write-Host "  NODE_HOME       = $env:NODE_HOME"

Step '4. ohpm install（鸿蒙依赖）'
Push-Location (Join-Path $ProjectRoot 'ohos')
try {
    & (Join-Path $ohpmDir 'ohpm.bat') install
} finally {
    Pop-Location
}

Step "5. 构建 HAP ($Mode / $TargetPlatform)"
Push-Location $ProjectRoot
try {
    if (-not (Test-Path '.dart_tool\package_config.json')) {
        Write-Host '  先执行 flutter pub get ...'
        & "$FlutterOhos\bin\flutter.bat" pub get
    }

    & "$FlutterOhos\bin\flutter.bat" build hap "--$Mode" "--target-platform=$TargetPlatform"

    if ($LASTEXITCODE -ne 0) {
        Write-Host '构建失败。排查建议：' -ForegroundColor Red
        Write-Host '  * 查看日志：ohos\.hvigor\outputs\build-logs\build.log'
        Write-Host '  * 若报 SDK component missing：确认 build-profile.json5 的'
        Write-Host '    compatibleSdkVersion 与实际 SDK 版本一致（当前 SDK 为 26.0.0）'
        Write-Host '  * 若报 @ohos/flutter_ohos 无法解析：检查 ohos\har\flutter.har 是否存在'
        exit $LASTEXITCODE
    }
} finally {
    Pop-Location
}

Step '6. 收集产物'
$hap = Get-ChildItem -Path (Join-Path $ProjectRoot 'ohos\entry\build') -Recurse -Filter '*.hap' -ErrorAction SilentlyContinue |
       Where-Object { $_.FullName -notmatch 'oh_modules' } |
       Sort-Object LastWriteTime -Descending |
       Select-Object -First 1

if (-not $hap) {
    Write-Host '  未找到 .hap 产物' -ForegroundColor Yellow
    exit 1
}

Write-Host ("  源文件: {0}  ({1:N1} MB)" -f $hap.FullName, ($hap.Length / 1MB)) -ForegroundColor Green

if ($OutDir) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $ver = (Select-String -Path (Join-Path $ProjectRoot 'pubspec.yaml') -Pattern '^version:\s*(.+)').Matches[0].Groups[1].Value.Split('+')[0]
    $dstName = "JMoe-$ver-ohos-unsigned.hap"
    Copy-Item $hap.FullName (Join-Path $OutDir $dstName) -Force
    Write-Host ("  已复制: {0}" -f (Join-Path $OutDir $dstName)) -ForegroundColor Green
}

Write-Host "`n完成。" -ForegroundColor Green
