<#
  Anvil: sets this Windows virtual machine up for Minecraft (Bedrock, the PC version).

  It shows what it will do and asks first. Then, as administrator:
    - takes out Windows' consumer extras (news, tips, promoted apps, Copilot, Teams and the like),
      keeping everything Minecraft needs: the Microsoft Store, the Xbox app, Gaming Services,
      the Xbox sign-in and the app installer;
    - turns off the widgets, suggestions, web results in Start and background start-ups that use
      the machine's time while you play, through Windows' own policy settings;
    - sets Windows for games: high-performance power, no sleep (Anvil puts the machine away
      instead), Game Mode on, background recording off;
    - installs Minecraft's own launcher from the Microsoft Store, and opens Minecraft whenever
      Windows signs in, once it's installed.
  Windows' security, updates and firewall are left exactly as they are.

  Run "Set up Minecraft.cmd undo" to put the settings back (apps it took out can be installed
  again from the Microsoft Store; they're listed in setup-log.txt).

  It writes what it did to status.json and setup-log.txt beside it, for Anvil's Minecraft page.
#>
param(
    [switch]$Undo,
    [switch]$Elevated
)

$ErrorActionPreference = 'Continue'
$work = Join-Path $env:ProgramData 'Anvil'
$script = Join-Path $work 'anvil-minecraft-setup.ps1'

# --- 1. As the player: a copy out of the shared folder, run as administrator, and what it wrote copied back. ---
if (-not $Elevated) {
    $share = $PSScriptRoot
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    Copy-Item -Force -LiteralPath $PSCommandPath -Destination $script
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-Elevated')
    if ($Undo) { $arguments += '-Undo' }
    try {
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -Wait -PassThru -ErrorAction Stop
    } catch {
        Write-Host 'Windows did not let the setup run as administrator, so nothing was changed.'
        Read-Host 'Press Enter to close'
        exit 1
    }
    foreach ($name in @('status.json', 'setup-log.txt')) {
        $from = Join-Path $work $name
        if (Test-Path -LiteralPath $from) { Copy-Item -Force -LiteralPath $from -Destination (Join-Path $share $name) }
    }
    exit $process.ExitCode
}

# --- 2. As administrator. ---
$log = Join-Path $work 'setup-log.txt'
$problems = @()
function Say([string]$text) {
    Write-Host $text
    Add-Content -LiteralPath $log -Value $text
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'This needs to run as administrator; nothing was changed.'
    Read-Host 'Press Enter to close'
    exit 1
}

# Consumer extras, by package name. Only these are ever taken out; anything matching $keep never is.
$extras = @(
    'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch', 'Microsoft.GetHelp', 'Microsoft.Getstarted',
    'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.MicrosoftOfficeHub', 'Microsoft.People', 'Microsoft.PowerAutomateDesktop',
    'Microsoft.Todos', 'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps', 'Microsoft.ZuneVideo', 'Microsoft.ZuneMusic',
    'Clipchamp.Clipchamp', 'MicrosoftTeams', 'MSTeams', 'Microsoft.OutlookForWindows', 'Microsoft.549981C3F5F10',
    'Microsoft.MicrosoftStickyNotes', 'Microsoft.WindowsAlarms', 'Microsoft.WindowsSoundRecorder', 'Microsoft.YourPhone',
    'Microsoft.Copilot', 'Microsoft.Windows.DevHome', 'MicrosoftCorporationII.QuickAssist', 'Microsoft.MicrosoftJournal',
    'MicrosoftWindows.CrossDevice',
    '*Spotify*', '*Disney*', '*LinkedIn*', '*TikTok*', '*Instagram*', '*Facebook*', '*CandyCrush*', '*king.com*', '*Netflix*',
    '*AmazonPrime*'
)
$keep = 'WindowsStore|StorePurchaseApp|GamingApp|GamingServices|XboxIdentityProvider|Xbox\.TCUI|XboxGamingOverlay|' +
        'DesktopAppInstaller|VCLibs|UI\.Xaml|NET\.Native|WindowsAppRuntime|SecHealthUI|Minecraft|4297127D64EC6|WebExperience'

# Windows' own policy and settings values: [hive path, value name, value while set up].
$values = @(
    @('HKLM:\SOFTWARE\Policies\Microsoft\Dsh', 'AllowNewsAndInterests', 0),
    @('HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot', 'TurnOffWindowsCopilot', 1),
    @('HKCU:\Software\Policies\Microsoft\Windows\Explorer', 'DisableSearchBoxSuggestions', 1),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent', 'DisableWindowsConsumerFeatures', 1),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent', 'DisableConsumerAccountStateContent', 1),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SilentInstalledAppsEnabled', 0),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SystemPaneSuggestionsEnabled', 0),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'PreInstalledAppsEnabled', 0),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'OemPreInstalledAppsEnabled', 0),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-338388Enabled', 0),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-338389Enabled', 0),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-353694Enabled', 0),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-353696Enabled', 0),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement', 'ScoobeSystemSettingEnabled', 0),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'StartupBoostEnabled', 0),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'BackgroundModeEnabled', 0),
    @('HKCU:\Software\Microsoft\GameBar', 'AutoGameModeEnabled', 1),
    @('HKCU:\Software\Microsoft\GameBar', 'AllowAutoGameMode', 1),
    @('HKCU:\System\GameConfigStore', 'GameDVR_Enabled', 0),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR', 'AppCaptureEnabled', 0)
)

$startScript = Join-Path $work 'start-minecraft.ps1'
$startup = [Environment]::GetFolderPath('Startup')
$shortcut = Join-Path $startup 'Minecraft (Anvil).lnk'

Set-Content -LiteralPath $log -Value ('Anvil Minecraft setup ' + $(if ($Undo) { '(undo) ' } else { '' }) + (Get-Date -Format s))

Write-Host ''
if ($Undo) {
    Write-Host 'Anvil will put back what its Minecraft setup changed:'
    Write-Host '  - the policy and settings values it set (widgets, Copilot, suggestions, Game Mode and the rest)'
    Write-Host '  - the balanced power plan, sleep after 30 minutes, the screen off after 10'
    Write-Host '  - Minecraft no longer opened as Windows signs in'
    Write-Host '  Apps it took out stay out; install any you want again from the Microsoft Store.'
} else {
    Write-Host 'Anvil will set this Windows up for Minecraft:'
    Write-Host '  - take out consumer extras (news, weather, tips, Solitaire, Teams, Clipchamp, Copilot, promoted apps)'
    Write-Host '    and keep the Microsoft Store, the Xbox app, Gaming Services and the Xbox sign-in'
    Write-Host '  - turn off widgets, suggestions, web results in Start and Edge running in the background'
    Write-Host '  - high-performance power with no sleep, Game Mode on, background recording off'
    Write-Host '  - install the Minecraft Launcher from the Microsoft Store'
    Write-Host '  - open Minecraft whenever Windows signs in, once it is installed'
    Write-Host '  Windows security, updates and the firewall are not touched.'
}
Write-Host ''
$answer = Read-Host 'Go ahead? Type Y and press Enter'
if ($answer -notmatch '^[Yy]') {
    Say 'Nothing changed: not confirmed.'
    exit 0
}

function Set-Dword([string]$path, [string]$name, [int]$value) {
    if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
    New-ItemProperty -LiteralPath $path -Name $name -Value $value -PropertyType DWord -Force | Out-Null
}

$removed = @()
$launcher = ''
$starts = $false

if ($Undo) {
    foreach ($v in $values) {
        try { Remove-ItemProperty -LiteralPath $v[0] -Name $v[1] -ErrorAction Stop; Say ('Put back: ' + $v[1]) } catch { }
    }
    powercfg /setactive SCHEME_BALANCED | Out-Null
    powercfg /change standby-timeout-ac 30 | Out-Null
    powercfg /change monitor-timeout-ac 10 | Out-Null
    Say 'Power: balanced, sleep after 30 minutes, the screen off after 10.'
    if (Test-Path -LiteralPath $shortcut) { Remove-Item -Force -LiteralPath $shortcut; Say 'Minecraft no longer opens as Windows signs in.' }
} else {
    # Extras out: for every account, and for accounts made later.
    foreach ($name in $extras) {
        $packages = @(Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch $keep })
        foreach ($p in $packages) {
            try {
                Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop
                $removed += $p.Name
                Say ('Took out: ' + $p.Name)
            } catch {
                try {
                    Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop
                    $removed += $p.Name
                    Say ('Took out: ' + $p.Name)
                } catch {
                    $problems += ('Could not take out ' + $p.Name + ': ' + $_.Exception.Message)
                }
            }
        }
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $name -and $_.DisplayName -notmatch $keep } |
            ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null }
    }
    $removed = @($removed | Select-Object -Unique)

    foreach ($v in $values) {
        try { Set-Dword $v[0] $v[1] $v[2] } catch { $problems += ('Could not set ' + $v[1] + ': ' + $_.Exception.Message) }
    }
    Say 'Widgets, Copilot, suggestions and background start-ups off; Game Mode on; background recording off.'
    # OneDrive and Teams no longer start with Windows (OneDrive itself is kept).
    foreach ($runName in @('OneDrive', 'com.squirrel.Teams.Teams', 'MicrosoftTeams')) {
        Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $runName -ErrorAction SilentlyContinue
    }

    powercfg /setactive SCHEME_MIN | Out-Null
    powercfg /change standby-timeout-ac 0 | Out-Null
    powercfg /change monitor-timeout-ac 0 | Out-Null
    powercfg /hibernate off | Out-Null
    Say 'Power: high performance, no sleep (Anvil puts the machine away instead).'

    # Minecraft's own launcher, from the Microsoft Store.
    if (Get-AppxPackage -Name 'Microsoft.4297127D64EC6' -ErrorAction SilentlyContinue) {
        $launcher = 'already installed'
    } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
        Say 'Installing the Minecraft Launcher from the Microsoft Store...'
        & winget install --id 9PGW18NPBZV5 --source msstore --accept-package-agreements --accept-source-agreements --silent | Out-Host
        if ($LASTEXITCODE -eq 0) { $launcher = 'installed' } else { $launcher = 'winget could not install it (' + $LASTEXITCODE + ')' }
    } else {
        $launcher = 'winget is not on this Windows'
    }
    if ($launcher -notmatch '^(installed|already installed)$') {
        Start-Process 'ms-windows-store://pdp/?ProductId=9PGW18NPBZV5'
        $launcher += '; the Store page opened instead'
    }
    Say ('Minecraft Launcher: ' + $launcher)

    # Minecraft at sign-in: a small script that opens Bedrock if it's installed, from the Startup folder.
    $starter = @(
        '# Anvil: opens Minecraft (Bedrock) as Windows signs in, once it is installed.',
        'Start-Sleep -Seconds 3',
        '$app = Get-StartApps | Where-Object { $_.Name -match ''^Minecraft( for Windows)?$'' } | Select-Object -First 1',
        'if ($app) { Start-Process explorer.exe (''shell:AppsFolder\'' + $app.AppID) }',
        'elseif (Get-AppxPackage -Name ''Microsoft.MinecraftUWP'' -ErrorAction SilentlyContinue) { Start-Process ''minecraft:'' }'
    )
    Set-Content -LiteralPath $startScript -Value $starter
    try {
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($shortcut)
        $link.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $link.Arguments = '-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "' + $startScript + '"'
        $link.WindowStyle = 7
        $link.Description = 'Opens Minecraft as Windows signs in (Anvil)'
        $link.Save()
        $starts = $true
        Say 'Minecraft opens whenever Windows signs in, once it is installed.'
    } catch {
        $problems += ('Could not add Minecraft to sign-in: ' + $_.Exception.Message)
    }
}

# What there is now, for Anvil's page.
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$minecraft = @(Get-AppxPackage -Name '*Minecraft*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name + ' ' + $_.Version })
$graphics = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
$pattern = 'game|controller|gamepad|joystick|xbox|nintendo|switch|powera'
$controllers = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match $pattern } |
    ForEach-Object { $_.FriendlyName + ' (' + $_.Status + ')' } | Select-Object -Unique)
$report = [ordered]@{
    version         = 1
    finished        = (Get-Date).ToString('s')
    undone          = [bool]$Undo
    windows         = $(if ($os) { $os.Caption + ' ' + $os.Version } else { '' })
    arch            = $env:PROCESSOR_ARCHITECTURE
    removed         = $removed
    launcher        = $launcher
    minecraft       = ($minecraft -join ', ')
    startsMinecraft = $starts
    graphics        = $graphics
    controllers     = $controllers
    problems        = $problems
}
$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $work 'status.json') -Encoding UTF8
foreach ($p in $problems) { Say ('Problem: ' + $p) }

Write-Host ''
if ($Undo) {
    Write-Host 'Done: put back.'
} else {
    Write-Host 'Done. Now sign in to the Minecraft Launcher with your Microsoft account and install Minecraft for Windows.'
    Write-Host 'From then on it opens by itself whenever Windows signs in, and Anvil resumes the machine inside the game.'
}
Read-Host 'Press Enter to close'
exit 0
