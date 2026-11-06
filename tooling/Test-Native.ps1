param(
    [string]$DeviceId = 'emulator-5554',
    [switch]$VerboseLogs,
    [ValidateSet('native_contract_test.dart', 'vpn_traffic_test.dart', 'settings_navigation_test.dart', 'profile_sort_test.dart', 'core_background_update_test.dart', 'subscription_diagnostic_test.dart', 'subscription_import_test.dart', 'subscription_hosts_test.dart')]
    [string]$TestFile = 'native_contract_test.dart',
    [string]$SubscriptionFile,
    [string[]]$ProfileEndpointIds = @()
)
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $PSScriptRoot
$workspaceEnvironment = Join-Path $appRoot '..\tools\Enter-MobileEnv.ps1'
if (Test-Path -LiteralPath $workspaceEnvironment -PathType Leaf) { . $workspaceEnvironment }
if (!$env:ANDROID_HOME) { throw 'Configure ANDROID_HOME and add Flutter to PATH before running native checks.' }
$previousDiagnosticFlag = $env:ORG_GRADLE_PROJECT_tachyonDiagnostics
$adbTool = Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe'
$mainPackage = 'dev.tachyon.tachyon_client'
$checksPackage = "$mainPackage.checks"
$testTarget = "integration_test/$TestFile"
$beforeMain = (& $adbTool -s $DeviceId shell pm path $mainPackage) -join "`n"
$checksVerified = $false
$nativeTestExit = 1
$deviceAbi = (& $adbTool -s $DeviceId shell getprop ro.product.cpu.abi).Trim()
$testPlatform = switch ($deviceAbi) {
    'x86_64' { 'android-x64' }
    'arm64-v8a' { 'android-arm64' }
    default { throw 'Native checks require an ARM64 or x86_64 Android device.' }
}
Push-Location $appRoot
try {
    $env:ORG_GRADLE_PROJECT_tachyonDiagnostics = 'true'
    # Flutter reads existing APK metadata before building its listener. Prebuild
    # the isolated package and prohibit the runner's automatic uninstall.
    & flutter.bat build apk --debug --target-platform $testPlatform --target $testTarget
    if ($LASTEXITCODE -ne 0) { throw 'Diagnostic APK preparation failed.' }
    $aapt = Join-Path $env:ANDROID_HOME 'build-tools\36.0.0\aapt2.exe'
    $badging = & $aapt dump badging build/app/outputs/flutter-apk/app-debug.apk
    if ($LASTEXITCODE -ne 0 -or !($badging -like "package: name='$checksPackage' *")) {
        throw 'The prepared APK is not the isolated checks package.'
    }
    $checksVerified = $true
    $oldChecks = (& $adbTool -s $DeviceId shell pm path $checksPackage) -join "`n"
    if ($oldChecks) { & $adbTool -s $DeviceId uninstall $checksPackage | Out-Null }
    if ($TestFile -in @('subscription_diagnostic_test.dart', 'subscription_import_test.dart', 'subscription_hosts_test.dart')) {
        if (!$SubscriptionFile -or !(Test-Path -LiteralPath $SubscriptionFile -PathType Leaf)) { throw 'A private subscription input file is required.' }
        & $adbTool -s $DeviceId install -r build/app/outputs/flutter-apk/app-debug.apk | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Diagnostic package installation failed.' }
        # Секрет передаётся только через stdin в приватные данные отдельного пакета.
        $copyInfo = [Diagnostics.ProcessStartInfo]::new($adbTool)
        $copyInfo.UseShellExecute = $false
        $copyInfo.CreateNoWindow = $true
        $copyInfo.RedirectStandardInput = $true
        $copyInfo.RedirectStandardOutput = $true
        $copyInfo.RedirectStandardError = $true
        foreach ($argument in @('-s', $DeviceId, 'shell', "run-as $checksPackage sh -c 'umask 077; mkdir -p files; cat > files/private-subscription-url'")) { $copyInfo.ArgumentList.Add($argument) }
        $copyProcess = [Diagnostics.Process]::new()
        $copyProcess.StartInfo = $copyInfo
        try {
            [void]$copyProcess.Start()
            $privateInput = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $SubscriptionFile).Path)
            if ($TestFile -eq 'subscription_hosts_test.dart' -and $ProfileEndpointIds.Count -gt 0) {
                if ($ProfileEndpointIds | Where-Object { $_ -notmatch '^[a-f0-9]{1,8}$' }) { throw 'Invalid endpoint diagnostic identifier.' }
                $privateInput = @{ url = $privateInput.Trim(); endpointIds = $ProfileEndpointIds } | ConvertTo-Json -Compress
            }
            $copyProcess.StandardInput.Write($privateInput)
            $copyProcess.StandardInput.Close()
            [void]$copyProcess.StandardOutput.ReadToEnd()
            [void]$copyProcess.StandardError.ReadToEnd()
            $copyProcess.WaitForExit()
            if ($copyProcess.ExitCode -ne 0) { throw 'Private diagnostic input transfer failed.' }
        } finally { $copyProcess.Dispose() }
    }
    $nativeTestArguments = @('test', $testTarget, '-d', $DeviceId, '--reporter', 'expanded', '--no-uninstall')
    if ($VerboseLogs) { $nativeTestArguments += '-v' }
    & flutter.bat @nativeTestArguments
    $nativeTestExit = $LASTEXITCODE
} finally {
    if ($checksVerified) { & $adbTool -s $DeviceId uninstall $checksPackage | Out-Null }
    $afterMain = (& $adbTool -s $DeviceId shell pm path $mainPackage) -join "`n"
    $env:ORG_GRADLE_PROJECT_tachyonDiagnostics = $previousDiagnosticFlag
    Pop-Location
    if ($beforeMain -and $beforeMain -ne $afterMain) { throw 'Native checks changed the main application installation.' }
}
exit $nativeTestExit
