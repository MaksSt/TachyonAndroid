param(
    [switch]$Debug,
    [ValidateSet('arm64', 'x64', 'universal')]
    [string]$Architecture = 'arm64'
)
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $PSScriptRoot
$workspaceEnvironment = Join-Path $appRoot '..\tools\Enter-MobileEnv.ps1'
if (Test-Path -LiteralPath $workspaceEnvironment -PathType Leaf) { . $workspaceEnvironment }
if (!$env:ANDROID_HOME) { throw 'Configure ANDROID_HOME and add Flutter to PATH before building.' }
$buildDate = Get-Date
$manifest = Get-Content -LiteralPath (Join-Path $appRoot 'pubspec.yaml') -Raw
$version = [regex]::Match($manifest, '(?m)^version:\s*(\d+\.\d+\.\d+)\+([1-9]\d*)\s*$')
if (!$version.Success) { throw 'Expected version: MAJOR.MINOR.PATCH+BUILD in pubspec.yaml.' }
$versionName = $version.Groups[1].Value
$manifestBuild = [long]$version.Groups[2].Value
$dayKey = $buildDate.ToString('yyyy-MM-dd')
$localRoot = Join-Path $appRoot '.local'
New-Item -ItemType Directory -Force $localRoot | Out-Null
$sequencePath = Join-Path $localRoot 'build-version.json'
$previousBuild = if (Test-Path -LiteralPath $sequencePath) { Get-Content -LiteralPath $sequencePath -Raw | ConvertFrom-Json } else { $null }
$sequence = if ($previousBuild) { [long]$previousBuild.sequence + 1 } else { 1 }
# После перехода с версий по дате нельзя уменьшать Android versionCode.
$versionCode = if ($previousBuild) { [Math]::Max($manifestBuild, [long]$previousBuild.versionCode + 1) } else { $manifestBuild }
if ($versionCode -gt 2100000000) { throw 'The Android versionCode limit is exhausted.' }
$buildMode = if ($Debug) { 'debug' } else { 'release' }
$targetPlatform = switch ($Architecture) {
    'arm64' { 'android-arm64' }
    'x64' { 'android-x64' }
    'universal' { 'android-arm64,android-x64' }
}
$abi = switch ($Architecture) {
    'arm64' { 'arm64-v8a' }
    'x64' { 'x86_64' }
}
Push-Location $appRoot
try {
    & flutter.bat build apk "--$buildMode" --target-platform $targetPlatform --build-name $versionName --build-number $versionCode
    if ($LASTEXITCODE -ne 0) { throw 'Android build failed.' }
    $artifact = "build/app/outputs/flutter-apk/app-$buildMode.apk"
    $verificationArgs = @('tooling/verify_apk.py', $artifact)
    if ($abi) { $verificationArgs += @('--abi', $abi) }
    & python @verificationArgs
    if ($LASTEXITCODE -ne 0) { throw 'Native artifact verification failed.' }
    & (Join-Path $env:ANDROID_HOME 'build-tools\36.0.0\apksigner.bat') verify $artifact
    if ($LASTEXITCODE -ne 0) { throw 'APK signature verification failed.' }
    $badging = & (Join-Path $env:ANDROID_HOME 'build-tools\36.0.0\aapt2.exe') dump badging $artifact
    if ($LASTEXITCODE -ne 0 -or !($badging -like "package: name='dev.tachyon.tachyon_client' versionCode='$versionCode' versionName='$versionName' *")) {
        throw 'APK package/version does not match this build.'
    }
    $exportRoot = Join-Path $localRoot 'exports'
    New-Item -ItemType Directory -Force $exportRoot | Out-Null
    $export = Join-Path $exportRoot "TachyonClient-$versionName-$Architecture-b$sequence.apk"
    Copy-Item -LiteralPath $artifact -Destination $export -Force
    $digest = (Get-FileHash -LiteralPath $export -Algorithm SHA256).Hash.ToLowerInvariant()
    @{ day = $dayKey; sequence = $sequence; versionName = $versionName; versionCode = $versionCode; architecture = $Architecture; apk = $export; sha256 = $digest } |
        ConvertTo-Json | Set-Content -LiteralPath $sequencePath -Encoding utf8
    Write-Output "APK: $export"
    Write-Output "Version: $versionName; build: $sequence; versionCode: $versionCode"
    Write-Output "SHA256: $digest"
} finally { Pop-Location }
