# SpicetifyManager.ps1 - Spicetify lifecycle manager for Windows.
# Requires PowerShell 5.1+ (7+ recommended). Run as Administrator.
# Usage: powershell -ExecutionPolicy Bypass -File .\SpicetifyManager.ps1 [-NoUI] [-Repair] [-Uninstall] [-Diagnose]

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$NoUI,
    [switch]$Repair,
    [switch]$Uninstall,
    [switch]$KeepLog,
    [switch]$FromLauncher,
    [switch]$Diagnose,
    [int]$MaxRetries = 3,
    [int]$RetryDelayMs = 2000,
    [int]$ProcessTimeoutMs = 90000,
    [string]$LogPath,
    [string]$CacheDir,
    [int]$BackupRetention = 3,
    [switch]$SkipPreflight
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

try {
    $tlsFlags = [Net.SecurityProtocolType]::Tls12
    $tls13Enum = [Net.SecurityProtocolType]::Tls13
    if ($null -ne $tls13Enum) {
        $tlsFlags = $tlsFlags -bor $tls13Enum
    }
} catch {
    # Tls13 not available -- Tls12 alone is sufficient
}
[Net.ServicePointManager]::SecurityProtocol = $tlsFlags

# PowerShell version gate (5.1 minimum, 7+ recommended)
if ($PSVersionTable.PSVersion -lt [version]'5.1') {
    Write-Host 'PowerShell 5.1+ is required. Detected: ' -NoNewline -ForegroundColor Red
    Write-Host $PSVersionTable.PSVersion.ToString() -ForegroundColor Yellow
    exit 64
}

$Script:FailedAssemblies = New-Object System.Collections.Generic.List[string]
foreach ($asm in @('System.IO.Compression.FileSystem', 'PresentationCore', 'PresentationFramework', 'WindowsBase', 'System.Xaml')) {
    try {
        Add-Type -AssemblyName $asm -ErrorAction Stop
    } catch {
        $Script:FailedAssemblies.Add($asm)
    }
}

$Script:ScriptVersion   = '1.0.0'
$Script:ScriptRepo      = 'Dalbouh02/SpicetifyManager'  # for self-update check

$Script:AppStateDir     = Join-Path $env:APPDATA 'SpicetifyManager'
$Script:ConfigPath      = Join-Path $Script:AppStateDir 'config.json'
$Script:StatsPath       = Join-Path $Script:AppStateDir 'stats.json'
$Script:WindowStatePath = Join-Path $Script:AppStateDir 'windowstate.json'

$configLogFilePath = if ($LogPath) { $LogPath } else { Join-Path $env:TEMP "SpicetifyManager_$(Get-Date -Format 'yyyyMMdd').log" }
$configCacheDir    = if ($null -ne $CacheDir -and $CacheDir -ne '' -and $CacheDir -ine 'none') { $CacheDir } else { Join-Path $env:LOCALAPPDATA 'spicetify\cache' }
$configEnableCache = -not ($null -ne $CacheDir -and ($CacheDir -ieq 'none' -or $CacheDir -eq ''))
$configMaxRetries  = if ($MaxRetries -lt 0) { 0 } else { $MaxRetries }
$configRetryDelay  = if ($RetryDelayMs -lt 0) { 0 } else { $RetryDelayMs }
$configProcTimeout = if ($ProcessTimeoutMs -lt 5000) { 5000 } else { $ProcessTimeoutMs }
$configRetention   = if ($BackupRetention -lt 1) { 1 } else { $BackupRetention }

$Script:Config = [PSCustomObject]@{
    AppDataPath       = Join-Path $env:APPDATA 'spicetify'
    SpicetifyExePath  = Join-Path $env:LOCALAPPDATA 'spicetify\spicetify.exe'
    MarketplaceDest   = Join-Path $env:APPDATA 'spicetify\CustomApps\marketplace'
    SpotifyExePath    = Join-Path $env:APPDATA 'Spotify\Spotify.exe'
    SpotifyInstallDir = Join-Path $env:APPDATA 'Spotify'
    # Microsoft Store Spotify -- Spicetify cannot modify this version
    SpotifyStorePath  = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\Spotify.exe'
    BackupDir         = Join-Path $env:APPDATA 'spicetify\Backup'
    # History lives OUTSIDE the Spicetify data dir so an uninstall preserves it
    BackupHistoryDir  = Join-Path $Script:AppStateDir 'BackupHistory'
    LogFilePath       = $configLogFilePath
    CacheDir          = $configCacheDir
    MaxRetries        = $configMaxRetries
    RetryDelayMs      = $configRetryDelay
    ProcessTimeoutMs  = $configProcTimeout
    FileLockRetries   = 20
    FileLockDelayMs   = 500
    BackupRetention   = $configRetention
    EnableCache       = $configEnableCache
    MinDiskSpaceMB    = 200
}

$Script:StagingPath    = $null
$Script:StagingValid   = $false
$Script:TempFiles      = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$Script:CurrentPhase   = 'Init'
$Script:PhaseStartTime = $null
$Script:PhaseTimings   = [System.Collections.Generic.Dictionary[string, TimeSpan]]::new()
$Script:CancelRequested = $false
$Script:RunspaceState   = $null
$Script:CompletionTimer = $null  # shared completion poller (single instance)

# Track whether the log path was explicitly customized (persisted only when true)
$Script:LogPathCustomized = $PSBoundParameters.ContainsKey('LogPath')

$Script:SettingsLimits = @{
    MaxRetriesMin       = 0
    MaxRetriesMax       = 10
    RetryDelayMin       = 100
    RetryDelayMax       = 30000
    ProcTimeoutMin      = 5000
    ProcTimeoutMax      = 600000
    RetentionMin        = 1
    RetentionMax        = 50
}

# Exit codes (reserved range 1-99). Keys match orchestrator phase names exactly.
$Script:ExitCodes = @{
    Init            = 1
    Preflight       = 2
    Backup          = 3
    SpotifyInstall  = 4
    SpicetifyInstall = 5
    Marketplace     = 6
    Apply           = 7
    Uninstall       = 8
    Restore         = 9
    Cancelled       = 10
    StoreSpotify    = 11
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'DEBUG')][string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $entry     = "[$timestamp] [$Level] $Message"

    # Append to log file with retry on transient locks (two runspaces may write)
    $maxAttempts = 3
    for ($i = 1; $i -le $maxAttempts; $i++) {
        try {
            Add-Content -Path $Script:Config.LogFilePath -Value $entry -ErrorAction Stop
            break
        } catch {
            if ($i -eq $maxAttempts) { break }
            Start-Sleep -Milliseconds 100
        }
    }

    if ($null -ne $Script:LogStream) {
        try {
            $Script:LogStream.Enqueue([PSCustomObject]@{
                Time  = $timestamp
                Level = $Level
                Msg   = $Message
            })
        } catch { }
    }
}

function Write-Step {
    [CmdletBinding()]
    param(
        [string]$Message,
        [ValidateSet('OK', 'WARN', 'ERR', 'INFO', 'STEP')][string]$Type = 'INFO'
    )

    $logLevel = switch ($Type) {
        'OK'   { 'SUCCESS' }
        'ERR'  { 'ERROR' }
        'WARN' { 'WARN' }
        default { 'INFO' }
    }

    if (-not $Script:NoUI -and $Script:GUIActive) {
        Write-Log -Message $Message -Level $logLevel
    } else {
        $prefix = switch ($Type) {
            'OK'   { '[OK]    ' }
            'WARN' { '[!]     ' }
            'ERR'  { '[X]     ' }
            'STEP' { '[...]   ' }
            default{ '[i]     ' }
        }
        $color = switch ($Type) {
            'OK'   { 'Green' }
            'WARN' { 'Yellow' }
            'ERR'  { 'Red' }
            'STEP' { 'Cyan' }
            default{ 'White' }
        }
        Write-Host "$prefix$Message" -ForegroundColor $color
        Write-Log -Message $Message -Level $logLevel
    }
}

function Get-ClampedInt {
    param(
        $Value,
        [int]$Fallback,
        [int]$Min,
        [int]$Max
    )
    $parsed = 0
    if (-not [int]::TryParse("$Value", [ref]$parsed)) { $parsed = $Fallback }
    if ($parsed -lt $Min) { $parsed = $Min }
    if ($parsed -gt $Max) { $parsed = $Max }
    return $parsed
}

function Load-Config {
    [CmdletBinding()]
    param([System.Collections.Generic.HashSet[string]]$BoundParams)

    if (-not (Test-Path -LiteralPath $Script:ConfigPath)) { return }

    try {
        $savedConfig = Get-Content -Path $Script:ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json

        $limits = $Script:SettingsLimits

        if ($null -ne $savedConfig.MaxRetries -and -not $BoundParams.Contains('MaxRetries')) {
            $Script:Config.MaxRetries = Get-ClampedInt -Value $savedConfig.MaxRetries -Fallback $Script:Config.MaxRetries -Min $limits.MaxRetriesMin -Max $limits.MaxRetriesMax
        }
        if ($null -ne $savedConfig.RetryDelayMs -and -not $BoundParams.Contains('RetryDelayMs')) {
            $Script:Config.RetryDelayMs = Get-ClampedInt -Value $savedConfig.RetryDelayMs -Fallback $Script:Config.RetryDelayMs -Min $limits.RetryDelayMin -Max $limits.RetryDelayMax
        }
        if ($null -ne $savedConfig.ProcessTimeoutMs -and -not $BoundParams.Contains('ProcessTimeoutMs')) {
            $Script:Config.ProcessTimeoutMs = Get-ClampedInt -Value $savedConfig.ProcessTimeoutMs -Fallback $Script:Config.ProcessTimeoutMs -Min $limits.ProcTimeoutMin -Max $limits.ProcTimeoutMax
        }
        if ($null -ne $savedConfig.BackupRetentionDays -and -not $BoundParams.Contains('BackupRetention')) {
            $Script:Config.BackupRetention = Get-ClampedInt -Value $savedConfig.BackupRetentionDays -Fallback $Script:Config.BackupRetention -Min $limits.RetentionMin -Max $limits.RetentionMax
        }
        if ($savedConfig.LogPath -and -not $BoundParams.Contains('LogPath')) {
            $Script:Config.LogFilePath = [string]$savedConfig.LogPath
            $Script:LogPathCustomized = $true
        }
        if ($null -ne $savedConfig.CacheDir -and -not $BoundParams.Contains('CacheDir')) {
            $dirValue = [string]$savedConfig.CacheDir
            if ($dirValue -ieq 'none') {
                $Script:Config.EnableCache = $false
            } elseif ($dirValue -ne '') {
                $Script:Config.CacheDir    = $dirValue
                $Script:Config.EnableCache = $true
            }
        }
        if ($null -ne $savedConfig.KeepLogFile) {
            $Script:KeepLog = [bool]$savedConfig.KeepLogFile
        }
        if ($null -ne $savedConfig.SkipPreflightCheck -and -not $BoundParams.Contains('SkipPreflight')) {
            $Script:SkipPreflight = [bool]$savedConfig.SkipPreflightCheck
        }

        Write-Log -Message "Loaded settings from $Script:ConfigPath" -Level INFO
    } catch {
        Write-Log -Message "Failed to load settings (using defaults): $($_.Exception.Message)" -Level WARN
    }
}

function Save-Config {
    [CmdletBinding()]
    param()

    try {
        $configDir = Split-Path $Script:ConfigPath -Parent
        if (-not (Test-Path -LiteralPath $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        }

        $persistLogPath = if ($Script:LogPathCustomized) { $Script:Config.LogFilePath } else { '' }
        $persistCache   = if ($Script:Config.EnableCache) { $Script:Config.CacheDir } else { 'none' }

        $configObj = [PSCustomObject]@{
            MaxRetries          = $Script:Config.MaxRetries
            RetryDelayMs        = $Script:Config.RetryDelayMs
            ProcessTimeoutMs    = $Script:Config.ProcessTimeoutMs
            BackupRetentionDays = $Script:Config.BackupRetention
            LogPath             = $persistLogPath
            CacheDir            = $persistCache
            KeepLogFile         = [bool]$Script:KeepLog
            SkipPreflightCheck  = [bool]$Script:SkipPreflight
        }

        $configObj | ConvertTo-Json -Depth 3 | Set-Content -Path $Script:ConfigPath -Encoding UTF8
        Write-Log -Message "Saved settings to $Script:ConfigPath" -Level INFO
    } catch {
        Write-Log -Message "Failed to save settings: $($_.Exception.Message)" -Level ERROR
    }
}

function Load-Stats {
    [CmdletBinding()]
    param()
    $Script:TotalRuns     = 0
    $Script:SuccessCount  = 0
    $Script:FailureCount  = 0
    if (-not (Test-Path -LiteralPath $Script:StatsPath)) { return }
    try {
        $s = Get-Content -Path $Script:StatsPath -Raw | ConvertFrom-Json
        if ($null -ne $s.TotalRuns)    { $Script:TotalRuns    = [int]$s.TotalRuns }
        if ($null -ne $s.SuccessCount) { $Script:SuccessCount = [int]$s.SuccessCount }
        if ($null -ne $s.FailureCount) { $Script:FailureCount = [int]$s.FailureCount }
    } catch {
        Write-Log -Message "Failed to load stats (resetting): $($_.Exception.Message)" -Level DEBUG
    }
}

function Save-Stats {
    [CmdletBinding()]
    param()
    try {
        $configDir = Split-Path $Script:StatsPath -Parent
        if (-not (Test-Path -LiteralPath $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        }
        [PSCustomObject]@{
            TotalRuns    = $Script:TotalRuns
            SuccessCount = $Script:SuccessCount
            FailureCount = $Script:FailureCount
        } | ConvertTo-Json | Set-Content -Path $Script:StatsPath -Encoding UTF8
    } catch {
        Write-Log -Message "Failed to save stats: $($_.Exception.Message)" -Level DEBUG
    }
}

$Script:lastWindowStateSave = [DateTime]::MinValue

function Save-WindowState {
    param([Parameter(Mandatory)]$Window)
    try {
        $now = [DateTime]::UtcNow
        if (($now - $Script:lastWindowStateSave).TotalMilliseconds -lt 1000) { return }
        $Script:lastWindowStateSave = $now
        $stateDir = Split-Path $Script:WindowStatePath -Parent
        if (-not (Test-Path -LiteralPath $stateDir)) {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        }

        # Use RestoreBounds when maximized so the "normal" size is preserved
        if ($Window.WindowState -eq [System.Windows.WindowState]::Maximized) {
            $saveWidth  = $Window.RestoreBounds.Width
            $saveHeight = $Window.RestoreBounds.Height
            $saveTop    = $Window.RestoreBounds.Top
            $saveLeft   = $Window.RestoreBounds.Left
        } else {
            $saveWidth  = $Window.ActualWidth
            $saveHeight = $Window.ActualHeight
            $saveTop    = $Window.Top
            $saveLeft   = $Window.Left
        }

        # Clamp onto visible desktop so a monitor change cannot strand the window
        if ([double]::IsNaN($saveLeft) -or [double]::IsNaN($saveTop)) { return }

        $stateObj = [PSCustomObject]@{
            Top    = $saveTop
            Left   = $saveLeft
            Width  = $saveWidth
            Height = $saveHeight
        }
        $stateObj | ConvertTo-Json | Set-Content -Path $Script:WindowStatePath -Encoding UTF8
    } catch {
        # Non-critical, fail silently
    }
}

function Restore-WindowState {
    param([Parameter(Mandatory)]$Window)
    if (-not (Test-Path -LiteralPath $Script:WindowStatePath)) { return }
    try {
        $json = Get-Content -Path $Script:WindowStatePath -Raw | ConvertFrom-Json
        # StrictMode-safe property presence checks (a truncated file must not throw)
        $props = $json.PSObject.Properties
        if ($props['Width'] -and $props['Height'] -and $props['Left'] -and $props['Top'] -and
            $null -ne $json.Left -and $null -ne $json.Top) {
            $Window.Left   = [double]$json.Left
            $Window.Top    = [double]$json.Top
            $Window.Width  = [double]$json.Width
            $Window.Height = [double]$json.Height
        }
    } catch {
        # Fail silently, use defaults
    }
}

function Show-Banner {
    Clear-Host
    $bar = ('=' * 60)
    Write-Host ''
    Write-Host $bar -ForegroundColor Cyan
    Write-Host '        Spicetify Lifecycle Manager v' -NoNewline -ForegroundColor Cyan
    Write-Host $Script:ScriptVersion -ForegroundColor White
    Write-Host '        Fully automatic - no input needed' -ForegroundColor DarkCyan
    Write-Host $bar -ForegroundColor Cyan
    Write-Host ''
}

function Show-ConsoleProgress {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$Percent
    )
    if ($Script:NoUI -or -not $Script:GUIActive) {
        Write-Progress -Activity $Activity -Status $Status -PercentComplete ([Math]::Min(100, [Math]::Max(0, $Percent)))
    }
}

function Close-Progress {
    Write-Progress -Activity 'Spicetify Manager' -Completed -ErrorAction SilentlyContinue
}

function Show-Summary {
    param(
        [string[]]$SuccessSteps = @(),
        [string[]]$WarningSteps = @(),
        [string]$ErrorStep
    )

    Close-Progress
    $bar = ('=' * 60)
    Write-Host ''
    Write-Host $bar -ForegroundColor Cyan
    Write-Host ' Summary' -ForegroundColor Cyan
    Write-Host $bar -ForegroundColor Cyan

    foreach ($step in $SuccessSteps) {
        Write-Host '  [OK]    ' -NoNewline -ForegroundColor Green
        Write-Host $step
    }
    foreach ($step in $WarningSteps) {
        Write-Host '  [!]     ' -NoNewline -ForegroundColor Yellow
        Write-Host $step
    }
    if ($ErrorStep) {
        Write-Host '  [X]     ' -NoNewline -ForegroundColor Red
        Write-Host $ErrorStep
        Write-Host $bar -ForegroundColor Red
        Write-Host ' Failed.' -ForegroundColor Red
    } else {
        Write-Host $bar -ForegroundColor Cyan
        Write-Host ' All steps completed successfully.' -ForegroundColor Green
    }
    Write-Host $bar -ForegroundColor Cyan

    if ($Script:PhaseTimings.Count -gt 0) {
        Write-Host ''
        Write-Host ' Phase timings:' -ForegroundColor DarkCyan
        foreach ($kv in $Script:PhaseTimings) {
            Write-Host ('  {0,-20} {1:N1}s' -f $kv.Key, $kv.Value.TotalSeconds) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
}

$Script:MainWindowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Spicetify Manager"
        Height="720" Width="980"
        MinHeight="600" MinWidth="820"
        WindowStartupLocation="CenterScreen"
        Background="#FF121212"
        WindowStyle="None"
        ResizeMode="CanResize"
        FontFamily="Segoe UI"
        Foreground="#FFFFFFFF"
        TextOptions.TextFormattingMode="Display"
        UseLayoutRounding="True">
    <Window.Resources>
        <Style x:Key="BtnPrimary" TargetType="Button">
            <Setter Property="Background" Value="#FF1DB954"/>
            <Setter Property="Foreground" Value="#FF000000"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="20,8"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="4">
                            <ContentPresenter RecognizesAccessKey="True" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF1ED760"/>
                            </Trigger>
                            <Trigger Property="IsFocused" Value="True">
                                <Setter TargetName="border" Property="Opacity" Value="0.9"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF179640"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#FF535353"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <!-- Disabled text graying lives at STYLE level: Foreground is a
                 Button property (Border has none). ContentPresenter inherits
                 it from the templated parent. -->
            <Style.Triggers>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Foreground" Value="#FFA0A0A0"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="BtnSecondary" TargetType="Button">
            <Setter Property="Background" Value="#FF282828"/>
            <Setter Property="Foreground" Value="#FFFFFFFF"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="#FF404040"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="4">
                            <ContentPresenter RecognizesAccessKey="True" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF3E3E3E"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#FF555555"/>
                            </Trigger>
                            <Trigger Property="IsFocused" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="#FF666666"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF2A2A2A"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#FF1A1A1A"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#FF333333"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Foreground" Value="#FF535353"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource BtnSecondary}">
            <Setter Property="Foreground" Value="#FFE22134"/>
            <Setter Property="BorderBrush" Value="#FF504040"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#FF3D1518"/>
                    <Setter Property="BorderBrush" Value="#FFE22134"/>
                </Trigger>
                <Trigger Property="IsFocused" Value="True">
                    <Setter Property="BorderBrush" Value="#FF664444"/>
                </Trigger>
                <Trigger Property="IsPressed" Value="True">
                    <Setter Property="Background" Value="#FFC01D28"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <!-- Default ProgressBar template retained: it scales the indicator
             proportionally AND supports IsIndeterminate (the custom template
             did neither). Colors are driven by the setters below. -->
        <Style TargetType="ProgressBar">
            <Setter Property="Height" Value="8"/>
            <Setter Property="Background" Value="#FF282828"/>
            <Setter Property="Foreground" Value="#FF1DB954"/>
            <Setter Property="BorderThickness" Value="0"/>
        </Style>
    </Window.Resources>

    <!-- Root Container -->
    <Grid>
        <!-- Custom Title Bar -->
        <Grid x:Name="TitleBar" Height="32" Background="#FF121212"
              VerticalAlignment="Top" Panel.ZIndex="100"
              Margin="0,0,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <!-- Icon + Title -->
            <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="8,0,0,0">
                <TextBlock Text="&#127925;" FontSize="13" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <TextBlock Text="Spicetify Manager" FontSize="12" FontWeight="SemiBold"
                           Foreground="#FFFFFFFF" VerticalAlignment="Center"/>
            </StackPanel>

            <!-- Window Controls -->
            <StackPanel Grid.Column="2" Orientation="Horizontal" HorizontalAlignment="Right">
                <Button x:Name="BtnMinimize" Width="46" Height="32"
                        Background="Transparent" BorderThickness="0"
                        Cursor="Hand" ToolTip="Minimize">
                    <Line X1="0" Y1="8" X2="12" Y2="8" Stroke="#FFFFFFFF" StrokeThickness="2"
                          HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <Button.Style>
                        <Style TargetType="Button">
                            <Setter Property="Template">
                                <Setter.Value>
                                    <ControlTemplate TargetType="Button">
                                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                                BorderThickness="0" Padding="0">
                                            <ContentPresenter RecognizesAccessKey="True" HorizontalAlignment="Center"
                                                              VerticalAlignment="Center"/>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter TargetName="border" Property="Background" Value="#FF2D2D2D"/>
                                            </Trigger>
                                            <Trigger Property="IsPressed" Value="True">
                                                <Setter TargetName="border" Property="Background" Value="#FF404040"/>
                                            </Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </Setter.Value>
                            </Setter>
                        </Style>
                    </Button.Style>
                </Button>

                <Button x:Name="BtnMaximize" Width="46" Height="32"
                        Background="Transparent" BorderThickness="0"
                        Cursor="Hand" ToolTip="Maximize">
                    <Rectangle Stroke="#FFFFFFFF" StrokeThickness="1.5"
                               Width="10" Height="10" Fill="Transparent"
                               HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <Button.Style>
                        <Style TargetType="Button">
                            <Setter Property="Template">
                                <Setter.Value>
                                    <ControlTemplate TargetType="Button">
                                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                                BorderThickness="0" Padding="0">
                                            <ContentPresenter RecognizesAccessKey="True" HorizontalAlignment="Center"
                                                              VerticalAlignment="Center"/>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter TargetName="border" Property="Background" Value="#FF2D2D2D"/>
                                            </Trigger>
                                            <Trigger Property="IsPressed" Value="True">
                                                <Setter TargetName="border" Property="Background" Value="#FF404040"/>
                                            </Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </Setter.Value>
                            </Setter>
                        </Style>
                    </Button.Style>
                </Button>

                <Button x:Name="BtnClose" Width="46" Height="32"
                        Background="Transparent" BorderThickness="0"
                        Cursor="Hand" ToolTip="Close">
                    <Grid Width="10" Height="10"
                          HorizontalAlignment="Center" VerticalAlignment="Center">
                        <Line X1="0" Y1="0" X2="10" Y2="10" Stroke="#FFFFFFFF" StrokeThickness="1"/>
                        <Line X1="10" Y1="0" X2="0" Y2="10" Stroke="#FFFFFFFF" StrokeThickness="1"/>
                    </Grid>
                    <Button.Style>
                        <Style TargetType="Button">
                            <Setter Property="Template">
                                <Setter.Value>
                                    <ControlTemplate TargetType="Button">
                                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                                BorderThickness="0" Padding="0">
                                            <ContentPresenter RecognizesAccessKey="True" HorizontalAlignment="Center"
                                                              VerticalAlignment="Center"/>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter TargetName="border" Property="Background" Value="#FFE81123"/>
                                            </Trigger>
                                            <Trigger Property="IsPressed" Value="True">
                                                <Setter TargetName="border" Property="Background" Value="#FFC50F0F"/>
                                            </Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </Setter.Value>
                            </Setter>
                        </Style>
                    </Button.Style>
                </Button>
            </StackPanel>
        </Grid>

        <!-- Main Content -->
        <Grid Margin="0,32,0,0">
            <Grid.RowDefinitions>
                <RowDefinition Height="64"/>     <!-- Header -->
                <RowDefinition Height="Auto"/>   <!-- Status bar -->
                <RowDefinition Height="*"/>      <!-- Main content -->
                <RowDefinition Height="Auto"/>   <!-- Progress bar -->
                <RowDefinition Height="56"/>     <!-- Footer buttons -->
            </Grid.RowDefinitions>

            <!-- Header -->
            <Border Grid.Row="0" Background="#FF000000" SnapsToDevicePixels="True">
                <Grid Margin="20,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="Spicetify Manager" FontSize="20" FontWeight="Bold"
                                   Foreground="#FF1DB954" VerticalAlignment="Center"/>
                        <TextBlock x:Name="TxtVersion" Text="v1.0.0" FontSize="11" Foreground="#FFB3B3B3"
                                   VerticalAlignment="Bottom" Margin="8,0,0,4"
                                   Cursor="Hand"
                                   ToolTip="Click for About dialog">
                            <TextBlock.Style>
                                <Style TargetType="TextBlock">
                                    <Style.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter Property="Foreground" Value="#FF1DB954"/>
                                            <Setter Property="TextDecorations" Value="Underline"/>
                                        </Trigger>
                                    </Style.Triggers>
                                </Style>
                            </TextBlock.Style>
                        </TextBlock>
                    </StackPanel>
                    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                        <Border Background="#FF1E1E1E" CornerRadius="4" Padding="10,5" Margin="0,0,10,0">
                            <TextBlock x:Name="TxtEnvInfo" FontSize="11" Foreground="#FF888888"
                                       VerticalAlignment="Center"/>
                        </Border>

                        <Border Background="#FF1E1E1E" CornerRadius="4" Padding="10,5" Margin="0,0,14,0">
                            <TextBlock x:Name="TxtInstalledState" FontSize="11" Foreground="#FF888888"
                                       VerticalAlignment="Center"/>
                        </Border>

                        <Button x:Name="BtnSettings" Content="Settings"
                                Background="#FF282828" Foreground="#FFFFFFFF"
                                BorderThickness="1" BorderBrush="#FF404040"
                                Padding="12,5" FontSize="11" FontWeight="SemiBold"
                                Cursor="Hand" ToolTip="Open configuration settings"
                                TabIndex="20"
                                AutomationProperties.Name="Settings Button">
                            <Button.Style>
                                <Style TargetType="Button">
                                    <Setter Property="Template">
                                        <Setter.Value>
                                            <ControlTemplate TargetType="Button">
                                                <Border x:Name="border" Background="{TemplateBinding Background}"
                                                        BorderBrush="{TemplateBinding BorderBrush}"
                                                        BorderThickness="{TemplateBinding BorderThickness}"
                                                        CornerRadius="4" Padding="{TemplateBinding Padding}">
                                                    <ContentPresenter RecognizesAccessKey="True" HorizontalAlignment="Center"
                                                                      VerticalAlignment="Center"/>
                                                </Border>
                                                <ControlTemplate.Triggers>
                                                    <Trigger Property="IsMouseOver" Value="True">
                                                        <Setter TargetName="border" Property="Background" Value="#FF3D3D3D"/>
                                                        <Setter TargetName="border" Property="BorderBrush" Value="#FF555555"/>
                                                    </Trigger>
                                                    <Trigger Property="IsPressed" Value="True">
                                                        <Setter TargetName="border" Property="Background" Value="#FF454545"/>
                                                    </Trigger>
                                                    <Trigger Property="IsEnabled" Value="False">
                                                        <Setter TargetName="border" Property="Background" Value="#FF1A1A1A"/>
                                                        <Setter TargetName="border" Property="BorderBrush" Value="#FF333333"/>
                                                    </Trigger>
                                                </ControlTemplate.Triggers>
                                            </ControlTemplate>
                                        </Setter.Value>
                                    </Setter>
                                    <Style.Triggers>
                                        <Trigger Property="IsEnabled" Value="False">
                                            <Setter Property="Foreground" Value="#FF535353"/>
                                        </Trigger>
                                    </Style.Triggers>
                                </Style>
                            </Button.Style>
                        </Button>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- Status bar -->
            <Border Grid.Row="1" Background="#FF181818" Padding="20,8" SnapsToDevicePixels="True">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock x:Name="TxtPhase" Text="Idle" FontSize="13" FontWeight="SemiBold"
                                   Foreground="#FFFFFFFF" VerticalAlignment="Center"
                                   ToolTip="Current operation phase"/>
                        <TextBlock x:Name="TxtDetail" Text="" FontSize="12" Foreground="#FFB3B3B3"
                                   Margin="16,0,0,0" VerticalAlignment="Center"
                                   ToolTip="Detailed status message"/>
                    </StackPanel>
                    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="Elapsed:" FontSize="11" Foreground="#FF7F7F7F"
                                   VerticalAlignment="Center" Margin="0,0,6,0"/>
                        <TextBlock x:Name="TxtElapsed" Text="00:00" FontSize="12"
                                   Foreground="#FFFFFFFF" VerticalAlignment="Center"
                                   FontFamily="Consolas" ToolTip="Time elapsed since operation started"/>
                        <TextBlock Text="ETA:" FontSize="11" Foreground="#FF7F7F7F"
                                   VerticalAlignment="Center" Margin="16,0,6,0"/>
                        <TextBlock x:Name="TxtEta" Text="--:--" FontSize="12"
                                   Foreground="#FFFFFFFF" VerticalAlignment="Center"
                                   FontFamily="Consolas" ToolTip="Estimated time remaining"/>
                    </StackPanel>
                    <TextBlock x:Name="TxtLastRunStatus" Grid.Column="2" FontSize="10" Foreground="#FF888888"
                               VerticalAlignment="Center" HorizontalAlignment="Right"
                               Margin="20,0,0,0" Text="Ready"
                               ToolTip="Result of last operation"/>
                </Grid>
            </Border>

            <!-- Main content: step list + log -->
            <Grid Grid.Row="2" Margin="20,12,20,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="240" MinWidth="180" MaxWidth="320"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <!-- Step list -->
                <Border Grid.Column="0" Background="#FF181818" CornerRadius="4" Padding="12" SnapsToDevicePixels="True">
                    <DockPanel>
                        <TextBlock Text="Workflow" FontSize="12" FontWeight="SemiBold"
                                   Foreground="#FFB3B3B3" Margin="0,0,0,8"
                                   DockPanel.Dock="Top"/>
                        <ScrollViewer VerticalScrollBarVisibility="Auto"
                                      HorizontalScrollBarVisibility="Disabled"
                                      CanContentScroll="False">
                            <ItemsControl x:Name="StepList">
                                <ItemsControl.ItemTemplate>
                                    <DataTemplate>
                                        <StackPanel Orientation="Horizontal" Margin="0,6" ToolTip="{Binding Tooltip}">
                                            <TextBlock Text="{Binding Icon}" FontSize="14"
                                                       Margin="0,0,10,0"
                                                       VerticalAlignment="Center" FontFamily="Segoe UI"
                                                       RenderTransformOrigin="0.5,0.5">
                                                <TextBlock.RenderTransform>
                                                    <ScaleTransform ScaleX="1" ScaleY="1"/>
                                                </TextBlock.RenderTransform>
                                                <TextBlock.Style>
                                                    <Style TargetType="TextBlock">
                                                        <Setter Property="Foreground" Value="{Binding IconColor}"/>
                                                        <Style.Triggers>
                                                            <!-- Active: pulsing opacity + scale = clear "this is happening now" -->
                                                            <DataTrigger Binding="{Binding State}" Value="Active">
                                                                <DataTrigger.EnterActions>
                                                                    <BeginStoryboard Name="ActivePulse">
                                                                        <Storyboard>
                                                                            <DoubleAnimation Storyboard.TargetProperty="Opacity"
                                                                                             From="1.0" To="0.30"
                                                                                             Duration="0:0:0.7"
                                                                                             AutoReverse="True"
                                                                                             RepeatBehavior="Forever"/>
                                                                            <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                                                             From="1.0" To="1.25"
                                                                                             Duration="0:0:0.7"
                                                                                             AutoReverse="True"
                                                                                             RepeatBehavior="Forever"/>
                                                                            <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                                                             From="1.0" To="1.25"
                                                                                             Duration="0:0:0.7"
                                                                                             AutoReverse="True"
                                                                                             RepeatBehavior="Forever"/>
                                                                        </Storyboard>
                                                                    </BeginStoryboard>
                                                                </DataTrigger.EnterActions>
                                                                <DataTrigger.ExitActions>
                                                                    <RemoveStoryboard BeginStoryboardName="ActivePulse"/>
                                                                </DataTrigger.ExitActions>
                                                            </DataTrigger>
                                                            <!-- Done: one-shot pop so the checkmark lands with a beat -->
                                                            <DataTrigger Binding="{Binding State}" Value="Done">
                                                                <DataTrigger.EnterActions>
                                                                    <BeginStoryboard>
                                                                        <Storyboard>
                                                                            <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                                                             From="0.4" To="1.0"
                                                                                             Duration="0:0:0.25"/>
                                                                            <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                                                             From="0.4" To="1.0"
                                                                                             Duration="0:0:0.25"/>
                                                                        </Storyboard>
                                                                    </BeginStoryboard>
                                                                </DataTrigger.EnterActions>
                                                            </DataTrigger>
                                                            <!-- Fail: one-shot shake -->
                                                            <DataTrigger Binding="{Binding State}" Value="Fail">
                                                                <DataTrigger.EnterActions>
                                                                    <BeginStoryboard>
                                                                        <Storyboard>
                                                                            <DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)">
                                                                                <LinearDoubleKeyFrame KeyTime="0:0:0.0" Value="1.0"/>
                                                                                <LinearDoubleKeyFrame KeyTime="0:0:0.08" Value="1.4"/>
                                                                                <LinearDoubleKeyFrame KeyTime="0:0:0.16" Value="1.0"/>
                                                                            </DoubleAnimationUsingKeyFrames>
                                                                        </Storyboard>
                                                                    </BeginStoryboard>
                                                                </DataTrigger.EnterActions>
                                                            </DataTrigger>
                                                        </Style.Triggers>
                                                    </Style>
                                                </TextBlock.Style>
                                            </TextBlock>
                                            <TextBlock Text="{Binding Name}" FontSize="12"
                                                       Foreground="{Binding TextColor}"
                                                       VerticalAlignment="Center"
                                                       TextWrapping="Wrap"
                                                       MaxWidth="260"/>
                                        </StackPanel>
                                    </DataTemplate>
                                </ItemsControl.ItemTemplate>
                            </ItemsControl>
                        </ScrollViewer>
                    </DockPanel>
                </Border>

                <!-- Log viewer -->
                <Border Grid.Column="1" Background="#FF0A0A0A" CornerRadius="4" Margin="12,0,0,0" SnapsToDevicePixels="True">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <Border Grid.Row="0" Background="#FF181818" Padding="12,6" CornerRadius="4,4,0,0" SnapsToDevicePixels="True">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Text="Live Log" FontSize="12" FontWeight="SemiBold"
                                           Foreground="#FFB3B3B3" VerticalAlignment="Center"/>
                                <StackPanel Grid.Column="1" Orientation="Horizontal">
                                    <TextBox x:Name="TxtLogSearch" Width="150" Height="24" Margin="0,0,8,0"
                                             FontSize="11" VerticalAlignment="Center"
                                             ToolTip="Search log entries"/>
                                    <ComboBox x:Name="CmbLogLevelFilter" Width="120" Height="24" Margin="0,0,8,0"
                                              FontSize="11" VerticalAlignment="Center" SelectedIndex="0"
                                              ToolTip="Filter logs by severity level">
                                        <ComboBoxItem Content="All Levels" Tag=""/>
                                        <ComboBoxItem Content="Errors Only" Tag="ERROR"/>
                                        <ComboBoxItem Content="Warnings+" Tag="WARN"/>
                                        <ComboBoxItem Content="Info+" Tag="INFO"/>
                                    </ComboBox>
                                    <CheckBox x:Name="ChkAutoscroll" Content="Autoscroll" IsChecked="True"
                                              Foreground="#FFB3B3B3" FontSize="11" VerticalAlignment="Center"
                                              ToolTip="Automatically scroll to newest log entries"
                                              TabIndex="90"
                                              AutomationProperties.Name="Autoscroll Log Checkbox"/>
                                    <Button x:Name="BtnCopyLog" Content="C_opy" Style="{StaticResource BtnSecondary}"
                                            Padding="8,2" FontSize="10" Margin="8,0,0,0"
                                            ToolTip="Copy log contents to clipboard"
                                            TabIndex="100"
                                            AutomationProperties.Name="Copy Log Button"/>
                                    <Button x:Name="BtnOpenLog" Content="_Open File" Style="{StaticResource BtnSecondary}"
                                            Padding="8,2" FontSize="10" Margin="4,0,0,0"
                                            ToolTip="Open log file in text editor"
                                            TabIndex="110"
                                            AutomationProperties.Name="Open Log File Button"/>
                                    <Button x:Name="BtnExportLog" Content="_Export" Style="{StaticResource BtnSecondary}"
                                            Padding="8,4" FontSize="11" Margin="4,0,0,0"
                                            ToolTip="Export filtered logs to file (Alt+E)"
                                            TabIndex="120"
                                            AutomationProperties.Name="Export Log Button"/>
                                </StackPanel>
                            </Grid>
                        </Border>
                        <Grid Grid.Row="1">
                            <ListBox x:Name="LogList" Background="Transparent" BorderThickness="0"
                                     ScrollViewer.HorizontalScrollBarVisibility="Auto"
                                     ScrollViewer.VerticalScrollBarVisibility="Auto"
                                     FontFamily="Cascadia Mono, Consolas, monospace" FontSize="11"
                                     VirtualizingPanel.IsVirtualizing="False">
                                <ListBox.ItemTemplate>
                                    <DataTemplate>
                                        <TextBlock Text="{Binding Line}" Foreground="{Binding Color}"
                                                   TextWrapping="NoWrap"/>
                                    </DataTemplate>
                                </ListBox.ItemTemplate>
                                <ListBox.ItemContainerStyle>
                                    <Style TargetType="ListBoxItem">
                                        <Setter Property="Padding" Value="8,1"/>
                                        <Setter Property="Margin" Value="0"/>
                                        <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                                        <Setter Property="Template">
                                            <Setter.Value>
                                                <ControlTemplate TargetType="ListBoxItem">
                                                    <Border Background="Transparent" Padding="{TemplateBinding Padding}">
                                                        <ContentPresenter/>
                                                    </Border>
                                                </ControlTemplate>
                                            </Setter.Value>
                                        </Setter>
                                    </Style>
                                </ListBox.ItemContainerStyle>
                            </ListBox>
                            <TextBlock x:Name="TxtLogEmptyState" Text="No log entries yet. Click Start to begin."
                                       HorizontalAlignment="Center" VerticalAlignment="Center"
                                       Foreground="#FF555555" FontSize="12" FontStyle="Italic"
                                       IsHitTestVisible="False"/>
                        </Grid>
                    </Grid>
                </Border>
            </Grid>

            <!-- Progress bar -->
            <Grid Grid.Row="3" Margin="20,12,20,8">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <Grid Grid.Row="0" Margin="0,0,0,4">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock x:Name="TxtProgressLabel" Text="Ready" FontSize="11" Foreground="#FFB3B3B3"/>
                    <TextBlock x:Name="TxtProgressPercent" Text="0%" FontSize="11" Foreground="#FFB3B3B3"
                               Grid.Column="1" FontFamily="Consolas"
                               ToolTip="Completion percentage"/>
                </Grid>
                <ProgressBar Grid.Row="1" x:Name="MainProgress" Height="8" Minimum="0" Maximum="100"
                             Value="0" Background="#FF282828" Foreground="#FF1DB954"
                             BorderThickness="0"/>
            </Grid>

            <!-- Footer buttons -->
            <Border Grid.Row="4" Background="#FF000000" Padding="20,0" SnapsToDevicePixels="True">
                <Grid VerticalAlignment="Center">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Button Grid.Column="0" x:Name="BtnStart" Content="_Start"
                            Style="{StaticResource BtnPrimary}" FontSize="13" Margin="0,0,8,0"
                            ToolTip="Begin full Spicetify installation (Alt+S)"
                            TabIndex="30" IsDefault="True"
                            AutomationProperties.Name="Start Installation Button"/>
                    <Button Grid.Column="1" x:Name="BtnRepair" Content="_Repair Only"
                            Style="{StaticResource BtnSecondary}" FontSize="13" Margin="0,0,8,0"
                            ToolTip="Repair broken installation (Alt+R)"
                            TabIndex="40"
                            AutomationProperties.Name="Repair Installation Button"/>
                    <Button Grid.Column="2" x:Name="BtnUninstall" Content="_Uninstall"
                            Style="{StaticResource BtnDanger}" FontSize="13" Margin="0,0,8,0"
                            ToolTip="Remove Spicetify and restore Spotify (Alt+U)"
                            TabIndex="50"
                            AutomationProperties.Name="Uninstall Button"/>
                    <Button Grid.Column="4" x:Name="BtnOpenSpicetify" Content="Open Spicetify Folder"
                            Style="{StaticResource BtnSecondary}" FontSize="11" Margin="0,0,4,0"
                            ToolTip="Open Spicetify configuration folder"
                            TabIndex="60"
                            AutomationProperties.Name="Open Spicetify Folder Button"/>
                    <Button Grid.Column="5" x:Name="BtnRestartSpotify" Content="Restart Spotify"
                            Style="{StaticResource BtnSecondary}" FontSize="11" Margin="0,0,4,0"
                            ToolTip="Restart Spotify to apply changes"
                            TabIndex="70"
                            AutomationProperties.Name="Restart Spotify Button"/>
                    <Button Grid.Column="6" x:Name="BtnCancel" Content="_Cancel"
                            Style="{StaticResource BtnSecondary}" FontSize="13" IsEnabled="False"
                            ToolTip="Cancel current operation (Alt+C)"
                            TabIndex="80" IsCancel="True"
                            AutomationProperties.Name="Cancel Operation Button"/>
                </Grid>
            </Border>
        </Grid>
    </Grid>
</Window>
'@

$Script:SettingsWindowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Settings" Height="552" Width="540"
        WindowStartupLocation="CenterOwner"
        Background="#FF121212" Foreground="#FFFFFFFF"
        FontFamily="Segoe UI" ResizeMode="NoResize"
        WindowStyle="None">
    <Window.Resources>
        <!-- Styles are duplicated here because the Settings window is loaded
             through a separate XAML reader (no shared resource dictionary). -->
        <Style x:Key="BtnSecondary" TargetType="Button">
            <Setter Property="Background" Value="#FF282828"/>
            <Setter Property="Foreground" Value="#FFFFFFFF"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="#FF404040"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter RecognizesAccessKey="True" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF3E3E3E"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#FF555555"/>
                            </Trigger>
                            <Trigger Property="IsFocused" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="#FF666666"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF2A2A2A"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#FF1A1A1A"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#FF333333"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Foreground" Value="#FF535353"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="BtnPrimary" TargetType="Button">
            <Setter Property="Background" Value="#FF1DB954"/>
            <Setter Property="Foreground" Value="#FF000000"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="4">
                            <ContentPresenter RecognizesAccessKey="True" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF1ED760"/>
                            </Trigger>
                            <Trigger Property="IsFocused" Value="True">
                                <Setter TargetName="border" Property="Opacity" Value="0.9"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF179640"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#FF535353"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Foreground" Value="#FFA0A0A0"/>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>

    <!-- Root Container -->
    <Grid>
        <!-- Custom Title Bar for Settings Window -->
        <Grid x:Name="SettingsTitleBar" Height="32" Background="#FF121212"
              VerticalAlignment="Top" Panel.ZIndex="100">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <TextBlock Grid.Column="0" Text="Settings" FontSize="12" FontWeight="SemiBold"
                       Foreground="#FFFFFFFF" VerticalAlignment="Center" Margin="12,0,0,0"/>

            <Button x:Name="BtnSettingsClose" Grid.Column="1" Width="46" Height="32"
                    Background="Transparent" BorderThickness="0"
                    Cursor="Hand" ToolTip="Close">
                <TextBlock Text="x" FontSize="11" Foreground="#FFFFFFFF"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
                <Button.Style>
                    <Style TargetType="Button">
                        <Setter Property="Template">
                            <Setter.Value>
                                <ControlTemplate TargetType="Button">
                                    <Border x:Name="border" Background="{TemplateBinding Background}"
                                            BorderThickness="0" Padding="0">
                                        <ContentPresenter RecognizesAccessKey="True" HorizontalAlignment="Center"
                                                          VerticalAlignment="Center"/>
                                    </Border>
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="border" Property="Background" Value="#FFE81123"/>
                                        </Trigger>
                                        <Trigger Property="IsPressed" Value="True">
                                            <Setter TargetName="border" Property="Background" Value="#FFC50F0F"/>
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </Setter.Value>
                        </Setter>
                    </Style>
                </Button.Style>
            </Button>
        </Grid>

        <!-- Main Content -->
        <Grid Margin="20,32,20,20">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <TextBlock Grid.Row="0" Text="Settings" FontSize="18" FontWeight="Bold"
                       Foreground="#FF1DB954" Margin="0,0,0,16"/>

            <StackPanel Grid.Row="1" Margin="0,0,0,12">
                <TextBlock Text="Max retries for network operations (0 = no retry)" FontSize="11" Foreground="#FFB3B3B3"/>
                <TextBox x:Name="TxtMaxRetries" Background="#FF282828" Foreground="#FFFFFFFF"
                         BorderBrush="#FF535353" Padding="6,4" Margin="0,4,0,0"
                         ToolTip="Maximum number of retry attempts for network operations (0-10)"
                         TabIndex="10"/>
            </StackPanel>

            <StackPanel Grid.Row="2" Margin="0,0,0,12">
                <TextBlock Text="Initial retry delay (ms)" FontSize="11" Foreground="#FFB3B3B3"/>
                <TextBox x:Name="TxtRetryDelayMs" Background="#FF282828" Foreground="#FFFFFFFF"
                         BorderBrush="#FF535353" Padding="6,4" Margin="0,4,0,0"
                         ToolTip="Initial delay in milliseconds between retry attempts (100-30000)"
                         TabIndex="20"/>
            </StackPanel>

            <StackPanel Grid.Row="3" Margin="0,0,0,12">
                <TextBlock Text="Process timeout (ms, min 5000)" FontSize="11" Foreground="#FFB3B3B3"/>
                <TextBox x:Name="TxtProcessTimeoutMs" Background="#FF282828" Foreground="#FFFFFFFF"
                         BorderBrush="#FF535353" Padding="6,4" Margin="0,4,0,0"
                         ToolTip="Timeout in milliseconds for external processes (5000-600000)"
                         TabIndex="30"/>
            </StackPanel>

            <StackPanel Grid.Row="4" Margin="0,0,0,12">
                <TextBlock Text="Backup snapshot retention count" FontSize="11" Foreground="#FFB3B3B3"/>
                <TextBox x:Name="TxtBackupRetention" Background="#FF282828" Foreground="#FFFFFFFF"
                         BorderBrush="#FF535353" Padding="6,4" Margin="0,4,0,0"
                         ToolTip="Number of historical backup snapshots to keep (1-50)"
                         TabIndex="40"/>
            </StackPanel>

            <StackPanel Grid.Row="5" Margin="0,0,0,12">
                <TextBlock Text="Log file path (leave empty for default)" FontSize="11" Foreground="#FFB3B3B3"/>
                <TextBox x:Name="TxtLogPath" Background="#FF282828" Foreground="#FFFFFFFF"
                         BorderBrush="#FF535353" Padding="6,4" Margin="0,4,0,0"
                         ToolTip="Custom path for log file (empty uses default location)"
                         TabIndex="50"/>
            </StackPanel>

            <StackPanel Grid.Row="6" Margin="0,0,0,12">
                <TextBlock Text="Cache directory (empty = default, 'none' = disable)" FontSize="11" Foreground="#FFB3B3B3"/>
                <TextBox x:Name="TxtCacheDir" Background="#FF282828" Foreground="#FFFFFFFF"
                         BorderBrush="#FF535353" Padding="6,4" Margin="0,4,0,0"
                         ToolTip="Directory for cached downloads (empty=default, none=disable)"
                         TabIndex="60"/>
            </StackPanel>

            <StackPanel Grid.Row="7">
                <CheckBox x:Name="ChkKeepLog" Content="Preserve log file after exit"
                          Foreground="#FFB3B3B3" FontSize="12" Margin="0,8,0,0"
                          ToolTip="Keep log file on disk after application closes"
                          TabIndex="70"/>
                <CheckBox x:Name="ChkSkipPreflight" Content="Skip pre-flight environment checks (not recommended)"
                          Foreground="#FFB3B3B3" FontSize="12" Margin="0,8,0,0"
                          ToolTip="Skip network, disk space, and architecture checks"
                          TabIndex="80"/>
            </StackPanel>

            <StackPanel Grid.Row="8" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
                <Button x:Name="BtnResetDefaults" Content="_Defaults" Style="{StaticResource BtnSecondary}"
                        Padding="12,4" FontSize="11" Margin="0,0,8,0"
                        ToolTip="Reset fields to default values"
                        TabIndex="85"
                        AutomationProperties.Name="Reset Defaults Button"/>
                <Button x:Name="BtnCancelSettings" Content="_Cancel" Style="{StaticResource BtnSecondary}"
                        Width="80" Margin="0,0,8,0" Padding="0,6"
                        ToolTip="Discard changes and close"
                        TabIndex="90"
                        AutomationProperties.Name="Cancel Settings Button"/>
                <Button x:Name="BtnSaveSettings" Content="_Save" Style="{StaticResource BtnPrimary}"
                        Width="80" Padding="0,6"
                        ToolTip="Save settings and close"
                        TabIndex="95"
                        AutomationProperties.Name="Save Settings Button"/>
            </StackPanel>
        </Grid>
    </Grid>
</Window>
'@

$Script:LogStream      = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()  # log entries
$Script:StepStream     = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()  # step state changes
$Script:ProgressStream = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()  # progress updates

$Script:CancellationToken      = [System.Threading.CancellationTokenSource]::new()
$Script:GUIActive              = $false   # true once the main window is displayed
$Script:OperationRunning       = $false   # true while the worker runspace is executing
$Script:CurrentPhasePercent    = 0        # GLOBAL progress percent (drives ETA)
$Script:OperationStartTime     = $null
$Script:OperationUtcStart      = $null   # UTC anchor for the UI timer's elapsed/ETA
$Script:MainWindow             = $null
$Script:LogView                = $null    # ICollectionView over $Script:LogEntries
$Script:LogLevelFilter         = ''       # '', 'ERROR', 'WARN', 'INFO'
$Script:LogSearchTerm          = ''
$Script:TotalRuns              = 0
$Script:SuccessCount           = 0
$Script:FailureCount           = 0
$Script:DefaultConfigSnapshot  = $null    # captured when Settings opens (Defaults button)

$Script:UI_TIMER_INTERVAL_MS        = 100
$Script:COMPLETION_POLL_INTERVAL_MS = 200

$Script:LogFilterSets = @{
    ''     = @('ERROR', 'WARN', 'SUCCESS', 'INFO', 'DEBUG')
    'ERROR'= @('ERROR')
    'WARN' = @('ERROR', 'WARN')
    'INFO' = @('ERROR', 'WARN', 'SUCCESS', 'INFO')
}

function Test-LogEntryVisible {
    param($Entry)
    $allowed = $Script:LogFilterSets[$Script:LogLevelFilter]
    if ($null -eq $allowed) { $allowed = $Script:LogFilterSets[''] }
    if ($allowed -notcontains $Entry.Level) { return $false }
    if ($Script:LogSearchTerm -ne '' -and $Entry.Line -notmatch [regex]::Escape($Script:LogSearchTerm)) {
        return $false
    }
    return $true
}

function Get-LogLevelColor {
    param([string]$Level)
    switch ($Level) {
        'ERROR'   { '#FFE22134' }
        'WARN'    { '#FFFFD700' }
        'SUCCESS' { '#FF1DB954' }
        'DEBUG'   { '#FF7F7F7F' }
        default   { '#FFE0E0E0' }
    }
}

function Format-LogEntry {
    param(
        [string]$Time,
        [string]$Level,
        [string]$Msg
    )
    $lvlPadded = $Level.PadRight(7)
    $prefix = switch ($Level) {
        'ERROR'   { '[FAIL] ' }
        'WARN'    { '[WARN] ' }
        'SUCCESS' { '[ OK ] ' }
        'DEBUG'   { '[DBG ] ' }
        default   { '--    ' }
    }
    return [PSCustomObject]@{
        Time  = $Time
        Level = $Level
        Line  = "[$Time] $lvlPadded ${prefix}$Msg"
        Color = Get-LogLevelColor -Level $Level
    }
}

function Get-FriendlyErrorMessage {
    param([string]$RawError)

    if (-not $RawError) { return 'Unknown error.' }
    $errorLower = $RawError.ToLower()

    if ($errorLower -match 'remote name could not be resolved|network|dns|connect|unreachable') {
        return "Cannot connect to GitHub.`nPlease check your internet connection and try again."
    }
    if ($errorLower -match 'access.*denied|permission|unauthorized|admin') {
        return "Access denied.`nPlease check file permissions (running as Administrator is usually NOT required)."
    }
    if ($errorLower -match 'file.*not found|cannot find path|does not exist') {
        return "Required file not found.`nThe installation may be incomplete. Try running Repair."
    }
    if ($errorLower -match 'cannot convert|invalid.*type|parse') {
        return "Invalid input format.`nPlease check your settings values."
    }
    if ($errorLower -match 'timeout|timed out|elapsed') {
        return "Operation timed out.`nThe server may be busy. Please try again."
    }
    if ($errorLower -match 'rate limit') {
        return "GitHub API rate limit reached.`nWait a while and run again."
    }
    if ($errorLower -match 'microsoft store') {
        return "Microsoft Store Spotify detected.`nSpicetify cannot modify it. Uninstall the Store version first."
    }
    if ($errorLower -match 'spicetify|spotify') {
        if ($errorLower -match 'no spotify|spotify.*not found|spotify not installed') {
            return "Spotify not found.`nPlease install Spotify first, then run this tool again."
        }
        if ($errorLower -match 'already applied|already installed') {
            return "Spicetify appears to already be installed.`nUse Uninstall first, or try Repair."
        }
    }

    if ($RawError.Length -gt 200) {
        return $RawError.Substring(0, 200) + "..."
    }
    return $RawError
}

if (-not ('Spm.StepModel' -as [type])) {
    Add-Type -TypeDefinition @'
using System.ComponentModel;

namespace Spm {
    public sealed class StepModel : INotifyPropertyChanged {
        private string _name;
        private string _tooltip;
        private string _icon;
        private string _iconColor;
        private string _textColor;
        private string _state;

        public event PropertyChangedEventHandler PropertyChanged;

        public StepModel(string name, string tooltip) {
            _name = name;
            _tooltip = tooltip;
            _icon = "\u25CB";
            _iconColor = "#FF535353";
            _textColor = "#FF7F7F7F";
            _state = "Pending";
        }

        public string Name    { get { return _name; } }
        public string Tooltip { get { return _tooltip; } }

        public string Icon {
            get { return _icon; }
            set { if (_icon != value) { _icon = value; OnChanged("Icon"); } }
        }
        public string IconColor {
            get { return _iconColor; }
            set { if (_iconColor != value) { _iconColor = value; OnChanged("IconColor"); } }
        }
        public string TextColor {
            get { return _textColor; }
            set { if (_textColor != value) { _textColor = value; OnChanged("TextColor"); } }
        }
        public string State {
            get { return _state; }
            set { if (_state != value) { _state = value; OnChanged("State"); } }
        }

        private void OnChanged(string propertyName) {
            var handler = PropertyChanged;
            if (handler != null) handler(this, new PropertyChangedEventArgs(propertyName));
        }
    }
}
'@ -ErrorAction Stop
}

$Script:WorkflowSteps = [System.Collections.ObjectModel.ObservableCollection[object]]::new()

function New-StepModel {
    param(
        [string]$Name,
        [string]$Tooltip
    )
    return New-Object Spm.StepModel -ArgumentList $Name, $Tooltip
}

function Set-StepVisual {
    param($Step, [string]$State)
    switch ($State) {
        'Pending' { $Step.Icon = [char]0x25CB; $Step.IconColor = '#FF535353'; $Step.TextColor = '#FF7F7F7F' }
        'Active'  { $Step.Icon = [char]0x25D4; $Step.IconColor = '#FF1DB954'; $Step.TextColor = '#FFFFFFFF' }
        'Done'    { $Step.Icon = [char]0x2713; $Step.IconColor = '#FF1DB954'; $Step.TextColor = '#FFB3B3B3' }
        'Warn'    { $Step.Icon = [char]0x26A0; $Step.IconColor = '#FFFFD700'; $Step.TextColor = '#FFB3B3B3' }
        'Fail'    { $Step.Icon = [char]0x2717; $Step.IconColor = '#FFE22134'; $Step.TextColor = '#FFB3B3B3' }
        'Skipped' { $Step.Icon = [char]0x2014; $Step.IconColor = '#FF535353'; $Step.TextColor = '#FF535353' }
    }
    $Step.State = $State
}

function Initialize-WorkflowSteps {
    param([ValidateSet('Full', 'Repair', 'Uninstall')][string]$Mode = 'Full')

    $Script:WorkflowSteps.Clear()
    if ($Mode -eq 'Uninstall') {
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Stop Spotify'     -Tooltip 'Terminate running Spotify processes'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Backup current'   -Tooltip 'Snapshot current customizations before removal'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Remove Spicetify' -Tooltip 'Delete Spicetify CLI binary and data'))
    } elseif ($Mode -eq 'Repair') {
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Stop Spotify'     -Tooltip 'Terminate running Spotify processes'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Backup'           -Tooltip 'Snapshot current customizations'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Repair Spotify'   -Tooltip 'Reinstall Spotify to repair corrupted files'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Spicetify backup' -Tooltip 'Recreate Spicetify backup'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Apply config'     -Tooltip 'Reapply Spicetify configuration'))
    } else {
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Preflight'   -Tooltip 'Environment, network, disk, architecture checks'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Spotify'     -Tooltip 'Detect or install Spotify (skip Store version)'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Backup'      -Tooltip 'Snapshot user customizations'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Spicetify'   -Tooltip 'Install or update Spicetify CLI'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Marketplace' -Tooltip 'Install or update Spicetify Marketplace'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Restore'     -Tooltip 'Restore user customizations'))
        $null = $Script:WorkflowSteps.Add((New-StepModel -Name 'Apply'       -Tooltip 'Apply Spicetify configuration'))
    }
}

function Get-WorkflowStepIndex {
    param([Parameter(Mandatory)][string]$Name)
    for ($i = 0; $i -lt $Script:WorkflowSteps.Count; $i++) {
        if ($Script:WorkflowSteps[$i].Name -eq $Name) { return $i }
    }
    return -1
}

function Set-WindowChrome {
    param(
        [Parameter(Mandatory)]$Window,
        [int]$CaptionHeight = 32,
        [double]$ResizeBorder = 8,
        [string[]]$ChromeButtonNames = @()
    )

    $chrome = New-Object System.Windows.Shell.WindowChrome
    $chrome.CaptionHeight        = $CaptionHeight
    $chrome.ResizeBorderThickness = New-Object System.Windows.Thickness($ResizeBorder)
    $chrome.GlassFrameThickness  = New-Object System.Windows.Thickness(0)
    $chrome.CornerRadius         = New-Object System.Windows.CornerRadius(0)
    $chrome.UseAeroCaptionButtons = $false
    $Window.SetValue([System.Windows.Shell.WindowChrome]::WindowChromeProperty, $chrome)

    foreach ($name in $ChromeButtonNames) {
        $btn = $Window.FindName($name)
        if ($null -ne $btn) {
            $btn.SetValue([System.Windows.Shell.WindowChrome]::IsHitTestVisibleInChromeProperty, $true)
        }
    }
}

function New-MainWindow {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop

    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($Script:MainWindowXaml))
    try {
        $window = [System.Windows.Markup.XamlReader]::Load($reader)
    } finally {
        $reader.Close()
    }

    # Chrome (drag / snap / resize) applied in code -- see Set-WindowChrome
    Set-WindowChrome -Window $window -CaptionHeight 32 -ResizeBorder 8 `
        -ChromeButtonNames @('BtnMinimize', 'BtnMaximize', 'BtnClose', 'BtnSettings')

    $window | Add-Member -MemberType NoteProperty -Name Ctrl -Value @{
        TxtPhase             = $window.FindName('TxtPhase')
        TxtDetail            = $window.FindName('TxtDetail')
        TxtElapsed           = $window.FindName('TxtElapsed')
        TxtEta               = $window.FindName('TxtEta')
        TxtVersion           = $window.FindName('TxtVersion')
        TxtEnvInfo           = $window.FindName('TxtEnvInfo')
        TxtInstalledState    = $window.FindName('TxtInstalledState')
        TxtProgressLabel     = $window.FindName('TxtProgressLabel')
        TxtProgressPercent   = $window.FindName('TxtProgressPercent')
        TxtLastRunStatus     = $window.FindName('TxtLastRunStatus')
        MainProgress         = $window.FindName('MainProgress')
        StepList             = $window.FindName('StepList')
        LogList              = $window.FindName('LogList')
        TxtLogEmptyState     = $window.FindName('TxtLogEmptyState')
        ChkAutoscroll        = $window.FindName('ChkAutoscroll')
        BtnStart             = $window.FindName('BtnStart')
        BtnRepair            = $window.FindName('BtnRepair')
        BtnUninstall         = $window.FindName('BtnUninstall')
        BtnCancel            = $window.FindName('BtnCancel')
        BtnSettings          = $window.FindName('BtnSettings')
        BtnOpenSpicetify     = $window.FindName('BtnOpenSpicetify')
        BtnRestartSpotify    = $window.FindName('BtnRestartSpotify')
        BtnCopyLog           = $window.FindName('BtnCopyLog')
        BtnOpenLog           = $window.FindName('BtnOpenLog')
        BtnExportLog         = $window.FindName('BtnExportLog')
        TxtLogSearch         = $window.FindName('TxtLogSearch')
        CmbLogLevelFilter    = $window.FindName('CmbLogLevelFilter')
        TitleBar             = $window.FindName('TitleBar')
        BtnMinimize          = $window.FindName('BtnMinimize')
        BtnMaximize          = $window.FindName('BtnMaximize')
        BtnClose             = $window.FindName('BtnClose')
    }

    return $window
}

function New-SettingsWindow {
    param($Owner)
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($Script:SettingsWindowXaml))
    try {
        $window = [System.Windows.Markup.XamlReader]::Load($reader)
    } finally {
        $reader.Close()
    }
    if ($Owner) { $window.Owner = $Owner }

    # Not resizable: ResizeBorder 0; caption band for drag; close button clickable
    Set-WindowChrome -Window $window -CaptionHeight 32 -ResizeBorder 0 `
        -ChromeButtonNames @('BtnSettingsClose')
    $window | Add-Member -MemberType NoteProperty -Name Ctrl -Value @{
        TxtMaxRetries       = $window.FindName('TxtMaxRetries')
        TxtRetryDelayMs     = $window.FindName('TxtRetryDelayMs')
        TxtProcessTimeoutMs = $window.FindName('TxtProcessTimeoutMs')
        TxtBackupRetention  = $window.FindName('TxtBackupRetention')
        TxtLogPath          = $window.FindName('TxtLogPath')
        TxtCacheDir         = $window.FindName('TxtCacheDir')
        ChkKeepLog          = $window.FindName('ChkKeepLog')
        ChkSkipPreflight    = $window.FindName('ChkSkipPreflight')
        BtnSaveSettings     = $window.FindName('BtnSaveSettings')
        BtnCancelSettings   = $window.FindName('BtnCancelSettings')
        BtnResetDefaults    = $window.FindName('BtnResetDefaults')
        SettingsTitleBar    = $window.FindName('SettingsTitleBar')
        BtnSettingsClose    = $window.FindName('BtnSettingsClose')
    }
    return $window
}

function Set-UiEnabled {
    param([bool]$Enabled)
    $w = $Script:MainWindow
    if ($null -eq $w) { return }
    $w.Dispatcher.Invoke([Action]{
        $w.Ctrl.BtnStart.IsEnabled          = $Enabled
        $w.Ctrl.BtnRepair.IsEnabled         = $Enabled
        $w.Ctrl.BtnUninstall.IsEnabled      = $Enabled
        $w.Ctrl.BtnSettings.IsEnabled       = $Enabled
        $w.Ctrl.BtnCancel.IsEnabled         = -not $Enabled
        $w.Ctrl.BtnOpenSpicetify.IsEnabled  = $Enabled
        $w.Ctrl.BtnRestartSpotify.IsEnabled = $Enabled
        if ($Enabled) {
            $w.Ctrl.BtnCancel.Content = "Cancel"
            $w.Ctrl.MainProgress.IsIndeterminate = $false
        }
    })
}

function Update-ElapsedClock {
    param([datetime]$StartTime, [datetime]$Now)
    $w = $Script:MainWindow
    if ($null -eq $w -or $null -eq $w.Ctrl.TxtElapsed) { return }
    $elapsed = $Now - $StartTime
    $h = [int]$elapsed.TotalHours
    $m = $elapsed.Minutes
    $s = $elapsed.Seconds
    $elapsedStr = if ($h -gt 0) { '{0:D2}:{1:D2}:{2:D2}' -f $h, $m, $s }
                  else { '{0:D2}:{1:D2}' -f $m, $s }
    $w.Ctrl.TxtElapsed.Text = $elapsedStr
}

function New-UiTimer {
    param()
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds($Script:UI_TIMER_INTERVAL_MS)

    $timer.Add_Tick({
        $w = $Script:MainWindow
        if ($null -eq $w) { return }
        $startTime = $Script:OperationUtcStart
        if ($null -eq $startTime) { $startTime = [datetime]::UtcNow }
        try {
            $drained = 0
            $maxDrainPerTick = 200
            while (-not $Script:LogStream.IsEmpty -and $drained -lt $maxDrainPerTick) {
                $entry = $null
                if ($Script:LogStream.TryDequeue([ref]$entry)) {
                    $Script:LogEntries.Add((Format-LogEntry -Time $entry.Time -Level $entry.Level -Msg $entry.Msg))
                    $drained++
                } else { break }
            }
            # Cap log size to avoid memory bloat (CollectionView follows along)
            $maxLogItems = 5000
            while ($Script:LogEntries.Count -gt $maxLogItems) {
                $Script:LogEntries.RemoveAt(0)
            }
            if ($null -ne $w.Ctrl.TxtLogEmptyState) {
                if ($Script:LogEntries.Count -gt 0) {
                    $w.Ctrl.TxtLogEmptyState.Visibility = [System.Windows.Visibility]::Collapsed
                } else {
                    $w.Ctrl.TxtLogEmptyState.Visibility = [System.Windows.Visibility]::Visible
                }
            }
            if ($drained -gt 0 -and $w.Ctrl.ChkAutoscroll.IsChecked -eq $true -and $Script:LogEntries.Count -gt 0) {
                $w.Ctrl.LogList.ScrollIntoView($Script:LogEntries[$Script:LogEntries.Count - 1])
            }

            while (-not $Script:StepStream.IsEmpty) {
                $evt = $null
                if ($Script:StepStream.TryDequeue([ref]$evt)) {
                    if ($evt.Index -ge 0 -and $evt.Index -lt $Script:WorkflowSteps.Count) {
                        Set-StepVisual -Step $Script:WorkflowSteps[$evt.Index] -State $evt.State
                    }
                } else { break }
            }

            while (-not $Script:ProgressStream.IsEmpty) {
                $p = $null
                if ($Script:ProgressStream.TryDequeue([ref]$p)) {
                    if ($p.Phase) {
                        # Mirror the phase into main scope so exit codes map correctly
                        $Script:CurrentPhase = $p.Phase
                        $w.Ctrl.TxtPhase.Text = $p.Phase
                    }
                    if ($p.Detail) { $w.Ctrl.TxtDetail.Text = $p.Detail }
                    if ($p.Percent -ge 0) {
                        $clamped = [Math]::Min(100, [Math]::Max(0, $p.Percent))
                        $Script:CurrentPhasePercent = $clamped
                        $w.Ctrl.MainProgress.Value = $clamped
                        $w.Ctrl.TxtProgressPercent.Text = $clamped.ToString() + '%'
                        if ($w.Ctrl.MainProgress.IsIndeterminate) {
                            $w.Ctrl.MainProgress.IsIndeterminate = $false
                        }
                    }
                    if ($p.IsIndeterminate) {
                        $w.Ctrl.MainProgress.IsIndeterminate = $true
                    }
                    if ($p.Label) { $w.Ctrl.TxtProgressLabel.Text = $p.Label }
                } else { break }
            }

            Update-ElapsedClock -StartTime $startTime -Now ([datetime]::UtcNow)

            if ($Script:OperationRunning -and $Script:CurrentPhasePercent -gt 3 -and $Script:CurrentPhasePercent -lt 100) {
                $elapsedSoFar = ([datetime]::UtcNow - $startTime).TotalSeconds
                $estTotal = $elapsedSoFar / ($Script:CurrentPhasePercent / 100.0)
                $remaining = [Math]::Max(0, $estTotal - $elapsedSoFar)
                $h = [int]([Math]::Floor($remaining / 3600))
                $m = [int]([Math]::Floor(($remaining % 3600) / 60))
                $s = [int]([Math]::Floor($remaining % 60))
                $etaStr = if ($h -gt 0) { '{0:D2}:{1:D2}:{2:D2}' -f $h, $m, $s }
                          else { '{0:D2}:{1:D2}' -f $m, $s }
                $w.Ctrl.TxtEta.Text = $etaStr
            }

            if ($Script:CancellationToken.IsCancellationRequested) {
                $w.Ctrl.TxtEta.Text = 'cancelling...'
                if ($w.Ctrl.TxtPhase.Text -ne 'Cancelling') {
                    $w.Ctrl.TxtPhase.Text = 'Cancelling'
                    $w.Ctrl.TxtDetail.Text = 'Waiting for operation to stop...'
                    $w.Ctrl.MainProgress.IsIndeterminate = $true
                }
            }
        } catch {
            # Suppress timer errors -- never crash the UI
        }
    })

    return $timer
}

# Functions the worker needs (orchestrator + services + infrastructure).
$Script:WorkerFunctionNames = @(
    # infrastructure
    'Write-Log', 'Write-Step', 'Set-Progress', 'Set-Step',
    'Test-Cancelled', 'Throw-IfCancelled', 'Invoke-WithRetry',
    'Invoke-ExternalCommand', 'Invoke-SpicetifyCli',
    'Copy-ItemSafe', 'Test-ZipIntegrity', 'Wait-ForFileRelease',
    'Wait-ForSpotifyRelease', 'Get-FreeDiskSpaceMB', 'Set-IniValue',
    'Get-DownloadGlobalPercent', 'Invoke-DownloadWithProgress',
    'Get-GitHubLatestRelease', 'Resolve-SpicetifyConfigPaths',
    # domain services
    'Test-NetworkOk', 'Test-MicrosoftStoreSpotify', 'Test-ArchitectureSupported',
    'Test-DiskSpace', 'Stop-SpotifyProcess',
    'Install-Spotify', 'Repair-Spotify',
    'Backup-UserCustomizations', 'Restore-UserCustomizations', 'Save-BackupHistory',
    'Get-SpicetifyLocalVersion', 'Install-Spicetify', 'Uninstall-Spicetify',
    'Install-Marketplace',
    'Get-CombinedOutput', 'Test-BackupOutputForRepair', 'Test-ApplyOutputForFailure',
    'Invoke-SpicetifyBackupWithRepair', 'Apply-SpicetifyConfiguration',
    'Invoke-PreflightChecks',
    # orchestration
    'Start-Phase', 'End-Phase', 'Invoke-Workflow',
    # sidebar helpers referenced by Set-Step / Set-Progress fallbacks
    'Get-WorkflowStepIndex', 'Set-StepVisual', 'Show-ConsoleProgress'
)

function New-WorkerScript {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($name in $Script:WorkerFunctionNames) {
        $cmd = Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue
        if ($null -eq $cmd) {
            throw "Worker assembly failed: function '$name' is not defined."
        }
        $fullText = $cmd.ScriptBlock.Ast.Extent.Text
        if ($fullText -notmatch "^function\s+$([regex]::Escape($name))") {
            throw "Worker assembly sanity check failed for '${name}'."
        }
        $parts.Add($fullText)
        $parts.Add('')
    }

    $bootstrap = @'
$Script:Config          = $Config
$Script:LogStream       = $LogStream
$Script:StepStream      = $StepStream
$Script:ProgressStream  = $ProgressStream
$Script:CancellationToken = $CancellationToken
$Script:ScriptVersion   = $ScriptVersion
$Script:UninstallMode   = $UninstallMode
$Script:RepairMode      = $RepairMode
$Script:SkipPreflight   = $SkipPreflight
$Script:WorkflowSteps   = $WorkflowSteps
$Script:TempFiles       = $TempFiles
$Script:PhaseTimings    = $PhaseTimings
$Script:GUIActive       = $true   # route Write-Step output to the log stream
$Script:NoUI            = $false
$Script:StagingPath     = $null
$Script:StagingValid    = $false
$Script:CurrentPhase    = 'Init'
$Script:PhaseStartTime  = $null
$Script:ExitCodes       = $ExitCodes

try {
    $workflowResult = Invoke-Workflow
    Write-Output $workflowResult
} finally {
    # Worker-side staging cleanup always runs, even on cancellation
    if ($Script:StagingPath -and (Test-Path -LiteralPath $Script:StagingPath)) {
        Remove-Item -Path $Script:StagingPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
'@
    $source = ($parts -join "`n") + "`n" + $bootstrap

    # Parse-gate: never dispatch a broken worker script to a runspace
    $parseErrors = $null
    $tokens = $null
    [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) {
        throw "Assembled worker script has parse errors: $($parseErrors[0].Message)"
    }
    return $source
}

function New-WorkerRunspace {
    param([Parameter(Mandatory)][string]$WorkerSource)

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()

    $rs.SessionStateProxy.SetVariable('Config',          $Script:Config)
    $rs.SessionStateProxy.SetVariable('LogStream',       $Script:LogStream)
    $rs.SessionStateProxy.SetVariable('StepStream',      $Script:StepStream)
    $rs.SessionStateProxy.SetVariable('ProgressStream',  $Script:ProgressStream)
    $rs.SessionStateProxy.SetVariable('CancellationToken', $Script:CancellationToken)
    $rs.SessionStateProxy.SetVariable('ScriptVersion',   $Script:ScriptVersion)
    $rs.SessionStateProxy.SetVariable('UninstallMode',   [bool]$Script:UninstallMode)
    $rs.SessionStateProxy.SetVariable('RepairMode',      [bool]$Script:RepairMode)
    $rs.SessionStateProxy.SetVariable('SkipPreflight',   [bool]$Script:SkipPreflight)
    $rs.SessionStateProxy.SetVariable('WorkflowSteps',   $Script:WorkflowSteps)
    $rs.SessionStateProxy.SetVariable('TempFiles',       $Script:TempFiles)
    $rs.SessionStateProxy.SetVariable('PhaseTimings',    $Script:PhaseTimings)
    $rs.SessionStateProxy.SetVariable('ExitCodes',       $Script:ExitCodes)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript($WorkerSource)

    return [PSCustomObject]@{
        Runspace   = $rs
        PowerShell = $ps
        Handle     = $ps.BeginInvoke()
    }
}

function Set-Progress {
    param(
        [string]$Phase,
        [string]$Detail,
        [int]$Percent = -1,
        [string]$Label,
        [switch]$IsIndeterminate
    )
    if ($Script:GUIActive) {
        $Script:ProgressStream.Enqueue([PSCustomObject]@{
            Phase          = $Phase
            Detail         = $Detail
            Percent        = $Percent
            Label          = $Label
            IsIndeterminate = $IsIndeterminate.IsPresent
        }) | Out-Null
    } else {
        if ($Percent -ge 0) {
            Show-ConsoleProgress -Activity 'Spicetify Manager' -Status $Detail -Percent $Percent
        }
    }
}

function Set-Step {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$State)
    $index = Get-WorkflowStepIndex -Name $Name
    if ($index -lt 0) { return }
    if ($Script:GUIActive) {
        $Script:StepStream.Enqueue([PSCustomObject]@{
            Index = $index
            State = $State
        }) | Out-Null
    } else {
        Set-StepVisual -Step $Script:WorkflowSteps[$index] -State $State
    }
}

function Test-Cancelled {
    return ($null -ne $Script:CancellationToken -and $Script:CancellationToken.IsCancellationRequested)
}

function Throw-IfCancelled {
    if (Test-Cancelled) {
        throw 'Operation cancelled by user.'
    }
}

function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$Label = 'Operation',
        [int]$MaxAttempts,
        [int]$InitialDelayMs
    )

    if (-not $PSBoundParameters.ContainsKey('MaxAttempts')) {
        $MaxAttempts = $Script:Config.MaxRetries
    }
    if (-not $PSBoundParameters.ContainsKey('InitialDelayMs')) {
        $InitialDelayMs = $Script:Config.RetryDelayMs
    }
    if ($MaxAttempts -le 0) { return & $Action }

    $delay = $InitialDelayMs
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Throw-IfCancelled
        try {
            return & $Action
        } catch {
            if ($attempt -eq $MaxAttempts) {
                Write-Log -Message "$Label failed after $MaxAttempts attempts: $($_.Exception.Message)" -Level ERROR
                throw
            }
            Write-Log -Message "$Label attempt $attempt failed (retry in ${delay}ms): $($_.Exception.Message)" -Level WARN
            Start-Sleep -Milliseconds $delay
            $delay = [Math]::Min($delay * 2, 30000)
        }
    }
}

function Get-GitHubLatestRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo
    )

    $uri     = "https://api.github.com/repos/$Owner/$Repo/releases/latest"
    $headers = @{
        'User-Agent' = "SpicetifyManager/$($Script:ScriptVersion)"
        'Accept'     = 'application/vnd.github+json'
    }

    try {
        $response = Invoke-WithRetry -Label 'GitHub API request' -Action {
            Invoke-WebRequest -Uri $uri -UseBasicParsing -Headers $headers -ErrorAction Stop -TimeoutSec 30
        }
        return ($response.Content | ConvertFrom-Json)
    } catch {
        $ex = $_.Exception
        $statusCode = 0
        if ($null -ne $ex -and $null -ne $ex.Response) {
            try { $statusCode = [int]$ex.Response.StatusCode } catch {}
        }

        if ($statusCode -eq 403 -or $ex.Message -match '\(403\)') {
            $resetEpoch = $null
            try { $resetEpoch = $ex.Response.Headers['X-RateLimit-Reset'] } catch {}
            $resetLong = 0
            if ($resetEpoch -and [long]::TryParse("$resetEpoch", [ref]$resetLong)) {
                $resetTime = [DateTimeOffset]::FromUnixTimeSeconds($resetLong).LocalDateTime
                $waitMinutes = [Math]::Ceiling(([DateTimeOffset]$resetTime - [DateTimeOffset]::Now).TotalMinutes)
                $waitMinutes = [Math]::Max(1, $waitMinutes)
                throw "GitHub API rate limit exceeded. Resets at $resetTime (~$waitMinutes min). Please wait and run again."
            }
            throw 'GitHub API rate limit exceeded (60 requests/hour unauthenticated). Please wait an hour and run again.'
        }
        if ($statusCode -eq 404) {
            throw "GitHub repository not found: $Owner/$Repo. The project may have moved."
        }
        throw "Failed to fetch release info from $Owner/$Repo`: $($_.Exception.Message)"
    }
}

function Invoke-ExternalCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [int]$TimeoutMs
    )

    if (-not $PSBoundParameters.ContainsKey('TimeoutMs')) {
        $TimeoutMs = $Script:Config.ProcessTimeoutMs
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $FilePath
    $psi.Arguments              = $Arguments
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    try {
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    } catch {}

    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
    } catch {
        return [PSCustomObject]@{
            ExitCode = -1
            Stdout   = ''
            Stderr   = "Failed to start process: $($_.Exception.Message)"
            TimedOut = $false
        }
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $exited = $process.WaitForExit($TimeoutMs)

    $stdout = ''
    $stderr = ''
    try { $stdout = $stdoutTask.GetAwaiter().GetResult() } catch {}
    try { $stderr = $stderrTask.GetAwaiter().GetResult() } catch {}

    if (-not $exited) {
        try {
            $process.Kill()
            $process.WaitForExit(5000)
        } catch {}
        return [PSCustomObject]@{
            ExitCode = -1
            Stdout   = $stdout
            Stderr   = $stderr
            TimedOut = $true
        }
    }

    return [PSCustomObject]@{
        ExitCode = $process.ExitCode
        Stdout   = $stdout
        Stderr   = $stderr
        TimedOut = $false
    }
}

function Invoke-SpicetifyCli {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Command)

    $exe = $Script:Config.SpicetifyExePath
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "Spicetify executable not found at: $exe"
    }

    $result = Invoke-ExternalCommand -FilePath $exe -Arguments "--bypass-admin $Command"

    if ($result.TimedOut) {
        throw "Spicetify command timed out: $Command"
    }

    return $result
}

function Copy-ItemSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$Recurse
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Log -Message "Source does not exist, skipping copy: $Source" -Level DEBUG
        return
    }

    Invoke-WithRetry -Label "Copy $Source -> $Destination" -Action {
        $params = @{
            Path        = $Source
            Destination = $Destination
            Force       = $true
            ErrorAction = 'Stop'
        }
        if ($Recurse) { $params.Recurse = $true }
        Copy-Item @params
    }
}

function Test-ZipIntegrity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    $archive = $null
    $stream  = $null
    $buffer  = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        $buffer  = [byte[]]::new(8192)
        foreach ($entry in $archive.Entries) {
            $stream = $entry.Open()
            while ($stream.Read($buffer, 0, $buffer.Length) -gt 0) { }
            $stream.Dispose()
            $stream = $null
        }
        return $true
    } catch {
        Write-Log -Message "ZIP integrity check failed for $Path`: $($_.Exception.Message)" -Level ERROR
        return $false
    } finally {
        if ($null -ne $stream)  { $stream.Dispose() }
        if ($null -ne $archive) { $archive.Dispose() }
    }
}

function Wait-ForFileRelease {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    for ($i = 0; $i -lt $Script:Config.FileLockRetries; $i++) {
        Throw-IfCancelled
        try {
            $stream = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
            $stream.Dispose()
            return
        } catch {
            Write-Log -Message "File locked, waiting ($($i + 1)/$($Script:Config.FileLockRetries)): $Path" -Level DEBUG
            Start-Sleep -Milliseconds $Script:Config.FileLockDelayMs
        }
    }
    Write-Log -Message "File still locked after $($Script:Config.FileLockRetries) attempts: $Path. Proceeding." -Level WARN
}

function Wait-ForSpotifyRelease {
    [CmdletBinding()]
    param()

    $spotifyDir = $Script:Config.SpotifyInstallDir
    if (-not (Test-Path -LiteralPath $spotifyDir)) { return }

    $xpuiPath = Join-Path $spotifyDir 'apps\xpui.spa'
    if (Test-Path -LiteralPath $xpuiPath) {
        Wait-ForFileRelease -Path $xpuiPath
        return
    }

    $xpuiFile = Get-ChildItem -Path $spotifyDir -Filter 'xpui.spa' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($xpuiFile) {
        Wait-ForFileRelease -Path $xpuiFile.FullName
    } elseif (Test-Path -LiteralPath $Script:Config.SpotifyExePath) {
        Wait-ForFileRelease -Path $Script:Config.SpotifyExePath
    }
}

function Get-FreeDiskSpaceMB {
    param([string]$Path)

    try {
        $drive = [System.IO.Path]::GetPathRoot((Resolve-Path -Path $Path -ErrorAction Stop).Path)
        $driveInfo = [System.IO.DriveInfo]::new($drive)
        if (-not $driveInfo.IsReady) { return -1 }
        return [int]([Math]::Floor($driveInfo.AvailableFreeSpace / 1MB))
    } catch {
        return -1
    }
}

function Get-DownloadGlobalPercent {
    param(
        [int]$Read,
        [int]$Total,
        [int]$Base,
        [int]$Weight
    )
    if ($Total -le 0) { return -1 }
    if ($Total -lt $Read) { $Read = $Total }
    $dlPct = [int]([Math]::Floor(($Read * 100.0) / $Total))
    if ($dlPct -gt 100) { $dlPct = 100 }
    if ($dlPct -lt 0)   { $dlPct = 0 }
    $global = $Base + [int]([Math]::Floor(($dlPct / 100.0) * $Weight))
    if ($global -gt ($Base + $Weight)) { $global = $Base + $Weight }
    if ($global -lt $Base)              { $global = $Base }
    return $global
}

function Invoke-DownloadWithProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$Label = 'Downloading',
        [int]$BasePercent = 0,
        [int]$Weight = 10,
        [int]$TimeoutMs = 0
    )

    $outDir = Split-Path $OutFile -Parent
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }
    # Truncate any partial file from a previous attempt
    if (Test-Path -LiteralPath $OutFile) {
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
    }

    $request  = $null
    $response = $null
    $inStream  = $null
    $outStream = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($Uri)
        $request.UserAgent = "SpicetifyManager/$($Script:ScriptVersion)"
        $request.AllowAutoRedirect = $true
        if ($TimeoutMs -gt 0) {
            $request.Timeout = $TimeoutMs
            $request.ReadWriteTimeout = $TimeoutMs
        }

        $response = $request.GetResponse()
        $total = $response.ContentLength
        $inStream  = $response.GetResponseStream()
        $outStream = [System.IO.File]::Create($OutFile)

        $buffer    = New-Object byte[] 65536
        $read      = 0
        $lastDlPct = -1

        while ($true) {
            Throw-IfCancelled
            $n = $inStream.Read($buffer, 0, $buffer.Length)
            if ($n -le 0) { break }
            $outStream.Write($buffer, 0, $n)
            $read += $n

            if ($total -gt 0) {
                $dlPct = [int]([Math]::Floor(($read * 100.0) / $total))
                if ($dlPct -gt 100) { $dlPct = 100 }
                if ($dlPct -ne $lastDlPct) {
                    $globalPct = Get-DownloadGlobalPercent -Read $read -Total $total -Base $BasePercent -Weight $Weight
                    Set-Progress -Phase $Label -Detail "$Label $dlPct%" -Percent $globalPct
                    $lastDlPct = $dlPct
                }
            } else {
                # Unknown total (chunked/HEAD-less) -- degrade to indeterminate
                Set-Progress -Phase $Label -Detail $Label -IsIndeterminate
            }
        }
        $outStream.Flush()

        if ($total -gt 0 -and $read -lt $total) {
            throw "Download truncated: got $read of $total bytes"
        }
    } catch {
        if ($outStream) { try { $outStream.Dispose() } catch {} ; $outStream = $null }
        if (Test-Path -LiteralPath $OutFile) {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        }
        throw
    } finally {
        if ($outStream) { $outStream.Dispose() }
        if ($inStream)  { $inStream.Dispose() }
        if ($response)  { $response.Dispose() }
    }
}

function Set-IniValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )

    $dir = Split-Path $FilePath -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    if (-not (Test-Path -LiteralPath $FilePath)) {
        [System.IO.File]::WriteAllText($FilePath, '', [System.Text.UTF8Encoding]::new($false))
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [System.IO.File]::ReadAllLines($FilePath, [System.Text.UTF8Encoding]::new($false))) {
        $lines.Add($line)
    }

    $sectionIndex = -1
    $keyIndex     = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*\[$([regex]::Escape($Section))\]\s*$") {
            $sectionIndex = $i
            break
        }
    }

    if ($sectionIndex -ge 0) {
        $nextSection = $lines.Count
        for ($j = $sectionIndex + 1; $j -lt $lines.Count; $j++) {
            if ($lines[$j] -match '^\s*\[') {
                $nextSection = $j
                break
            }
            if ($lines[$j] -notmatch '^\s*[;#]' -and
                $lines[$j] -match "^\s*$([regex]::Escape($Key))\s*=") {
                $keyIndex = $j
                break
            }
        }

        if ($keyIndex -ge 0) {
            $lines[$keyIndex] = "${Key}=${Value}"
        } else {
            $lines.Insert($nextSection, "${Key}=${Value}")
        }
    } else {
        $lines.Add("[$Section]")
        $lines.Add("${Key}=${Value}")
    }

    [System.IO.File]::WriteAllLines($FilePath, $lines, [System.Text.UTF8Encoding]::new($false))
}

function Resolve-SpicetifyConfigPaths {
    [CmdletBinding()]
    param()

    $iniPath = Join-Path $Script:Config.AppDataPath 'config-xpui.ini'
    if (-not (Test-Path -LiteralPath $iniPath)) { return }

    $lines = [System.IO.File]::ReadAllLines($iniPath, [System.Text.UTF8Encoding]::new($false))

    foreach ($line in $lines) {
        if ($line -match '^\s*spotify_path\s*=\s*(.+)$') {
            $resolved = Join-Path $Matches[1].Trim() 'Spotify.exe'
            if (Test-Path -LiteralPath $resolved) {
                $Script:Config.SpotifyExePath    = $resolved
                $Script:Config.SpotifyInstallDir = $Matches[1].Trim()
                Write-Log -Message "Resolved Spotify path from INI: $($Script:Config.SpotifyExePath)" -Level DEBUG
            }
        }
        elseif ($line -match '^\s*backup_dir\s*=\s*(.+)$') {
            $Script:Config.BackupDir = $Matches[1].Trim()
            Write-Log -Message "Resolved backup_dir from INI: $($Script:Config.BackupDir)" -Level DEBUG
        }
    }
}

function Test-NetworkOk {
    [CmdletBinding()]
    param()

    $endpoints = @(
        @{ Name = 'GitHub API';      Url = 'https://api.github.com' }
        @{ Name = 'GitHub download'; Url = 'https://github.com' }
        @{ Name = 'Spotify CDN';     Url = 'https://download.scdn.co' }
    )

    $failed = @()
    foreach ($ep in $endpoints) {
        Throw-IfCancelled
        try {
            $resp = Invoke-WebRequest -Uri $ep.Url -Method Head -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            Write-Log -Message "Preflight: $($ep.Name) reachable (HTTP $($resp.StatusCode))" -Level DEBUG
        } catch {
            $code = 0
            if ($null -ne $_.Exception.Response) {
                try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            }
            if ($code -ge 400 -and $code -lt 500 -and $code -ne 408 -and $code -ne 429) {
                Write-Log -Message "Preflight: $($ep.Name) reachable (HTTP $code)" -Level DEBUG
            } else {
                Write-Log -Message "Preflight: $($ep.Name) unreachable: $($_.Exception.Message)" -Level WARN
                $failed += $ep.Name
            }
        }
    }

    if ($failed.Count -gt 0) {
        Write-Log -Message "Network unreachable for: $($failed -join ', ')" -Level ERROR
        return $false
    }
    return $true
}

function Test-ArchitectureSupported {
    [CmdletBinding()]
    param()

    $arch = $env:PROCESSOR_ARCHITECTURE
    if (-not $arch) { $arch = [System.Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE') }

    $ok = $true
    $warning = $null

    if ($arch -eq 'ARM64') {
        $ok = $true
        $warning = 'ARM64 detected. Spicetify x64 binary will run via Windows emulation -- functionally supported but slower than native.'
    } elseif ($arch -eq 'x86') {
        $ok = $false
        $warning = '32-bit (x86) Windows detected. Spicetify ships x64-only binaries and is not supported on this architecture.'
    } elseif ($arch -eq 'AMD64') {
        $ok = $true
    } else {
        $warning = "Unknown architecture: $arch. Proceeding with caution."
    }

    return [PSCustomObject]@{
        Ok      = $ok
        Arch    = $arch
        Warning = $warning
    }
}

function Test-MicrosoftStoreSpotify {
    [CmdletBinding()]
    param()

    $storePath = $Script:Config.SpotifyStorePath
    if (Test-Path -LiteralPath $storePath) {
        try {
            $item = Get-Item $storePath -ErrorAction Stop
            if (-not $item.PSIsContainer) {
                return $true
            }
        } catch {
            return $false
        }
    }

    try {
        $pkg = Get-AppxPackage -Name 'SpotifyAB.SpotifyMusic*' -ErrorAction Stop
        if ($pkg) { return $true }
    } catch {
        # Get-AppxPackage may be unavailable on older Windows
    }

    return $false
}

function Test-DiskSpace {
    [CmdletBinding()]
    param()

    $minMB = $Script:Config.MinDiskSpaceMB

    $tempFree = Get-FreeDiskSpaceMB -Path $env:TEMP
    $appFree  = Get-FreeDiskSpaceMB -Path $env:APPDATA

    $ok = ($tempFree -lt 0 -or $tempFree -ge $minMB) -and
          ($appFree -lt 0 -or $appFree -ge $minMB)

    return [PSCustomObject]@{
        Ok         = $ok
        TempFreeMB = $tempFree
        AppFreeMB  = $appFree
        MinMB      = $minMB
    }
}

function Invoke-PreflightChecks {
    [CmdletBinding()]
    param()

    if ($Script:SkipPreflight) {
        Write-Step -Message 'Pre-flight checks skipped by setting.' -Type WARN
        return
    }

    Write-Step -Message 'Running pre-flight checks...' -Type STEP

    $arch = Test-ArchitectureSupported
    if (-not $arch.Ok) {
        Write-Step -Message "  $($arch.Warning)" -Type ERR
        throw $arch.Warning
    }
    if ($arch.Warning) {
        Write-Step -Message "  $($arch.Warning)" -Type WARN
    } else {
        Write-Step -Message "  Architecture: $($arch.Arch) -- OK." -Type OK
    }

    $disk = Test-DiskSpace
    if (-not $disk.Ok) {
        $msg = "Insufficient disk space. Temp: $($disk.TempFreeMB) MB, AppData: $($disk.AppFreeMB) MB. Required: $($disk.MinMB) MB."
        Write-Step -Message "  $msg" -Type ERR
        throw $msg
    }
    Write-Step -Message "  Disk space: Temp $($disk.TempFreeMB) MB / AppData $($disk.AppFreeMB) MB -- OK." -Type OK

    if (-not (Test-NetworkOk)) {
        throw 'Network unreachable. Check your connection or proxy.'
    }
    Write-Step -Message '  Network connectivity OK.' -Type OK

    if (Test-MicrosoftStoreSpotify) {
        $msg = @'
Microsoft Store version of Spotify detected. Spicetify cannot modify the Store
version. To use Spicetify:
  1. Open Settings > Apps > Installed apps
  2. Uninstall "Spotify" (the Store version)
  3. Run this tool again -- it will install the standard desktop version
     from https://download.scdn.co/SpotifySetup.exe
'@
        Write-Step -Message '  Microsoft Store Spotify detected!' -Type ERR
        Write-Step -Message $msg -Type ERR
        throw 'Microsoft Store Spotify is not supported by Spicetify. Uninstall it first.'
    }
    Write-Step -Message '  No Microsoft Store Spotify detected.' -Type OK

    # PowerShell 7+ recommendation
    if ($PSVersionTable.PSVersion -lt [version]'7.0') {
        Write-Step -Message "  PowerShell $($PSVersionTable.PSVersion) detected. PS 7+ recommended for best performance." -Type WARN
    } else {
        Write-Step -Message "  PowerShell $($PSVersionTable.PSVersion) -- OK." -Type OK
    }

    Write-Step -Message 'Pre-flight checks passed.' -Type OK
}

function Stop-SpotifyProcess {
    [CmdletBinding()]
    param([switch]$Force)

    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^Spotify' })
    if ($procs.Count -eq 0) { return }

    Write-Log -Message "Stopping $($procs.Count) Spotify process(es)" -Level INFO
    try {
        $procs | Stop-Process -Force -ErrorAction Continue
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while ((@(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^Spotify' })).Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 500
        }
    } catch {
        Write-Log -Message "Failed to stop Spotify processes: $($_.Exception.Message)" -Level WARN
    }
}

function Install-Spotify {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Write-Step -Message 'Spotify not found. Installing...' -Type STEP

    if (-not $PSCmdlet.ShouldProcess('Spotify', 'Download and install')) {
        return
    }

    $installerPath = Join-Path $env:TEMP "SpotifySetup_$(New-Guid).exe"
    $null = $Script:TempFiles.Add($installerPath)

    Write-Step -Message '  Downloading Spotify installer...' -Type STEP
    Invoke-WithRetry -Label 'Download Spotify installer' -Action {
        # Real byte-based progress: download spans global 5% -> 15%
        Invoke-DownloadWithProgress `
            -Uri 'https://download.scdn.co/SpotifySetup.exe' `
            -OutFile $installerPath `
            -Label 'Downloading Spotify installer' `
            -BasePercent 5 -Weight 10 `
            -TimeoutMs 180000
    }

    if (-not (Test-Path -LiteralPath $installerPath)) {
        throw 'Spotify installer download failed -- file not created.'
    }
    $size = (Get-Item $installerPath).Length
    if ($size -lt 1024) {
        throw "Spotify installer is suspiciously small ($size bytes). Download may have failed."
    }
    Write-Log -Message "Downloaded Spotify installer: $size bytes" -Level DEBUG

    Write-Step -Message '  Running Spotify installer...' -Type STEP
    # Installer reports no progress of its own -- indeterminate while it runs
    Set-Progress -Phase 'Spotify' -Detail 'Running Spotify installer...' -IsIndeterminate
    $result = Invoke-ExternalCommand -FilePath $installerPath -TimeoutMs 180000

    if ($result.TimedOut) {
        throw 'Spotify installer timed out after 180 seconds'
    }
    # The Spotify web installer routinely returns non-zero even on success
    if ($result.ExitCode -ne 0) {
        Write-Log -Message "Installer exited with code $($result.ExitCode) -- may be normal." -Level WARN
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 120000) {
        if (Test-Path -LiteralPath $Script:Config.SpotifyExePath) {
            Start-Sleep -Seconds 3
            break
        }
        Start-Sleep -Milliseconds 500
    }

    if (-not (Test-Path -LiteralPath $Script:Config.SpotifyExePath)) {
        throw 'Spotify executable not found after installation'
    }

    Stop-SpotifyProcess -Force
    Wait-ForSpotifyRelease
    Write-Step -Message 'Spotify installed.' -Type OK
}

function Repair-Spotify {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Write-Step -Message 'Repairing Spotify...' -Type WARN

    if (Test-Path -LiteralPath $Script:Config.BackupDir) {
        Remove-Item -Path $Script:Config.BackupDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not $PSCmdlet.ShouldProcess('Spotify', 'Repair installation')) {
        return
    }

    Stop-SpotifyProcess -Force
    Wait-ForSpotifyRelease

    $installerPath = Join-Path $env:TEMP "SpotifySetup_$(New-Guid).exe"
    $null = $Script:TempFiles.Add($installerPath)

    Write-Step -Message '  Downloading Spotify installer...' -Type STEP
    Invoke-WithRetry -Label 'Download Spotify installer (repair)' -Action {
        # Real byte-based progress: download spans global 25% -> 40%
        Invoke-DownloadWithProgress `
            -Uri 'https://download.scdn.co/SpotifySetup.exe' `
            -OutFile $installerPath `
            -Label 'Downloading Spotify installer (repair)' `
            -BasePercent 25 -Weight 15 `
            -TimeoutMs 180000
    }

    if (-not (Test-Path -LiteralPath $installerPath)) {
        throw 'Spotify installer download failed during repair.'
    }
    $size = (Get-Item $installerPath).Length
    if ($size -lt 1024) {
        throw "Spotify installer is suspiciously small ($size bytes). Download may have failed."
    }

    Write-Step -Message '  Running Spotify installer...' -Type STEP
    Set-Progress -Phase 'Repair' -Detail 'Running Spotify installer...' -IsIndeterminate
    $result = Invoke-ExternalCommand -FilePath $installerPath -TimeoutMs 180000

    if ($result.TimedOut) {
        throw 'Spotify installer timed out after 180 seconds during repair'
    }
    if ($result.ExitCode -ne 0) {
        Write-Log -Message "Installer exited with code $($result.ExitCode) -- may be normal." -Level WARN
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 120000) {
        if (Test-Path -LiteralPath $Script:Config.SpotifyExePath) {
            Start-Sleep -Seconds 3
            break
        }
        Start-Sleep -Milliseconds 500
    }

    if (-not (Test-Path -LiteralPath $Script:Config.SpotifyExePath)) {
        throw 'Spotify executable not found after repair'
    }

    Stop-SpotifyProcess -Force
    Wait-ForSpotifyRelease
    Write-Step -Message 'Spotify repaired.' -Type OK
}

function Backup-UserCustomizations {
    [CmdletBinding()]
    param()

    if (-not (Test-Path -LiteralPath $Script:Config.AppDataPath)) {
        Write-Log -Message 'No Spicetify app data directory found. Nothing to back up.' -Level INFO
        return
    }

    Write-Log -Message 'Backing up user customizations...' -Level INFO
    Wait-ForSpotifyRelease

    try {
        if (-not $Script:StagingPath) {
            $Script:StagingPath = Join-Path $env:TEMP "spicetify_staging_$(New-Guid)"
        }
        if (-not (Test-Path -LiteralPath $Script:StagingPath)) {
            New-Item -ItemType Directory -Force -Path $Script:StagingPath | Out-Null
        }

        $items = @(
            @{ Src = Join-Path $Script:Config.AppDataPath 'config-xpui.ini'; Dst = $Script:StagingPath; Recurse = $false }
            @{ Src = Join-Path $Script:Config.AppDataPath 'Extensions';     Dst = Join-Path $Script:StagingPath 'Extensions'; Recurse = $true }
            @{ Src = Join-Path $Script:Config.AppDataPath 'Themes';         Dst = Join-Path $Script:StagingPath 'Themes';      Recurse = $true }
            @{ Src = Join-Path $Script:Config.AppDataPath 'CustomApps';     Dst = Join-Path $Script:StagingPath 'CustomApps';  Recurse = $true }
        )

        foreach ($item in $items) {
            if (Test-Path -LiteralPath $item.Src) {
                Copy-ItemSafe -Source $item.Src -Destination $item.Dst -Recurse:$item.Recurse
            }
        }

        # Mark staging as valid BEFORE writing the marker (safer ordering)
        $Script:StagingValid = $true
        New-Item -ItemType File -Path (Join-Path $Script:StagingPath '.backup_complete') -Force | Out-Null
        Write-Log -Message 'Backup completed.' -Level SUCCESS
    } catch {
        $Script:StagingValid = $false
        Write-Log -Message "Backup failed: $($_.Exception.Message)" -Level ERROR
        throw
    }
}

function Save-BackupHistory {
    [CmdletBinding()]
    param()

    if (-not $Script:StagingValid) { return }
    if (-not $Script:StagingPath -or -not (Test-Path -LiteralPath $Script:StagingPath)) { return }

    if (-not (Test-Path -LiteralPath $Script:Config.BackupHistoryDir)) {
        New-Item -ItemType Directory -Force -Path $Script:Config.BackupHistoryDir | Out-Null
    }

    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $histDest = Join-Path $Script:Config.BackupHistoryDir "backup_$ts"
    Copy-ItemSafe -Source $Script:StagingPath -Destination $histDest -Recurse
    Write-Log -Message "Snapshot saved to backup history: $histDest" -Level DEBUG

    $history = @(Get-ChildItem -Path $Script:Config.BackupHistoryDir -Directory -Filter 'backup_*' |
        Sort-Object Name -Descending)
    if ($history.Count -gt $Script:Config.BackupRetention) {
        $toDelete = $history | Select-Object -Skip $Script:Config.BackupRetention
        foreach ($old in $toDelete) {
            Write-Log -Message "Pruning old backup: $($old.FullName)" -Level DEBUG
            Remove-Item -Path $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Restore-UserCustomizations {
    [CmdletBinding()]
    param()

    if (-not $Script:StagingValid) {
        Write-Log -Message 'No valid backup staging data. Skipping restore.' -Level DEBUG
        return
    }

    $marker = Join-Path $Script:StagingPath '.backup_complete'
    if (-not (Test-Path -LiteralPath $marker)) {
        Write-Log -Message 'Backup marker missing. Skipping restore.' -Level WARN
        return
    }

    Write-Log -Message 'Restoring user customizations...' -Level INFO

    try {
        $appData = $Script:Config.AppDataPath

        if (-not (Test-Path -LiteralPath $appData)) {
            New-Item -ItemType Directory -Force -Path $appData | Out-Null
        }

        foreach ($dir in @('Extensions', 'Themes', 'CustomApps')) {
            $target = Join-Path $appData $dir
            if (-not (Test-Path -LiteralPath $target)) {
                New-Item -ItemType Directory -Force -Path $target | Out-Null
            }
        }

        $iniSrc = Join-Path $Script:StagingPath 'config-xpui.ini'
        if (Test-Path -LiteralPath $iniSrc) {
            Copy-ItemSafe -Source $iniSrc -Destination $appData
        }

        foreach ($dir in @('Extensions', 'Themes', 'CustomApps')) {
            $src = Join-Path $Script:StagingPath $dir
            if (Test-Path -LiteralPath $src) {
                Copy-ItemSafe -Source "$src\*" -Destination (Join-Path $appData $dir) -Recurse
            }
        }

        Write-Log -Message 'Customizations restored.' -Level SUCCESS
    } catch {
        throw "Restore failed: $($_.Exception.Message)"
    }
}

function Get-SpicetifyLocalVersion {
    [CmdletBinding()]
    param()

    if (-not (Test-Path -LiteralPath $Script:Config.SpicetifyExePath)) { return $null }

    try {
        $r = Invoke-SpicetifyCli '--version'
        if ($r.ExitCode -ne 0) { return $null }
    } catch {
        return $null
    }

    # Spicetify emits: "spicetify 2.39.0" or "2.39.0"
    if ($r.Stdout -match '(\d+\.\d+\.\d+(?:\.\d+)?)') {
        try { return [version]$Matches[1] } catch { return $null }
    }
    return $null
}

function Install-Spicetify {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $exe = $Script:Config.SpicetifyExePath
    $currentVersion = $null
    $release        = $null
    $needsInstall   = -not (Test-Path -LiteralPath $exe)

    if (-not $needsInstall) {
        $currentVersion = Get-SpicetifyLocalVersion
        if ($null -eq $currentVersion) {
            Write-Log -Message 'Local version query failed. Forcing reinstall.' -Level WARN
            $needsInstall = $true
        }
    }

    if (-not $needsInstall) {
        $release = Get-GitHubLatestRelease -Owner 'spicetify' -Repo 'cli'
        $latestTag = $release.tag_name -replace '^v', '' -replace '-.*$', ''
        $latestVersion = $null
        try {
            $latestVersion = [version]$latestTag
        } catch {
            Write-Log -Message "Could not parse remote version '$latestTag'. Forcing reinstall." -Level WARN
            $needsInstall = $true
        }

        if (-not $needsInstall -and $currentVersion -ge $latestVersion) {
            Write-Step -Message "Spicetify $currentVersion is current (latest: $latestVersion)." -Type OK
            return
        }
        if (-not $needsInstall) {
            Write-Step -Message "Upgrading Spicetify $currentVersion -> $latestVersion..." -Type STEP
        }
    } else {
        Write-Step -Message 'Spicetify not found. Installing...' -Type STEP
    }

    if (-not $PSCmdlet.ShouldProcess('Spicetify', 'Install/Update')) {
        return
    }

    if ($null -eq $release) {
        $release = Get-GitHubLatestRelease -Owner 'spicetify' -Repo 'cli'
    }

    # Precise asset match: spicetify-<version>-windows-x64.zip
    $asset = $release.assets | Where-Object {
        $_.name -match '^spicetify-[\d.]+-windows-x64\.zip$'
    } | Select-Object -First 1
    if (-not $asset) {
        throw 'Windows x64 binary not found in latest Spicetify release. Assets: ' + (($release.assets | ForEach-Object { $_.name }) -join ', ')
    }

    $tempZip = $null
    $cachedZip = $null
    if ($Script:Config.EnableCache) {
        if (-not (Test-Path -LiteralPath $Script:Config.CacheDir)) {
            New-Item -ItemType Directory -Force -Path $Script:Config.CacheDir | Out-Null
        }
        # Compute the cache target only after ensuring the directory exists
        $cachedZip = Join-Path $Script:Config.CacheDir $asset.name
        if (Test-Path -LiteralPath $cachedZip) {
            if (Test-ZipIntegrity -Path $cachedZip) {
                Write-Log -Message "Using cached Spicetify binary: $cachedZip" -Level INFO
                $tempZip = $cachedZip
            } else {
                Write-Log -Message 'Cached Spicetify binary is corrupt -- re-downloading.' -Level WARN
                Remove-Item $cachedZip -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not $tempZip) {
        $tempZip = Join-Path $env:TEMP "spicetify_$(New-Guid).zip"
        $null = $Script:TempFiles.Add($tempZip)
        Write-Step -Message '  Downloading Spicetify binary...' -Type STEP
        Invoke-WithRetry -Label 'Download Spicetify binary' -Action {
            # Real byte-based progress: download spans global 30% -> 50%
            Invoke-DownloadWithProgress `
                -Uri $asset.browser_download_url `
                -OutFile $tempZip `
                -Label 'Downloading Spicetify binary' `
                -BasePercent 30 -Weight 20 `
                -TimeoutMs 300000
        }

        if (-not (Test-ZipIntegrity -Path $tempZip)) {
            throw 'Downloaded Spicetify archive is corrupted'
        }

        # Populate the cache for future runs (only when the path was computed)
        if ($Script:Config.EnableCache -and $cachedZip) {
            try {
                Copy-Item -Path $tempZip -Destination $cachedZip -Force -ErrorAction Stop
                Write-Log -Message "Cached Spicetify binary at: $cachedZip" -Level DEBUG
            } catch {
                Write-Log -Message "Failed to cache binary: $($_.Exception.Message)" -Level DEBUG
            }
        }
    }

    $installDir = Split-Path $exe
    if (-not (Test-Path -LiteralPath $installDir)) {
        New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    }

    Write-Step -Message '  Extracting Spicetify...' -Type STEP
    Expand-Archive -Path $tempZip -DestinationPath $installDir -Force

    # Add to PATH using exact path comparison (not wildcard/substring)
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathEntries = if ($userPath) { $userPath -split ';' } else { @() }
    $installDirNorm = $installDir.TrimEnd('\').TrimEnd('/')
    $alreadyInPath = $false
    foreach ($entry in $pathEntries) {
        if ($entry.Trim().TrimEnd('\').TrimEnd('/') -ieq $installDirNorm) {
            $alreadyInPath = $true
            break
        }
    }
    if (-not $alreadyInPath) {
        $separator = if ($userPath -and -not $userPath.EndsWith(';')) { ';' } else { '' }
        [Environment]::SetEnvironmentVariable('Path', "${userPath}${separator}${installDir}", 'User')
        $sessionSep = if ($env:Path -and -not $env:Path.EndsWith(';')) { ';' } else { '' }
        $env:Path = "${env:Path}${sessionSep}${installDir}"
        Write-Log -Message "Added $installDir to user PATH" -Level INFO
    }

    if (-not (Test-Path -LiteralPath $exe)) {
        throw "Spicetify executable not found after extraction: $exe"
    }

    Write-Step -Message 'Spicetify installed.' -Type OK
}

function Uninstall-Spicetify {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Write-Step -Message 'Uninstalling Spicetify...' -Type STEP

    Stop-SpotifyProcess -Force
    Wait-ForSpotifyRelease

    if (-not $PSCmdlet.ShouldProcess('Spicetify', 'Uninstall')) {
        return
    }

    if (Test-Path -LiteralPath $Script:Config.SpicetifyExePath) {
        Write-Step -Message '  Restoring Spotify to pre-Spicetify state...' -Type STEP
        $r = Invoke-SpicetifyCli 'restore'
        Write-Log -Message "Restore exit code: $($r.ExitCode)" -Level DEBUG
        Write-Log -Message "Restore stdout: $($r.Stdout)" -Level DEBUG
        if ($r.Stderr) { Write-Log -Message "Restore stderr: $($r.Stderr)" -Level DEBUG }
    }

    foreach ($p in @(
        $Script:Config.AppDataPath,
        (Split-Path $Script:Config.SpicetifyExePath)
    )) {
        if (Test-Path -LiteralPath $p) {
            Write-Step -Message "  Removing $p ..." -Type STEP
            Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath) {
        $installDir = Split-Path $Script:Config.SpicetifyExePath
        $installDirNorm = $installDir.TrimEnd('\').TrimEnd('/')
        $newEntries = @()
        foreach ($entry in ($userPath -split ';')) {
            if ($entry.Trim().TrimEnd('\').TrimEnd('/') -ine $installDirNorm -and $entry.Trim() -ne '') {
                $newEntries += $entry.Trim()
            }
        }
        [Environment]::SetEnvironmentVariable('Path', ($newEntries -join ';'), 'User')
    }

    Write-Step -Message 'Spicetify uninstalled.' -Type OK
}

function Install-Marketplace {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $dest = $Script:Config.MarketplaceDest

    if (-not $PSCmdlet.ShouldProcess('Marketplace', 'Install/Update')) {
        return
    }

    # Clear destination first to remove stale files from previous versions
    if (Test-Path -LiteralPath $dest) {
        Write-Step -Message '  Clearing old Marketplace files...' -Type STEP
        Remove-Item -Path $dest -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null

    $zipPath = Join-Path $dest 'marketplace.zip'
    $null = $Script:TempFiles.Add($zipPath)

    Write-Step -Message '  Downloading Marketplace...' -Type STEP
    Invoke-WithRetry -Label 'Download Marketplace' -Action {
        # Real byte-based progress: download spans global 60% -> 70%
        Invoke-DownloadWithProgress `
            -Uri 'https://github.com/spicetify/marketplace/releases/latest/download/marketplace.zip' `
            -OutFile $zipPath `
            -Label 'Downloading Marketplace' `
            -BasePercent 60 -Weight 10 `
            -TimeoutMs 300000
    }

    if (-not (Test-ZipIntegrity -Path $zipPath)) {
        $size = 0
        try { $size = (Get-Item $zipPath -ErrorAction Stop).Length } catch {}
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        if ($size -lt 1024) {
            throw "Downloaded Marketplace file is suspiciously small ($size bytes). URL may have returned an error page."
        }
        throw 'Downloaded Marketplace archive is corrupted'
    }

    Write-Step -Message '  Extracting Marketplace...' -Type STEP
    Expand-Archive -Path $zipPath -DestinationPath $dest -Force
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    $null = $Script:TempFiles.Remove($zipPath)

    Write-Step -Message 'Marketplace installed.' -Type OK
}

function Get-CombinedOutput {
    param($Result)
    $parts = @()
    if ($Result.Stdout) { $parts += $Result.Stdout }
    if ($Result.Stderr) { $parts += $Result.Stderr }
    return ($parts -join "`n")
}

function Test-BackupOutputForRepair {
    param([string]$Output)
    if (-not $Output) { return $false }
    return $Output.ToLower() -match 'cannot be backed up|mismatched|failed to backup|reinstall spotify'
}

function Test-ApplyOutputForFailure {
    param([string]$Output, [int]$ExitCode)
    if ($ExitCode -ne 0) {
        $lower = "$Output".ToLower()
        if ($lower -match 'version mismatch|cannot find symbol') {
            return @{ Fatal = $false; Reason = 'version_mismatch' }
        }
        return @{ Fatal = $true; Reason = 'non_zero_exit' }
    }
    $lower = "$Output".ToLower()
    if ($lower -match "haven't backed up|cannot be backed up|failed to apply") {
        return @{ Fatal = $true; Reason = 'explicit_failure_phrase' }
    }
    return @{ Fatal = $false; Reason = 'ok' }
}

function Invoke-SpicetifyBackupWithRepair {
    [CmdletBinding()]
    param()

    if (Test-Path -LiteralPath $Script:Config.BackupDir) {
        Remove-Item -Path $Script:Config.BackupDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $r = Invoke-SpicetifyCli 'backup'
    $out = Get-CombinedOutput -Result $r
    if (Test-BackupOutputForRepair -Output $out) {
        Write-Step -Message '  Spotify needs repair. Running repair...' -Type WARN
        Repair-Spotify
        Stop-SpotifyProcess -Force
        Wait-ForSpotifyRelease
        $r = Invoke-SpicetifyCli 'backup'
        $out = Get-CombinedOutput -Result $r
        if ($r.ExitCode -ne 0 -and (Test-BackupOutputForRepair -Output $out)) {
            throw "Spicetify backup failed after repair (exit $($r.ExitCode)): $out"
        }
    } elseif ($r.ExitCode -ne 0) {
        throw "Spicetify backup failed (exit $($r.ExitCode)): $out"
    }
}

function Apply-SpicetifyConfiguration {
    [CmdletBinding()]
    param()

    Write-Step -Message 'Applying Spicetify configuration...' -Type STEP

    Stop-SpotifyProcess
    Wait-ForSpotifyRelease

    Write-Step -Message '  Creating Spicetify backup...' -Type STEP
    Invoke-SpicetifyBackupWithRepair

    Write-Step -Message '  Configuring Marketplace custom app...' -Type STEP
    $configResult = Invoke-SpicetifyCli 'config custom_apps marketplace'
    if ($configResult.ExitCode -ne 0) {
        Write-Log -Message "Marketplace config returned exit $($configResult.ExitCode)" -Level WARN
    }

    $marketplaceThemeDir = Join-Path $Script:Config.AppDataPath 'Themes\marketplace'
    if (-not (Test-Path -LiteralPath $marketplaceThemeDir)) {
        Write-Step -Message '  Creating Marketplace placeholder theme...' -Type STEP
        New-Item -ItemType Directory -Force -Path $marketplaceThemeDir | Out-Null

        $colorIni = @'
[Base]
text               = FFFFFF
subtext            = B3B3B3
main               = 121212
sidebar            = 000000
player             = 181818
card               = 282828
shadow             = 000000
selected-row       = FFFFFF
button             = 1DB954
button-active      = 1DB954
button-disabled    = 535353
tab-active         = FFFFFF
notification       = 1DB954
notification-error = E22134
misc               = B3B3B3
'@
        $colorIniPath = Join-Path $marketplaceThemeDir 'color.ini'
        [System.IO.File]::WriteAllText($colorIniPath, $colorIni, [System.Text.UTF8Encoding]::new($false))
    }

    Write-Step -Message '  Setting current_theme to marketplace...' -Type STEP
    $themeResult = Invoke-SpicetifyCli 'config current_theme marketplace'
    if ($themeResult.ExitCode -ne 0) {
        Write-Log -Message "current_theme config returned exit $($themeResult.ExitCode)" -Level WARN
    }

    Write-Step -Message '  Applying Spicetify customizations...' -Type STEP
    $applyResult = Invoke-SpicetifyCli 'apply'
    $applyOutput = Get-CombinedOutput -Result $applyResult

    $verdict = Test-ApplyOutputForFailure -Output $applyOutput -ExitCode $applyResult.ExitCode

    if ($verdict.Fatal) {
        Write-Step -Message "  Apply failed ($($verdict.Reason)). Running repair..." -Type WARN
        Write-Log -Message "Apply output: $applyOutput" -Level DEBUG

        Repair-Spotify
        Stop-SpotifyProcess -Force
        Wait-ForSpotifyRelease

        Write-Step -Message '  Creating fresh backup after repair...' -Type STEP
        Invoke-SpicetifyBackupWithRepair

        Write-Step -Message '  Retrying apply...' -Type STEP
        $applyResult = Invoke-SpicetifyCli 'apply'
        $applyOutput = Get-CombinedOutput -Result $applyResult
        $verdict = Test-ApplyOutputForFailure -Output $applyOutput -ExitCode $applyResult.ExitCode

        if ($verdict.Fatal) {
            throw "Spicetify apply failed even after repair ($($verdict.Reason), exit $($applyResult.ExitCode)): $applyOutput"
        }
    }

    if ($applyOutput.ToLower() -match 'version mismatch|cannot find symbol') {
        Write-Step -Message '  Spotify is newer than Spicetify fully supports. Some features may have issues.' -Type WARN
        Write-Log -Message 'Check for Spicetify update: https://github.com/spicetify/cli/releases' -Level WARN
    }

    Write-Step -Message '  Verifying config INI...' -Type STEP
    $iniPath = Join-Path $Script:Config.AppDataPath 'config-xpui.ini'
    try {
        Set-IniValue -FilePath $iniPath -Section 'Setting'           -Key 'current_theme' -Value 'marketplace'
        Set-IniValue -FilePath $iniPath -Section 'AdditionalOptions' -Key 'custom_apps'   -Value 'marketplace'
        Write-Log -Message 'INI verified: current_theme=marketplace, custom_apps=marketplace' -Level SUCCESS
    } catch {
        Write-Log -Message "Failed to write INI: $($_.Exception.Message)" -Level WARN
    }

    Write-Step -Message 'Configuration applied.' -Type OK
}

function Start-Phase {
    param([string]$Name)
    $Script:CurrentPhase = $Name
    $Script:PhaseStartTime = [DateTime]::UtcNow
    Write-Log -Message "Entering phase: $Name" -Level INFO
}

function End-Phase {
    param([string]$Name)
    if ($null -ne $Script:PhaseStartTime) {
        $elapsed = [DateTime]::UtcNow - $Script:PhaseStartTime
        $Script:PhaseTimings[$Name] = $elapsed
        Write-Log -Message "Phase $Name completed in $([Math]::Round($elapsed.TotalSeconds, 2))s" -Level INFO
    }
}

function Invoke-Workflow {
    [CmdletBinding()]
    param()

    $result = [PSCustomObject]@{
        SuccessSteps = @()
        WarningSteps = @()
    }

    Write-Log -Message "Log file: $($Script:Config.LogFilePath)" -Level INFO

    try {
        if ($Script:UninstallMode) {
            Start-Phase 'Uninstall'
            Set-Progress -Phase 'Uninstall' -Detail 'Stopping Spotify' -Percent 5

            Set-Step -Name 'Stop Spotify' -State 'Active'
            Throw-IfCancelled
            Stop-SpotifyProcess -Force
            Wait-ForSpotifyRelease
            Set-Step -Name 'Stop Spotify' -State 'Done'
            $result.SuccessSteps += 'Spotify stopped'

            Set-Step -Name 'Backup current' -State 'Active'
            Set-Progress -Phase 'Uninstall' -Detail 'Backing up current customizations' -Percent 15
            Throw-IfCancelled
            Backup-UserCustomizations
            Save-BackupHistory
            Set-Step -Name 'Backup current' -State 'Done'
            $result.SuccessSteps += 'Final snapshot preserved'

            Set-Step -Name 'Remove Spicetify' -State 'Active'
            Set-Progress -Phase 'Uninstall' -Detail 'Removing Spicetify' -Percent 40
            Throw-IfCancelled
            Uninstall-Spicetify
            Set-Step -Name 'Remove Spicetify' -State 'Done'
            $result.SuccessSteps += 'Spicetify removed'

            Set-Progress -Phase 'Uninstall' -Detail 'Done' -Percent 100
            Write-Step -Message "Uninstall completed. Customization snapshots kept in $($Script:Config.BackupHistoryDir)" -Type OK
            End-Phase 'Uninstall'

        } elseif ($Script:RepairMode) {
            Set-Step -Name 'Stop Spotify' -State 'Active'
            Set-Progress -Phase 'Repair' -Detail 'Stopping Spotify' -Percent 5
            Start-Phase 'SpotifyInstall'
            Throw-IfCancelled
            Stop-SpotifyProcess -Force
            Wait-ForSpotifyRelease

            if (-not (Test-Path -LiteralPath $Script:Config.SpotifyExePath)) {
                throw 'Spotify is not installed. Cannot repair. Run the full install first.'
            }
            Set-Step -Name 'Stop Spotify' -State 'Done'
            $result.SuccessSteps += 'Spotify stopped'
            End-Phase 'SpotifyInstall'

            Set-Step -Name 'Backup' -State 'Active'
            Set-Progress -Phase 'Repair' -Detail 'Backing up customizations' -Percent 20
            Start-Phase 'Backup'
            Throw-IfCancelled
            Backup-UserCustomizations
            Save-BackupHistory
            Set-Step -Name 'Backup' -State 'Done'
            $result.SuccessSteps += 'Customizations backed up'
            End-Phase 'Backup'

            Set-Step -Name 'Repair Spotify' -State 'Active'
            Set-Progress -Phase 'Repair' -Detail 'Reinstalling Spotify...' -Percent 25
            Start-Phase 'Apply'
            Throw-IfCancelled
            Repair-Spotify
            Stop-SpotifyProcess -Force
            Wait-ForSpotifyRelease
            Set-Step -Name 'Repair Spotify' -State 'Done'
            $result.SuccessSteps += 'Spotify reinstalled'

            Set-Step -Name 'Spicetify backup' -State 'Active'
            Set-Progress -Phase 'Repair' -Detail 'Recreating Spicetify backup' -Percent 55
            Throw-IfCancelled
            Invoke-SpicetifyBackupWithRepair
            Set-Step -Name 'Spicetify backup' -State 'Done'
            $result.SuccessSteps += 'Spicetify backup recreated'

            Set-Step -Name 'Apply config' -State 'Active'
            Set-Progress -Phase 'Repair' -Detail 'Reapplying Spicetify config' -Percent 70
            Throw-IfCancelled
            Apply-SpicetifyConfiguration
            Set-Step -Name 'Apply config' -State 'Done'
            $result.SuccessSteps += 'Configuration reapplied'
            End-Phase 'Apply'

            Set-Progress -Phase 'Repair' -Detail 'Done' -Percent 100
            Write-Step -Message 'Repair completed.' -Type OK

        } else {
            Set-Step -Name 'Preflight' -State 'Active'
            Set-Progress -Phase 'Preflight' -Detail 'Running pre-flight checks' -Percent 2
            Start-Phase 'Preflight'
            Throw-IfCancelled
            Invoke-PreflightChecks
            Set-Step -Name 'Preflight' -State 'Done'
            $result.SuccessSteps += 'Pre-flight checks passed'
            End-Phase 'Preflight'

            Start-Phase 'Init'
            Resolve-SpicetifyConfigPaths
            End-Phase 'Init'

            Set-Step -Name 'Spotify' -State 'Active'
            Set-Progress -Phase 'Spotify' -Detail 'Checking Spotify' -Percent 5
            Start-Phase 'SpotifyInstall'
            Throw-IfCancelled
            Stop-SpotifyProcess -Force

            if (-not (Test-Path -LiteralPath $Script:Config.SpotifyExePath)) {
                Set-Progress -Phase 'Spotify' -Detail 'Installing Spotify...' -Percent 5
                Install-Spotify
                $result.SuccessSteps += 'Spotify installed'
            } else {
                Write-Step -Message 'Spotify found.' -Type OK
                $result.SuccessSteps += 'Spotify found'
            }
            Set-Step -Name 'Spotify' -State 'Done'
            End-Phase 'SpotifyInstall'

            Set-Step -Name 'Backup' -State 'Active'
            Set-Progress -Phase 'Backup' -Detail 'Backing up customizations...' -Percent 20 -IsIndeterminate
            Start-Phase 'Backup'
            Throw-IfCancelled
            Backup-UserCustomizations
            Save-BackupHistory
            Set-Step -Name 'Backup' -State 'Done'
            $result.SuccessSteps += 'Customizations backed up (history kept)'
            End-Phase 'Backup'

            Set-Step -Name 'Spicetify' -State 'Active'
            Set-Progress -Phase 'Spicetify' -Detail 'Installing Spicetify...' -Percent 30
            Start-Phase 'SpicetifyInstall'
            Throw-IfCancelled
            Install-Spicetify

            if (-not (Test-Path -LiteralPath $Script:Config.SpicetifyExePath)) {
                throw 'Spicetify not installed. Cannot continue.'
            }
            Set-Step -Name 'Spicetify' -State 'Done'
            $result.SuccessSteps += 'Spicetify installed/updated'
            End-Phase 'SpicetifyInstall'

            Set-Step -Name 'Marketplace' -State 'Active'
            Set-Progress -Phase 'Marketplace' -Detail 'Installing Marketplace...' -Percent 60
            Start-Phase 'Marketplace'
            Throw-IfCancelled
            Write-Step -Message 'Installing Marketplace...' -Type STEP
            Install-Marketplace
            Set-Step -Name 'Marketplace' -State 'Done'
            $result.SuccessSteps += 'Marketplace installed'
            End-Phase 'Marketplace'

            Set-Step -Name 'Restore' -State 'Active'
            Set-Progress -Phase 'Restore' -Detail 'Restoring customizations...' -Percent 75
            Start-Phase 'Restore'
            Throw-IfCancelled
            Restore-UserCustomizations
            Set-Step -Name 'Restore' -State 'Done'
            $result.SuccessSteps += 'Customizations restored'
            End-Phase 'Restore'

            Set-Step -Name 'Apply' -State 'Active'
            Set-Progress -Phase 'Apply' -Detail 'Applying configuration...' -Percent 85
            Start-Phase 'Apply'
            Throw-IfCancelled
            Apply-SpicetifyConfiguration
            Set-Step -Name 'Apply' -State 'Done'
            $result.SuccessSteps += 'Configuration applied'
            End-Phase 'Apply'

            Set-Progress -Phase 'Complete' -Detail 'Done' -Percent 100
            Write-Step -Message 'Workflow completed successfully.' -Type OK
        }
    } catch {
        # Mark the in-flight step as failed and the rest as skipped
        for ($i = 0; $i -lt $Script:WorkflowSteps.Count; $i++) {
            if ($Script:WorkflowSteps[$i].State -eq 'Active') {
                Set-Step -Name $Script:WorkflowSteps[$i].Name -State 'Fail'
            }
        }
        for ($i = 0; $i -lt $Script:WorkflowSteps.Count; $i++) {
            if ($Script:WorkflowSteps[$i].State -eq 'Pending') {
                Set-Step -Name $Script:WorkflowSteps[$i].Name -State 'Skipped'
            }
        }
        if ($null -ne $Script:PhaseStartTime) {
            End-Phase $Script:CurrentPhase
        }
        throw
    }

    return $result
}

function Update-InstalledStateInfo {
    param($Window)

    $spotifyFound   = $false
    $spicetifyFound = $false
    $spotifyVersion   = 'Not Found'
    $spicetifyVersion = 'Not Found'

    try {
        $spotifyPaths = @(
            "${env:PROGRAMFILES}\Spotify\Spotify.exe"
            "${env:PROGRAMFILES(X86)}\Spotify\Spotify.exe"
            "$env:LOCALAPPDATA\Microsoft\WindowsApps\Spotify.exe"
            "$env:LOCALAPPDATA\Spotify\Spotify.exe"
            "$env:LOCALAPPDATA\Programs\Spotify\Spotify.exe"
            "${env:APPDATA}\Spotify\Spotify.exe"
        )
        foreach ($path in $spotifyPaths) {
            if ($path -and (Test-Path -LiteralPath $path)) {
                $spotifyFound = $true
                try {
                    $spotifyVersion = (Get-Item $path).VersionInfo.FileVersion
                    if (-not $spotifyVersion) { $spotifyVersion = 'Installed' }
                } catch {
                    $spotifyVersion = 'Installed'
                }
                break
            }
        }

        try {
            $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
            $spotifyReg = Get-ItemProperty $regPath -ErrorAction SilentlyContinue |
                          Where-Object { $_.DisplayName -like '*Spotify*' }
            if ($spotifyReg) { $spotifyFound = $true }
        } catch {}

        # Spicetify: managed path first, then PATH, then common alternates
        $spicetifyExePath = $null
        if (Test-Path -LiteralPath $Script:Config.SpicetifyExePath) {
            $spicetifyFound = $true
            $spicetifyExePath = $Script:Config.SpicetifyExePath
        } else {
            try {
                $inPath = Get-Command spicetify -ErrorAction SilentlyContinue
                if ($inPath) {
                    $spicetifyFound = $true
                    $spicetifyExePath = $inPath.Source
                }
            } catch {}
        }
        if (-not $spicetifyFound) {
            foreach ($path in @(
                (Join-Path $env:USERPROFILE '.spicetify\spicetify.exe')
                (Join-Path $env:LOCALAPPDATA 'spicetify\spicetify.exe')
            )) {
                if (Test-Path -LiteralPath $path) {
                    $spicetifyFound = $true
                    $spicetifyExePath = $path
                    break
                }
            }
        }

        if ($spicetifyFound -and $spicetifyExePath) {
            try {
                $verOutput = & $spicetifyExePath --version 2>$null
                if ("$verOutput" -match '\d+\.\d+(\.\d+)?') {
                    $spicetifyVersion = $Matches[0]
                } else {
                    $spicetifyVersion = 'Installed'
                }
            } catch {
                $spicetifyVersion = 'Installed'
            }
        }
    } catch {
        Write-Log -Message "Detection error: $($_.Exception.Message)" -Level DEBUG
    }

    $spotifyStatus   = if ($spotifyFound)   { "[OK] v$spotifyVersion" }   else { '[--] Not Found' }
    $spicetifyStatus = if ($spicetifyFound) { "[OK] v$spicetifyVersion" } else { '[--] Not Found' }
    if ($Window) {
        $Window.Ctrl.TxtInstalledState.Text = "Spotify: $spotifyStatus | Spicetify: $spicetifyStatus"
    }

    return [PSCustomObject]@{
        SpotifyFound   = $spotifyFound
        SpicetifyFound = $spicetifyFound
    }
}

function Start-Operation {
    param(
        [Parameter(Mandatory)][ValidateSet('Full', 'Repair', 'Uninstall')][string]$Mode,
        [Parameter(Mandatory)][string]$ConfirmTitle,
        [Parameter(Mandatory)][string]$ConfirmBody
    )

    if ($Script:OperationRunning) { return }

    $w = $Script:MainWindow

    if ([System.Windows.MessageBox]::Show($w, $ConfirmBody, $ConfirmTitle,
            [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question) -ne 'Yes') {
        return
    }

    $Script:UninstallMode        = ($Mode -eq 'Uninstall')
    $Script:RepairMode           = ($Mode -eq 'Repair')
    $Script:OperationRunning     = $true
    $Script:CurrentPhasePercent  = 0
    $Script:CurrentOpLabel       = $Mode
    $Script:CancellationToken    = [System.Threading.CancellationTokenSource]::new()
    $Script:OperationStartTime   = Get-Date
    $Script:CurrentPhase         = 'Init'

    Initialize-WorkflowSteps -Mode $Mode

    $w.Ctrl.LogList.Items.Refresh()
    $Script:LogEntries.Clear()
    $w.Ctrl.MainProgress.Value = 0
    $w.Ctrl.TxtProgressPercent.Text = '0%'
    $w.Ctrl.TxtProgressLabel.Text = "Starting $($Mode.ToLower())..."
    $w.Ctrl.TxtEta.Text = '--:--'
    $w.Ctrl.TxtPhase.Text = 'Starting'
    $w.Ctrl.TxtDetail.Text = ''

    Set-UiEnabled -Enabled $false

    $startTime = [datetime]::UtcNow
    $Script:OperationUtcStart = $startTime
    $uiTimer = New-UiTimer
    $uiTimer.Start()
    $w | Add-Member -MemberType NoteProperty -Name UiTimer -Value $uiTimer -Force

    # Assemble the worker FROM the live function definitions (parse-gated)
    $workerSource = New-WorkerScript
    $Script:RunspaceState = New-WorkerRunspace -WorkerSource $workerSource

    if ($null -ne $Script:CompletionTimer) {
        $Script:CompletionTimer.Stop()
    }
    $Script:CompletionTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $Script:CompletionTimer.Interval = [TimeSpan]::FromMilliseconds($Script:COMPLETION_POLL_INTERVAL_MS)
    $Script:CompletionTimer.Add_Tick({
        $w = $Script:MainWindow
        if ($null -eq $w) { return }
        if ($null -eq $Script:RunspaceState -or $Script:RunspaceState.Handle.IsCompleted) {
            $Script:CompletionTimer.Stop()

            while (-not $Script:LogStream.IsEmpty) {
                $entry = $null
                if ($Script:LogStream.TryDequeue([ref]$entry)) {
                    $Script:LogEntries.Add((Format-LogEntry -Time $entry.Time -Level $entry.Level -Msg $entry.Msg))
                } else { break }
            }
            if ($w.Ctrl.ChkAutoscroll.IsChecked -eq $true -and $Script:LogEntries.Count -gt 0) {
                $w.Ctrl.LogList.ScrollIntoView($Script:LogEntries[$Script:LogEntries.Count - 1])
            }

            # Retrieve any exception, then dispose the runspace
            $workerError = $null
            try {
                $null = $Script:RunspaceState.PowerShell.EndInvoke($Script:RunspaceState.Handle)
            } catch {
                $workerError = $_.Exception.InnerException
                if ($null -eq $workerError) { $workerError = $_.Exception }
            }
            $Script:RunspaceState.PowerShell.Dispose()
            $Script:RunspaceState.Runspace.Close()
            $Script:RunspaceState.Runspace.Dispose()
            $Script:RunspaceState = $null

            # Clean worker-registered temp files (safe: worker has exited)
            foreach ($path in @($Script:TempFiles)) {
                if (Test-Path -LiteralPath $path) {
                    Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
                }
            }
            $Script:TempFiles.Clear()

            if ($w.UiTimer) { $w.UiTimer.Stop() }
            $Script:OperationRunning = $false

            $opLabel = $Script:CurrentOpLabel
            if ($workerError -and $workerError.Message -match 'cancelled by user') {
                $w.Ctrl.TxtPhase.Text = 'Cancelled'
                $w.Ctrl.TxtDetail.Text = 'Operation was cancelled by user'
                $w.Ctrl.TxtProgressLabel.Text = 'Cancelled'
                $w.Ctrl.TxtEta.Text = 'cancelled'
                $w.Ctrl.MainProgress.IsIndeterminate = $false
                $Script:TotalRuns++
                $w.Ctrl.TxtLastRunStatus.Text = "Last Run: $(Get-Date -Format 'HH:mm:ss') - CANCELLED ($opLabel)"
                $w.Ctrl.TxtLastRunStatus.Foreground = [System.Windows.Media.Brushes]::Orange
                Save-Stats
                $null = [System.Windows.MessageBox]::Show($w,
                    'Operation was cancelled.',
                    'Cancelled',
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Information)
            } elseif ($workerError) {
                $msg = Get-FriendlyErrorMessage -RawError $workerError.Message
                $w.Ctrl.TxtPhase.Text = 'Failed'
                $w.Ctrl.TxtDetail.Text = $msg
                $w.Ctrl.TxtProgressLabel.Text = "Error: $msg"
                $w.Ctrl.TxtEta.Text = 'failed'
                $w.Ctrl.MainProgress.IsIndeterminate = $false
                $errItem = Format-LogEntry -Time (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') -Level 'ERROR' -Msg $workerError.Message
                $Script:LogEntries.Add($errItem)
                if ($Script:LogEntries.Count -gt 0) {
                    $w.Ctrl.LogList.ScrollIntoView($Script:LogEntries[$Script:LogEntries.Count - 1])
                }
                $Script:TotalRuns++
                $Script:FailureCount++
                $w.Ctrl.TxtLastRunStatus.Text = "Last Run: $(Get-Date -Format 'HH:mm:ss') - FAILED ($opLabel)"
                $w.Ctrl.TxtLastRunStatus.Foreground = [System.Windows.Media.Brushes]::Red
                Save-Stats
                $null = [System.Windows.MessageBox]::Show($w,
                    "$opLabel failed:`n`n$msg`n`nSee the log panel for details.",
                    'Spicetify Manager',
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Error)
            } else {
                $w.Ctrl.TxtPhase.Text = 'Complete'
                $w.Ctrl.TxtDetail.Text = ''
                $w.Ctrl.TxtProgressLabel.Text = "$opLabel completed successfully"
                $w.Ctrl.TxtEta.Text = 'done'
                $w.Ctrl.MainProgress.Value = 100
                $w.Ctrl.TxtProgressPercent.Text = '100%'

                $duration = (Get-Date) - $Script:OperationStartTime
                $durationStr = "{0:mm\:ss}" -f $duration
                if ($duration.TotalHours -ge 1) {
                    $durationStr = "{0:h\:mm\:ss}" -f $duration
                }
                $Script:TotalRuns++
                $Script:SuccessCount++
                $w.Ctrl.TxtLastRunStatus.Text = "Last Run: $(Get-Date -Format 'HH:mm:ss') - SUCCESS ($opLabel, $durationStr)"
                $w.Ctrl.TxtLastRunStatus.Foreground = [System.Windows.Media.Brushes]::Green
                Save-Stats

                $extraNote = if ($opLabel -eq 'Uninstall') {
                    "Your customization snapshots were kept in:`n$($Script:Config.BackupHistoryDir)"
                } else { '' }

                $null = [System.Windows.MessageBox]::Show($w,
                    "$opLabel completed successfully.$extraNote",
                    'Spicetify Manager',
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Information)
            }

            Update-InstalledStateInfo -Window $w
            Set-UiEnabled -Enabled $true
        }
    })
    $Script:CompletionTimer.Start()
}

function Show-MainWindow {
    [CmdletBinding()]
    param()

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop

    $Script:GUIActive = $true
    $Script:MainWindow = New-MainWindow
    $w = $Script:MainWindow

    $Script:LogEntries = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    $w.Ctrl.LogList.ItemsSource = $Script:LogEntries
    $Script:LogView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($Script:LogEntries)
    $Script:LogView.Filter = [Predicate[object]]{ param($item) Test-LogEntryVisible -Entry $item }

    $w.Ctrl.StepList.ItemsSource = $Script:WorkflowSteps
    $w.Ctrl.TxtEnvInfo.Text = "PS $($PSVersionTable.PSVersion.ToString())  *  $env:PROCESSOR_ARCHITECTURE"
    $w.Ctrl.TxtVersion.Text = "v$($Script:ScriptVersion)"

    $null = Update-InstalledStateInfo -Window $w
    $w.Ctrl.TxtLastRunStatus.Text = 'Ready'

    $Script:CurrentPhasePercent = 0
    $Script:ProgressStream.Enqueue([PSCustomObject]@{
        Phase = 'Idle'; Detail = ''; Percent = 0; Label = 'Ready'
    }) | Out-Null

    $UpdateMaximizeIcon = {
        $btn = $w.Ctrl.BtnMaximize
        if ($w.WindowState -eq [System.Windows.WindowState]::Maximized) {
            $grid = New-Object System.Windows.Controls.Grid
            $rect1 = New-Object System.Windows.Shapes.Rectangle
            $rect1.Stroke = [System.Windows.Media.Brushes]::White
            $rect1.StrokeThickness = 1.5
            $rect1.Width = 7
            $rect1.Height = 7
            $rect1.Margin = New-Object System.Windows.Thickness(2, 2, 0, 0)
            $rect2 = New-Object System.Windows.Shapes.Rectangle
            $rect2.Stroke = [System.Windows.Media.Brushes]::White
            $rect2.StrokeThickness = 1.5
            $rect2.Width = 7
            $rect2.Height = 7
            $rect2.Margin = New-Object System.Windows.Thickness(0, 0, 2, 2)
            $null = $grid.Children.Add($rect1)
            $null = $grid.Children.Add($rect2)
            $btn.Content = $grid
        } else {
            $rect = New-Object System.Windows.Shapes.Rectangle
            $rect.Stroke = [System.Windows.Media.Brushes]::White
            $rect.StrokeThickness = 1.5
            $rect.Width = 10
            $rect.Height = 10
            $rect.Fill = [System.Windows.Media.Brushes]::Transparent
            $btn.Content = $rect
        }
    }

    $w.Ctrl.BtnMinimize.Add_Click({
        $w.WindowState = [System.Windows.WindowState]::Minimized
    })

    $w.Ctrl.BtnMaximize.Add_Click({
        if ($w.WindowState -eq [System.Windows.WindowState]::Maximized) {
            $w.WindowState = [System.Windows.WindowState]::Normal
        } else {
            $w.WindowState = [System.Windows.WindowState]::Maximized
        }
        & $UpdateMaximizeIcon
    })

    $w.Ctrl.BtnClose.Add_Click({
        $w.Close()
    })

    $w.Add_StateChanged({
        & $UpdateMaximizeIcon
        Save-WindowState -Window $w
    })

    $w.Ctrl.TxtVersion.Add_MouseLeftButtonUp({
        $successRate = if ($Script:TotalRuns -gt 0) {
            [Math]::Round(($Script:SuccessCount / $Script:TotalRuns) * 100)
        } else {
            'N/A'
        }
        $aboutMsg = @(
            "Spicetify Manager v$($Script:ScriptVersion)"
            ''
            'A fully automatic Spicetify lifecycle manager.'
            'Features:'
            '  - One-click Spicetify installation'
            '  - Marketplace integration'
            '  - Automatic backup/restore with history'
            '  - Repair and uninstall tools'
            ''
            'Statistics (persisted):'
            "  Total Runs: $Script:TotalRuns"
            "  Successful: $Script:SuccessCount"
            "  Failed:     $Script:FailureCount"
            "  Success Rate: $successRate%"
            ''
            "Settings: $Script:ConfigPath"
            "Backups:  $($Script:Config.BackupHistoryDir)"
            ''
            'GitHub: https://github.com/dalbouh02/SpicetifyManager'
            ''
            'Powered by PowerShell + WPF'
        ) -join "`n"

        $null = [System.Windows.MessageBox]::Show($w, $aboutMsg, 'About Spicetify Manager',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information)
    })

    $w.Ctrl.BtnStart.Add_Click({
        Start-Operation -Mode 'Full' -ConfirmTitle 'Confirm Installation' -ConfirmBody (@(
            'This will perform the following actions:'
            '  - Download/install Spicetify CLI'
            '  - Download/install Spicetify Marketplace'
            '  - Modify your Spotify installation'
            '  - Back up any existing customizations'
            ''
            'This process may take several minutes.'
            ''
            'Continue?'
        ) -join "`n")
    })

    $w.Ctrl.BtnRepair.Add_Click({
        Start-Operation -Mode 'Repair' -ConfirmTitle 'Confirm Repair' -ConfirmBody (@(
            'Repair mode will:'
            '  1. Stop Spotify'
            '  2. Back up your customizations'
            '  3. Reinstall Spotify'
            '  4. Recreate the Spicetify backup'
            '  5. Reapply the Spicetify configuration'
            ''
            'Continue?'
        ) -join "`n")
    })

    $w.Ctrl.BtnUninstall.Add_Click({
        Start-Operation -Mode 'Uninstall' -ConfirmTitle 'Confirm Uninstall' -ConfirmBody (@(
            'Uninstall will:'
            '  1. Stop Spotify'
            '  2. Save a final snapshot of your customizations'
            "     to $($Script:Config.BackupHistoryDir)"
            '  3. Restore Spotify to its pre-Spicetify state'
            '  4. Remove Spicetify CLI, Marketplace, and custom apps'
            '  5. Remove Spicetify from your PATH'
            ''
            'Spotify will remain installed. Continue?'
        ) -join "`n")
    })

    $w.Ctrl.BtnCancel.Add_Click({
        if ($w.Ctrl.BtnCancel.IsEnabled -eq $false) { return }

        $cancelMsg = @(
            'Are you sure you want to cancel?'
            ''
            'Cancelling may leave Spicetify in an incomplete state.'
            'You may need to run Repair afterwards.'
        ) -join "`n"
        if ([System.Windows.MessageBox]::Show($w, $cancelMsg, 'Confirm Cancellation',
                [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning) -ne 'Yes') {
            return
        }

        try {
            $Script:CancellationToken.Cancel()
            $Script:ProgressStream.Enqueue([PSCustomObject]@{
                Phase = 'Cancelling'
                Detail = 'Requesting cancellation... please wait'
                Percent = -1
                IsIndeterminate = $true
            }) | Out-Null
            $w.Ctrl.BtnCancel.IsEnabled = $false
            $w.Ctrl.BtnCancel.Content = 'Cancelling...'
            Write-Log -Message 'Cancellation requested by user.' -Level WARN
        } catch {
            Write-Log -Message "Cancel failed: $($_.Exception.Message)" -Level WARN
        }
    })

    $w.Ctrl.BtnSettings.Add_Click({
        if ($Script:OperationRunning) {
            $null = [System.Windows.MessageBox]::Show($w,
                'Please wait for the current operation to complete before opening Settings.',
                'Operation in Progress',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information)
            return
        }

        $sw = New-SettingsWindow -Owner $w
        $sw.Ctrl.TxtMaxRetries.Text       = "$($Script:Config.MaxRetries)"
        $sw.Ctrl.TxtRetryDelayMs.Text     = "$($Script:Config.RetryDelayMs)"
        $sw.Ctrl.TxtProcessTimeoutMs.Text = "$($Script:Config.ProcessTimeoutMs)"
        $sw.Ctrl.TxtBackupRetention.Text  = "$($Script:Config.BackupRetention)"
        $sw.Ctrl.TxtLogPath.Text          = if ($Script:LogPathCustomized) { $Script:Config.LogFilePath } else { '' }
        $sw.Ctrl.TxtCacheDir.Text         = if ($Script:Config.EnableCache) { $Script:Config.CacheDir } else { 'none' }
        $sw.Ctrl.ChkKeepLog.IsChecked     = [bool]$Script:KeepLog
        $sw.Ctrl.ChkSkipPreflight.IsChecked = [bool]$Script:SkipPreflight

        $sw.Ctrl.BtnCancelSettings.Add_Click({ $sw.Close() })
        $sw.Ctrl.BtnSettingsClose.Add_Click({ $sw.Close() })

        # Defaults = TRUE factory defaults (not a snapshot of current values)
        $sw.Ctrl.BtnResetDefaults.Add_Click({
            $sw.Ctrl.TxtMaxRetries.Text       = '3'
            $sw.Ctrl.TxtRetryDelayMs.Text     = '2000'
            $sw.Ctrl.TxtProcessTimeoutMs.Text = '90000'
            $sw.Ctrl.TxtBackupRetention.Text  = '3'
            $sw.Ctrl.TxtLogPath.Text          = ''
            $sw.Ctrl.TxtCacheDir.Text         = ''
            $sw.Ctrl.ChkKeepLog.IsChecked     = $false
            $sw.Ctrl.ChkSkipPreflight.IsChecked = $false
        })

        $sw.Ctrl.BtnSaveSettings.Add_Click({
            $limits = $Script:SettingsLimits
            $errorsFound = @()

            $maxRetries = 0
            if (-not [int]::TryParse($sw.Ctrl.TxtMaxRetries.Text, [ref]$maxRetries)) {
                $errorsFound += 'Max Retries must be a valid number'
            } elseif ($maxRetries -lt $limits.MaxRetriesMin -or $maxRetries -gt $limits.MaxRetriesMax) {
                $errorsFound += "Max Retries must be between $($limits.MaxRetriesMin) and $($limits.MaxRetriesMax)"
            }

            $retryDelay = 0
            if (-not [int]::TryParse($sw.Ctrl.TxtRetryDelayMs.Text, [ref]$retryDelay)) {
                $errorsFound += 'Retry Delay must be a valid number (milliseconds)'
            } elseif ($retryDelay -lt $limits.RetryDelayMin -or $retryDelay -gt $limits.RetryDelayMax) {
                $errorsFound += "Retry Delay must be between $($limits.RetryDelayMin) and $($limits.RetryDelayMax) ms"
            }

            $procTimeout = 0
            if (-not [int]::TryParse($sw.Ctrl.TxtProcessTimeoutMs.Text, [ref]$procTimeout)) {
                $errorsFound += 'Process Timeout must be a valid number (milliseconds)'
            } elseif ($procTimeout -lt $limits.ProcTimeoutMin -or $procTimeout -gt $limits.ProcTimeoutMax) {
                $errorsFound += "Process Timeout must be between $($limits.ProcTimeoutMin) and $($limits.ProcTimeoutMax) ms"
            }

            $retention = 0
            if (-not [int]::TryParse($sw.Ctrl.TxtBackupRetention.Text, [ref]$retention)) {
                $errorsFound += 'Backup Retention must be a valid number'
            } elseif ($retention -lt $limits.RetentionMin -or $retention -gt $limits.RetentionMax) {
                $errorsFound += "Backup Retention must be between $($limits.RetentionMin) and $($limits.RetentionMax)"
            }

            $logPathInput = $sw.Ctrl.TxtLogPath.Text.Trim()
            if ($logPathInput -ne '' -and $logPathInput -notmatch '^[a-zA-Z]:\\') {
                $errorsFound += 'Log file path must be an absolute path (e.g. C:\logs\spm.log)'
            }

            $cacheInput = $sw.Ctrl.TxtCacheDir.Text.Trim()
            if ($cacheInput -ne '' -and $cacheInput -ine 'none' -and $cacheInput -notmatch '^[a-zA-Z]:\\') {
                $errorsFound += "Cache directory must be an absolute path, or 'none' to disable"
            }

            if ($errorsFound.Count -gt 0) {
                $null = [System.Windows.MessageBox]::Show($sw, ($errorsFound -join "`n"), 'Validation Errors',
                    [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
                return
            }

            try {
                $Script:Config.MaxRetries       = $maxRetries
                $Script:Config.RetryDelayMs     = $retryDelay
                $Script:Config.ProcessTimeoutMs = $procTimeout
                $Script:Config.BackupRetention  = $retention

                if ($logPathInput -eq '') {
                    # Empty restores the default (date-stamped) location
                    $Script:Config.LogFilePath = Join-Path $env:TEMP "SpicetifyManager_$(Get-Date -Format 'yyyyMMdd').log"
                    $Script:LogPathCustomized = $false
                } else {
                    $Script:Config.LogFilePath = $logPathInput
                    $Script:LogPathCustomized = $true
                }

                if ($cacheInput -ieq 'none') {
                    $Script:Config.EnableCache = $false
                } else {
                    $Script:Config.EnableCache = $true
                    if ($cacheInput -ne '') {
                        $Script:Config.CacheDir = $cacheInput
                    } else {
                        $Script:Config.CacheDir = Join-Path $env:LOCALAPPDATA 'spicetify\cache'
                    }
                }

                $Script:KeepLog      = [bool]$sw.Ctrl.ChkKeepLog.IsChecked
                $Script:SkipPreflight = [bool]$sw.Ctrl.ChkSkipPreflight.IsChecked

                Save-Config

                $null = [System.Windows.MessageBox]::Show($sw,
                    'Settings saved. They apply to the next operation.',
                    'Settings', 'OK', 'Information')
                $sw.Close()
            } catch {
                $settingsError = Get-FriendlyErrorMessage -RawError $_.Exception.Message
                $null = [System.Windows.MessageBox]::Show($sw, "Invalid input: $settingsError", 'Settings', 'OK', 'Error')
            }
        })

        $null = $sw.ShowDialog()
    })

    $w.Ctrl.BtnOpenSpicetify.Add_Click({
        $p = $Script:Config.AppDataPath
        if (Test-Path -LiteralPath $p) {
            Start-Process explorer.exe -ArgumentList $p
        } else {
            $null = [System.Windows.MessageBox]::Show($w, 'Folder does not exist yet: ' + $p,
                'Open Folder', 'OK', 'Information')
        }
    })

    $w.Ctrl.BtnRestartSpotify.Add_Click({
        $restartMsg = @(
            'This will close and restart Spotify.'
            ''
            'Any unsaved playback state may be lost.'
            ''
            'Continue?'
        ) -join "`n"
        if ([System.Windows.MessageBox]::Show($w, $restartMsg, 'Confirm Restart',
                [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning) -ne 'Yes') {
            return
        }
        try {
            Stop-SpotifyProcess -Force
            Start-Sleep -Seconds 1
            if (Test-Path -LiteralPath $Script:Config.SpotifyExePath) {
                Start-Process -FilePath $Script:Config.SpotifyExePath
                $null = [System.Windows.MessageBox]::Show($w, 'Spotify restarted.', 'Restart', 'OK', 'Information')
            } else {
                $null = [System.Windows.MessageBox]::Show($w, 'Spotify not found at expected location.',
                    'Restart', 'OK', 'Warning')
            }
        } catch {
            $errorMsg = Get-FriendlyErrorMessage -RawError $_.Exception.Message
            $null = [System.Windows.MessageBox]::Show($w, "Failed: $errorMsg", 'Restart', 'OK', 'Error')
        }
    })

    $w.Ctrl.BtnCopyLog.Add_Click({
        try {
            $sb = [System.Text.StringBuilder]::new()
            foreach ($item in $Script:LogEntries) {
                if (Test-LogEntryVisible -Entry $item) {
                    $null = $sb.AppendLine($item.Line)
                }
            }
            [System.Windows.Clipboard]::SetText($sb.ToString())
            $null = [System.Windows.MessageBox]::Show($w, 'Visible log entries copied to clipboard.',
                'Copy', 'OK', 'Information')
        } catch {
            $null = [System.Windows.MessageBox]::Show($w, 'Copy failed: ' + $_.Exception.Message,
                'Copy', 'OK', 'Error')
        }
    })

    $w.Ctrl.BtnOpenLog.Add_Click({
        if (Test-Path -LiteralPath $Script:Config.LogFilePath) {
            Start-Process notepad.exe -ArgumentList $Script:Config.LogFilePath
        } else {
            $null = [System.Windows.MessageBox]::Show($w, 'No log file exists yet.', 'Open Log', 'OK', 'Information')
        }
    })

    $w.Ctrl.BtnExportLog.Add_Click({
        try {
            $saveDialog = New-Object Microsoft.Win32.SaveFileDialog
            $saveDialog.Filter = 'Text Files|*.txt|Log Files|*.log|All Files|*.*'
            $saveDialog.DefaultExt = '.txt'
            $saveDialog.FileName = 'SpicetifyManager_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt'

            if ($saveDialog.ShowDialog() -eq $true) {
                # Export EXACTLY the entries visible under the current filter
                $lines = @()
                foreach ($item in $Script:LogEntries) {
                    if (Test-LogEntryVisible -Entry $item) {
                        $lines += $item.Line
                    }
                }
                $lines | Out-File -FilePath $saveDialog.FileName -Encoding UTF8

                $null = [System.Windows.MessageBox]::Show($w,
                    "Exported $($lines.Count) log entries to:`n$($saveDialog.FileName)",
                    'Export Complete',
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Information)
            }
        } catch {
            $null = [System.Windows.MessageBox]::Show($w,
                'Failed to export log: ' + $_.Exception.Message,
                'Export Error',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error)
        }
    })

    $w.Ctrl.TxtLogSearch.Add_TextChanged({
        $Script:LogSearchTerm = $w.Ctrl.TxtLogSearch.Text.Trim()
        if ($null -ne $Script:LogView) { $Script:LogView.Refresh() }
    })

    $w.Ctrl.CmbLogLevelFilter.Add_SelectionChanged({
        $selectedItem = $w.Ctrl.CmbLogLevelFilter.SelectedItem
        if ($selectedItem) {
            $tagValue = $selectedItem.Tag
            $Script:LogLevelFilter = if ($null -ne $tagValue) { $tagValue.ToString() } else { '' }
            if ($null -ne $Script:LogView) { $Script:LogView.Refresh() }
        }
    })

    $w.Add_PreviewKeyDown({
        if ($_.Key -eq 'Escape' -and -not $Script:OperationRunning) {
            $w.Close()
        }
    })

    $w.Add_Closing({
        if ($Script:OperationRunning) {
            $_.Cancel = $true
            $null = [System.Windows.MessageBox]::Show($w,
                'Cannot close while an operation is running. Cancel it first.',
                'Busy', 'OK', 'Warning')
            return
        }
        # Authoritative final save (throttled saves may have dropped the last move)
        Save-WindowState -Window $w
        try { $Script:CancellationToken.Dispose() } catch {}
    })

    $w.Add_Closed({
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([Action]{
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
        }) | Out-Null
    })

    Restore-WindowState -Window $w

    $null = $w.Show()

    $w.Add_LocationChanged({ Save-WindowState -Window $w })
    $w.Add_SizeChanged({ Save-WindowState -Window $w })

    [System.Windows.Threading.Dispatcher]::Run()
}

function Invoke-Diagnostics {
    [CmdletBinding()]
    param()

    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host ' Spicetify Manager -- Diagnostic Mode' -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host ''

    Write-Host '--- Environment ---' -ForegroundColor Yellow
    Write-Host ('  PowerShell Version:  ' + $PSVersionTable.PSVersion.ToString())
    Write-Host ('  PS Edition:          ' + $PSVersionTable.PSEdition)
    Write-Host ('  OS:                  ' + $env:OS)
    Write-Host ('  Architecture:        ' + $env:PROCESSOR_ARCHITECTURE)
    $clrVer = if ($PSVersionTable.PSObject.Properties.Name -contains 'CLRVersion') { $PSVersionTable.CLRVersion.ToString() } else { '(not available on PS Core)' }
    Write-Host ('  .NET Version:        ' + $clrVer)
    Write-Host ('  Host Name:           ' + $Host.Name)
    Write-Host ('  User Interactive:    ' + [Environment]::UserInteractive)
    $isAdmin = 'unknown'
    try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
    Write-Host ('  Is Admin:            ' + $isAdmin)
    Write-Host ''

    Write-Host '--- TLS ---' -ForegroundColor Yellow
    try {
        Write-Host ('  SecurityProtocol:    ' + [Net.ServicePointManager]::SecurityProtocol)
    } catch {
        Write-Host ('  SecurityProtocol:    ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    }
    try {
        $null = [Net.SecurityProtocolType]::Tls13
        Write-Host '  Tls13 available:     Yes'
    } catch {
        Write-Host '  Tls13 available:     No (using Tls12 only)' -ForegroundColor DarkYellow
    }
    Write-Host ''

    Write-Host '--- Paths ---' -ForegroundColor Yellow
    Write-Host ('  APPDATA:             ' + $env:APPDATA)
    Write-Host ('  LOCALAPPDATA:        ' + $env:LOCALAPPDATA)
    Write-Host ('  TEMP:                ' + $env:TEMP)
    Write-Host ('  Settings file:       ' + $Script:ConfigPath)
    Write-Host ('  Stats file:          ' + $Script:StatsPath)
    Write-Host ('  Log file:            ' + $Script:Config.LogFilePath)
    Write-Host ('  Cache dir:           ' + $Script:Config.CacheDir + ' (enabled: ' + $Script:Config.EnableCache + ')')
    Write-Host ('  Backup history:      ' + $Script:Config.BackupHistoryDir)
    Write-Host ('  Spicetify exe:       ' + $Script:Config.SpicetifyExePath)
    Write-Host ('  Spotify exe:         ' + $Script:Config.SpotifyExePath)
    Write-Host ('  Spotify install dir: ' + $Script:Config.SpotifyInstallDir)
    Write-Host ('  Marketplace dest:    ' + $Script:Config.MarketplaceDest)
    Write-Host ''

    Write-Host '--- Disk Space ---' -ForegroundColor Yellow
    $tempFree = Get-FreeDiskSpaceMB -Path $env:TEMP
    $appFree  = Get-FreeDiskSpaceMB -Path $env:APPDATA
    Write-Host ('  TEMP drive free:     ' + $tempFree + ' MB')
    Write-Host ('  APPDATA drive free:  ' + $appFree + ' MB')
    Write-Host ('  Minimum required:    ' + $Script:Config.MinDiskSpaceMB + ' MB')
    Write-Host ''

    Write-Host '--- Network ---' -ForegroundColor Yellow
    foreach ($ep in @(
        @{ Name = 'GitHub API';      Url = 'https://api.github.com' }
        @{ Name = 'GitHub download'; Url = 'https://github.com' }
        @{ Name = 'Spotify CDN';     Url = 'https://download.scdn.co' }
    )) {
        try {
            $resp = Invoke-WebRequest -Uri $ep.Url -Method Head -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            Write-Host ('  ' + $ep.Name.PadRight(20) + ' OK (HTTP ' + $resp.StatusCode + ')') -ForegroundColor Green
        } catch {
            $code = 0
            if ($null -ne $_.Exception.Response) {
                try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            }
            if ($code -gt 0) {
                Write-Host ('  ' + $ep.Name.PadRight(20) + ' Reachable (HTTP ' + $code + ')') -ForegroundColor DarkYellow
            } else {
                Write-Host ('  ' + $ep.Name.PadRight(20) + ' UNREACHABLE: ' + $_.Exception.Message) -ForegroundColor Red
            }
        }
    }
    Write-Host ''

    Write-Host '--- Spotify ---' -ForegroundColor Yellow
    $desktopSpotify = Test-Path -LiteralPath $Script:Config.SpotifyExePath
    $storeSpotify   = Test-MicrosoftStoreSpotify
    Write-Host ('  Desktop Spotify installed: ' + $desktopSpotify)
    Write-Host ('  Store Spotify installed:   ' + $storeSpotify)
    if ($desktopSpotify) {
        try {
            $ver = (Get-Item $Script:Config.SpotifyExePath).VersionInfo
            Write-Host ('  Spotify version:           ' + $ver.ProductVersion)
        } catch {}
    }
    Write-Host ''

    Write-Host '--- Spicetify ---' -ForegroundColor Yellow
    $spicetifyInstalled = Test-Path -LiteralPath $Script:Config.SpicetifyExePath
    Write-Host ('  Spicetify installed:  ' + $spicetifyInstalled)
    if ($spicetifyInstalled) {
        try {
            $r = Invoke-ExternalCommand -FilePath $Script:Config.SpicetifyExePath -Arguments '--version' -TimeoutMs 10000
            Write-Host ('  Spicetify version:    ' + $r.Stdout.Trim())
        } catch {
            Write-Host ('  Spicetify version:    ERROR: ' + $_.Exception.Message) -ForegroundColor Red
        }
        $historyCount = 0
        if (Test-Path -LiteralPath $Script:Config.BackupHistoryDir) {
            $historyCount = @(Get-ChildItem -Path $Script:Config.BackupHistoryDir -Directory -Filter 'backup_*').Count
        }
        Write-Host ('  Backup snapshots:     ' + $historyCount + ' (retention: ' + $Script:Config.BackupRetention + ')')
    }
    Write-Host ''

    Write-Host '--- Assemblies ---' -ForegroundColor Yellow
    if ($Script:FailedAssemblies.Count -gt 0) {
        foreach ($asm in $Script:FailedAssemblies) {
            Write-Host ('  ' + $asm.PadRight(40) + ' FAILED TO LOAD (GUI may not start)') -ForegroundColor Red
        }
    } else {
        Write-Host '  All required assemblies loaded OK' -ForegroundColor Green
    }
    Write-Host ''

    Write-Host '--- Config ---' -ForegroundColor Yellow
    Write-Host ('  MaxRetries:        ' + $Script:Config.MaxRetries)
    Write-Host ('  RetryDelayMs:      ' + $Script:Config.RetryDelayMs)
    Write-Host ('  ProcessTimeoutMs:  ' + $Script:Config.ProcessTimeoutMs)
    Write-Host ('  BackupRetention:   ' + $Script:Config.BackupRetention)
    Write-Host ('  EnableCache:       ' + $Script:Config.EnableCache)
    Write-Host ('  MinDiskSpaceMB:    ' + $Script:Config.MinDiskSpaceMB)
    Write-Host ''

    Write-Host '--- Statistics ---' -ForegroundColor Yellow
    Write-Host ('  Total runs:        ' + $Script:TotalRuns)
    Write-Host ('  Successful:        ' + $Script:SuccessCount)
    Write-Host ('  Failed:            ' + $Script:FailureCount)
    Write-Host ''

    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host ' Diagnostic complete. No changes were made to your system.' -ForegroundColor Green
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host ''
}

function Hide-ConsoleWindow {
    try {
        if (-not ('SpmWin32.Native' -as [type])) {
            Add-Type -Namespace SpmWin32 -Name Native -MemberDefinition @"
            [System.Runtime.InteropServices.DllImport("kernel32.dll")]
            public static extern System.IntPtr GetConsoleWindow();
            [System.Runtime.InteropServices.DllImport("user32.dll")]
            public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
"@ -ErrorAction Stop
        }
        $hwnd = [SpmWin32.Native]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) {
            # SW_HIDE = 0
            [void][SpmWin32.Native]::ShowWindow($hwnd, 0)
        }
    } catch {
        # Non-fatal: keep the console visible on any failure
    }
}

function Show-ConsoleWindow {
    try {
        if (-not ('SpmWin32.Native' -as [type])) { return }
        $hwnd = [SpmWin32.Native]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) {
            # SW_SHOW = 5
            [void][SpmWin32.Native]::ShowWindow($hwnd, 5)
        }
    } catch { }
}

function Write-FatalError {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    Show-ConsoleWindow

    $crashTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $crashReport = New-Object System.Text.StringBuilder
    $null = $crashReport.AppendLine('=' * 70)
    $null = $crashReport.AppendLine('SPICETIFY MANAGER -- CRASH REPORT')
    $null = $crashReport.AppendLine('Time:        ' + $crashTime)
    $null = $crashReport.AppendLine('Phase:       ' + $Script:CurrentPhase)
    $null = $crashReport.AppendLine('PS Version:  ' + $PSVersionTable.PSVersion.ToString())
    $null = $crashReport.AppendLine('OS:          ' + $env:OS)
    $null = $crashReport.AppendLine('Arch:        ' + $env:PROCESSOR_ARCHITECTURE)
    $null = $crashReport.AppendLine('.' * 70)
    $null = $crashReport.AppendLine('Error Type:  ' + $ErrorRecord.Exception.GetType().FullName)
    $null = $crashReport.AppendLine('Message:     ' + $ErrorRecord.Exception.Message)
    $null = $crashReport.AppendLine('.' * 70)
    $null = $crashReport.AppendLine('Script Stack Trace:')
    $null = $crashReport.AppendLine($ErrorRecord.ScriptStackTrace)
    $null = $crashReport.AppendLine('.' * 70)
    $null = $crashReport.AppendLine('.NET Stack Trace:')
    $null = $crashReport.AppendLine($ErrorRecord.Exception.StackTrace)
    $null = $crashReport.AppendLine('.' * 70)
    $inner = $ErrorRecord.Exception.InnerException
    $depth = 1
    while ($null -ne $inner -and $depth -lt 10) {
        $null = $crashReport.AppendLine("Inner Exception ${depth}:")
        $null = $crashReport.AppendLine('  Type:    ' + $inner.GetType().FullName)
        $null = $crashReport.AppendLine('  Message: ' + $inner.Message)
        $null = $crashReport.AppendLine('')
        $inner = $inner.InnerException
        $depth++
    }
    $null = $crashReport.AppendLine('=' * 70)

    $reportText = $crashReport.ToString()

    # 1. Print to console (Write-Host directly -- never fails)
    try {
        Write-Host '' -ForegroundColor Red
        Write-Host ('=' * 70) -ForegroundColor Red
        Write-Host ' FATAL ERROR' -ForegroundColor Red
        Write-Host ('=' * 70) -ForegroundColor Red
        Write-Host (' Phase:   ' + $Script:CurrentPhase) -ForegroundColor Yellow
        Write-Host (' Error:   ' + $ErrorRecord.Exception.Message) -ForegroundColor Yellow
        Write-Host (' Type:    ' + $ErrorRecord.Exception.GetType().Name) -ForegroundColor DarkYellow
        $innerEx = $ErrorRecord.Exception.InnerException
        $depth = 1
        while ($null -ne $innerEx -and $depth -le 5) {
            Write-Host (" Inner[$depth]: " + $innerEx.Message) -ForegroundColor DarkYellow
            $innerEx = $innerEx.InnerException
            $depth++
        }
        Write-Host '' -ForegroundColor Red
        Write-Host ' Stack Trace:' -ForegroundColor DarkRed
        Write-Host $ErrorRecord.ScriptStackTrace -ForegroundColor DarkGray
        Write-Host ('=' * 70) -ForegroundColor Red
    } catch { }

    # 2. Write crash log file that is NEVER deleted
    $crashLogPath = Join-Path $env:TEMP ('SpicetifyManager_CRASH_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
    try {
        [System.IO.File]::WriteAllText($crashLogPath, $reportText, [System.Text.UTF8Encoding]::new($true))
        Write-Host '' -ForegroundColor Cyan
        Write-Host (' Crash log saved: ' + $crashLogPath) -ForegroundColor Cyan
        Write-Host (' Regular log:     ' + $Script:Config.LogFilePath) -ForegroundColor Cyan
        Write-Host '' -ForegroundColor Cyan
    } catch {
        Write-Host ' Failed to write crash log file.' -ForegroundColor Red
    }

    # 3. Try to append to regular log too
    try {
        Add-Content -Path $Script:Config.LogFilePath -Value $reportText -ErrorAction SilentlyContinue
    } catch { }

    try {
        Write-Host ''
        Write-Host ('=' * 70) -ForegroundColor Yellow
        Write-Host ' Window will stay open for 10 seconds so you can copy the log.' -ForegroundColor Yellow
        Write-Host ' Press Ctrl+C to abort now, or wait for the countdown.' -ForegroundColor Gray
        Write-Host ('=' * 70) -ForegroundColor Yellow
        Write-Host ''
        $countdown = 10
        while ($countdown -gt 0) {
            Write-Host -NoNewline ("`r  Closing in {0,2} seconds...  " -f $countdown)
            Start-Sleep -Milliseconds 1000
            $countdown--
        }
        Write-Host ''
    } catch { }
}

function Invoke-FinalCleanup {
    param([int]$ExitCode)

    try { Close-Progress } catch {}

    if ($ExitCode -ne 0) {
        try { Stop-SpotifyProcess -Force } catch {}
    }

    if ($Script:StagingPath -and (Test-Path -LiteralPath $Script:StagingPath)) {
        Remove-Item -Path $Script:StagingPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    foreach ($path in @($Script:TempFiles)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
        }
    }
    $Script:TempFiles.Clear()

    if ($null -ne $Script:CancellationToken) {
        try { $Script:CancellationToken.Dispose() } catch {}
    }

    # Only delete the log on SUCCESS -- keep it on failure for debugging
    if ($ExitCode -eq 0 -and -not $Script:KeepLog -and (Test-Path -LiteralPath $Script:Config.LogFilePath)) {
        Remove-Item -Path $Script:Config.LogFilePath -Force -ErrorAction SilentlyContinue
    }
}

# Determine interactive launch (for "Press any key" prompt at the very end)
$Script:InteractiveLaunch = ($Host.Name -eq 'ConsoleHost') -and `
    [Environment]::UserInteractive -and `
    -not $FromLauncher -and `
    -not $NoUI

# Mode flags (GUI buttons override these at runtime)
$Script:UninstallMode = [bool]$Uninstall
$Script:RepairMode    = [bool]$Repair
$Script:KeepLog       = [bool]$KeepLog
$Script:SkipPreflight = [bool]$SkipPreflight
$Script:CurrentOpLabel = 'Install'

$Script:ExitReason = $null
$Script:ExitCode   = 0

# Report any assembly load failures through the logger now that it exists
foreach ($failedAsm in $Script:FailedAssemblies) {
    Write-Log -Message "Assembly failed to load: $failedAsm (GUI may not start)" -Level WARN
}

# Load persisted settings + stats for BOTH modes. CLI parameters always win.
$boundParamSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
foreach ($k in $PSBoundParameters.Keys) { $null = $boundParamSet.Add($k) }
Load-Config -BoundParams $boundParamSet
Load-Stats

if ($Diagnose) {
    try {
        Invoke-Diagnostics
        $Script:ExitCode = 0
    } catch {
        Write-Host ''
        Write-Host ('FATAL in diagnostics: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host ('Type: ' + $_.Exception.GetType().FullName) -ForegroundColor DarkYellow
        Write-Host ('Stack: ' + $_.ScriptStackTrace) -ForegroundColor DarkGray
        $Script:ExitCode = 1
    }
    if ($Script:InteractiveLaunch) {
        Write-Host 'Press any key to close...' -ForegroundColor Gray
        try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep -Seconds 2 }
    }
    exit $Script:ExitCode
}

if (-not $NoUI) {
    Hide-ConsoleWindow
    $Script:InteractiveLaunch = $false   # no "press any key" prompt needed
    try {
        Show-Banner
        Initialize-WorkflowSteps -Mode $(if ($Script:UninstallMode) { 'Uninstall' } elseif ($Script:RepairMode) { 'Repair' } else { 'Full' })
        Show-MainWindow
        $Script:ExitReason = 'Success'
        $Script:ExitCode   = 0
    } catch {
        Write-FatalError -ErrorRecord $_
        $phaseCode = $Script:ExitCodes[$Script:CurrentPhase]
        if (-not $phaseCode) { $phaseCode = 1 }
        $Script:ExitReason = "Failed at phase: $Script:CurrentPhase"
        $Script:ExitCode   = $phaseCode
        Show-Summary -SuccessSteps @() -WarningSteps @() -ErrorStep $Script:ExitReason
    } finally {
        Invoke-FinalCleanup -ExitCode $Script:ExitCode
        if ($Script:InteractiveLaunch) {
            Write-Host ''
            Write-Host 'Press any key to close...' -ForegroundColor Gray
            try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep -Seconds 2 }
        }
        exit $Script:ExitCode
    }
} else {
    Show-Banner

    try {
        $workflowResult = Invoke-Workflow
        if ($null -eq $workflowResult) {
            $workflowResult = [PSCustomObject]@{ SuccessSteps = @(); WarningSteps = @() }
        }
        Show-Summary -SuccessSteps $workflowResult.SuccessSteps -WarningSteps $workflowResult.WarningSteps
        $Script:ExitReason = 'Success'
        $Script:ExitCode   = 0
    } catch {
        Write-FatalError -ErrorRecord $_
        $phaseCode = $Script:ExitCodes[$Script:CurrentPhase]
        if (-not $phaseCode) { $phaseCode = 1 }
        $Script:ExitReason = "Failed at phase: $Script:CurrentPhase"
        $Script:ExitCode   = $phaseCode
        Show-Summary -SuccessSteps @() -WarningSteps @() -ErrorStep $Script:ExitReason
    } finally {
        Invoke-FinalCleanup -ExitCode $Script:ExitCode
        if ($Script:InteractiveLaunch) {
            Write-Host ''
            Write-Host 'Press any key to close...' -ForegroundColor Gray
            try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep -Seconds 2 }
        }
        exit $Script:ExitCode
    }
}
