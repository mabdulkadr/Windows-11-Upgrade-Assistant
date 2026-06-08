<#!
.SYNOPSIS
    Launches a guided Windows 11 in-place upgrade from local installation media
    (mounted ISO, USB stick, or extracted folder) using a modern WPF-based UI.

.DESCRIPTION
    Windows 11 Upgrade Assistant is a single-file PowerShell tool that helps
    operators perform an in-place upgrade to Windows 11 while preserving files,
    applications, and settings. It can also bypass Windows 11 hardware checks
    (TPM 2.0, Secure Boot, supported CPU) on older devices by injecting the
    /Product server and /compat IgnoreWarning switches.

    The script collects device/OS information, runs readiness checks (RAM, free
    disk space, AC power), validates the user-selected setup.exe, lets the user
    pick from predefined setup command profiles, and builds the final command
    line for review before execution.

    Main capabilities:
      * WPF graphical interface (single window, 1040x740) with sidebar session
        info, OS details card, readiness pills, and a planned-command preview.
      * Browse for setup.exe on local media, or mount an ISO and auto-fill the
        path. Unmount support is included.
      * Three preset upgrade profiles (Basic, Standard, Silent) with editable
        extra-arguments field.
      * Optional re-launch of Windows Setup with elevation (RunAs) when the
        current session is not elevated.
      * One-click copy of the planned command to the clipboard.
      * Confirmation dialog before executing setup.exe (with Copy as fallback).
      * Session transcript logging to %LOCALAPPDATA%\Win11UpgradeAssistant\Logs.
      * Background device-info collection on a dedicated MTA runspace so the
        UI thread never blocks on WMI/CIM calls.

    Exit codes:
      * 0 : The script completed normally or the UI was closed without error.
      * 1 : The script failed or could not continue (currently unused; failures
            inside the UI are surfaced via the status bar).

.RUN AS
    Standard user is supported for browsing, mounting the ISO, and reviewing
    the plan. Administrator rights are usually required by Windows Setup
    itself when it actually runs; the assistant offers a RunAs prompt in that
    case.

.EXAMPLE
    .\Windows-11-Upgrade-Assistant-v1.1.ps1

    Opens the upgrade assistant UI. The user can select setup.exe or an ISO,
    review the generated command, copy it, and start Windows Setup.

.NOTES
    Author      : Mohammad Abdelkader Omar
    Website     : https://momar.tech
    LinkedIn    : https://www.linkedin.com/in/mabdulkadr/
    Date        : 2026-06-08
    Version     : 1.1
    Changelog   :
                 1.1  - Added: ISO dismount button, Clear path button, session
                          logging (Start-Transcript), launch confirmation
                          dialog, Copy-as-fallback from confirm.
                       - Fixed: Null reference on tRam/tFree controls (removed),
                          redundant Update-DeviceUI in TextChanged handler,
                          Get-DeviceInfo product-name reverse case.
                       - Refactored: De-duplicated Get-DeviceInfo between the
                          foreground function and the background runspace.
                 1.0  - Initial release.
#>
#region ======================== SETTINGS ============================

# ---------------------------------------------------------------------------
# Preset setup.exe command templates (selectable in the UI).
#
# These profiles intentionally include /Product server and /compat IgnoreWarning
# in order to relax the Windows 11 hardware checks (TPM, Secure Boot, CPU).
# Use only on devices approved by your organisational policy. The exact
# reference lines (commented out below) document the full setup.exe surface
# the assistant can emit.
#
#   setup.exe /Product server /compat IgnoreWarning /MigrateDrivers All
#   setup.exe /auto upgrade /Product server /migratedrivers all /dynamicupdate disable /eula accept /compat ignorewarning /copylogs C:\WinSetup.log
#   setup.exe /auto Upgrade /migratedrivers all /ShowOOBE none /Telemetry Disable /dynamicupdate disable /eula accept /quiet /noreboot /compat ignorewarning /copylogs C:\WinSetup.log
# ---------------------------------------------------------------------------
$script:SetupProfiles = @(
    [pscustomobject]@{
        Key     = "OPT1"
        Args    = "/Product server /compat IgnoreWarning /MigrateDrivers All"
        LabelEN = "Option 1 - Basic (Clean Install + driver migration)"
        Desc    = "Basic upgrade; Clean Install and migrates drivers."
    }
    [pscustomobject]@{
        Key     = "OPT2"
        Args    = "/auto upgrade /Product server /compat ignorewarning /migratedrivers all /eula accept /copylogs C:\WinSetup.log"
        LabelEN = "Option 2 - Standard In-Place Upgrade (Keep data/apps + logs)"
        Desc    = "Standard in-place upgrade; keeps data/apps and saves logs."
    }
    [pscustomobject]@{
        Key     = "OPT3"
        Args    = "/auto Upgrade /Product server /compat ignorewarning /migratedrivers all /eula accept /ShowOOBE none /Telemetry Disable /quiet /noreboot /copylogs C:\WinSetup.log"
        LabelEN = "Option 3 - Silent In-Place Upgrade (No reboot + no user prompts)"
        Desc    = "Silent in-place upgrade; no prompts and no automatic reboot."
    }
)
$script:DefaultProfileKey = "OPT2"

# ---------------------------------------------------------------------------
# Readiness thresholds (informational only; they never block the UI).
#   $MinRamGB       : Minimum total RAM in GB.
#   $MinDiskGB      : Minimum free space on C: in GB.
#   $RequireACPower : When $true, attempt to detect battery; desktops are
#                     always reported as "on AC" (best-effort fallback).
#   $UiVersion      : Displayed in the UI footer; keep in sync with header.
# ---------------------------------------------------------------------------
$MinRamGB       = 8
$MinDiskGB      = 30
$RequireACPower = $true
$UiVersion      = "1.1"
#endregion ==============================================================

#region ===================== ENVIRONMENT HELPERS ======================

<#
.SYNOPSIS
    Re-launches the current script in a Single-Threaded Apartment (STA)
    PowerShell host if the current thread is not STA. WPF requires STA; the
    script simply exits in the parent process when a child is spawned so the
    caller sees the child's exit code.
#>
function Ensure-STA {
    $state = $null
    try { $state = [System.Threading.Thread]::CurrentThread.ApartmentState } catch {}
    if ($state -ne "STA") {
        # No path means we are running in an interactive prompt; in that
        # environment WPF will already have a working apartment state.
        $self = $MyInvocation.MyCommand.Path
        if ([string]::IsNullOrWhiteSpace($self) -or !(Test-Path $self)) { return }
        $arg = "-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File `"$self`""
        $p = Start-Process -FilePath "powershell.exe" -ArgumentList $arg -Wait -PassThru
        exit $p.ExitCode
    }
}

<#
.SYNOPSIS
    Starts a transcript of the current session under
    %LOCALAPPDATA%\Win11UpgradeAssistant\Logs\Session_<timestamp>.log.
    Best-effort: any failure is swallowed so logging never blocks the UI.
#>
function Start-SessionLog {
    try {
        $logDir = Join-Path $env:LOCALAPPDATA "Win11UpgradeAssistant\Logs"
        if (-not (Test-Path $logDir)) { [void](New-Item -ItemType Directory -Path $logDir -Force) }
        $logFile = Join-Path $logDir ("Session_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
        Start-Transcript -Path $logFile -Append -ErrorAction SilentlyContinue | Out-Null
        Write-Host "Session log: $logFile"
    } catch {}
}
#endregion ==============================================================

#region ============================ DATA ================================

<#
.SYNOPSIS
    Collects OS, hardware, and disk information for the UI cards.
    Returns a PSCustomObject that is consumed by Update-DeviceUI.

.DESCRIPTION
    All CIM/WMI calls are wrapped in -ErrorAction SilentlyContinue so the
    function never throws - the UI is designed to show a graceful
    "checks failed" state instead. The registry path used here is the
    canonical location for Windows edition metadata; if it is missing
    (very rare), the script falls back to WMI.

    The product-name normalisation handles the common case where the
    registry still says "Windows 10" on a build >= 22000 device that has
    been upgraded to Windows 11, and the inverse case where the registry
    claims "Windows 11" on a Windows 10 build (e.g. due to a
    compatibility shim).
#>
function Get-DeviceInfo {
    # Read the registry once; it is the fastest source for the static fields.
    $cv   = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue
    $os   = Get-CimInstance Win32_OperatingSystem       -ErrorAction SilentlyContinue
    $cs   = Get-CimInstance Win32_ComputerSystem        -ErrorAction SilentlyContinue
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue

    # Pick the most specific "version" label available.
    $version = $cv.DisplayVersion
    if ([string]::IsNullOrWhiteSpace($version)) { $version = $cv.ReleaseId }
    if ([string]::IsNullOrWhiteSpace($version) -and $os) { $version = $os.Version }

    # Build.UBR is the patch level (e.g. 22621.4391). We compose both.
    $build = $cv.CurrentBuild
    $ubr   = $cv.UBR
    if (-not $build -and $os) { $build = $os.BuildNumber }
    $buildText = if ($build -and $ubr) { "$build.$ubr" } elseif ($build) { "$build" } else { $null }
    $buildNum  = $null
    try { if ($build) { $buildNum = [int]$build } } catch {}

    # InstallDate is a Windows FILETIME expressed as seconds since 1970.
    $installDate = $null
    try { if ($cv.InstallDate) { $installDate = (Get-Date "1970-01-01").AddSeconds([int64]$cv.InstallDate).ToString("yyyy-MM-dd") } } catch {}

    $modelText = ""
    if ($cs) { $modelText = ("{0} / {1}" -f $cs.Manufacturer, $cs.Model).Trim() }

    # Normalise product name on devices that have crossed the 22000 boundary
    # in either direction. See function header for details.
    $productName = if ($cv.ProductName) { $cv.ProductName } elseif ($os) { $os.Caption } else { $null }
    if ($productName -and $buildNum -ge 22000 -and $productName -match "Windows 10") {
        $productName = $productName -replace "Windows 10", "Windows 11"
    }
    if ($productName -and $buildNum -lt  22000 -and $productName -match "Windows 11") {
        $productName = $productName -replace "Windows 11", "Windows 10"
    }

    [pscustomobject]@{
        ProductName = $productName
        Version     = $version
        Build       = $buildText
        InstallDate = $installDate
        Model       = $modelText
        RamGB       = if ($cs.TotalPhysicalMemory) { [math]::Round($cs.TotalPhysicalMemory/1GB,2) } else { $null }
        FreeC       = if ($disk.FreeSpace)          { [math]::Round($disk.FreeSpace/1GB,2) }          else { $null }
    }
}

<#
.SYNOPSIS
    Reports whether the system is currently on AC power.

.DESCRIPTION
    Best-effort implementation:
      * If a battery is reported, the WMI BatteryStatus codes 2,6,7,8,9 are
        the documented "charging / on AC" states.
      * On desktops or any system that simply has no battery entry, we
        optimistically return $true so the check never blocks the user
        (desktops cannot run out of battery mid-upgrade).
#>
function Get-AcPowerStatus {
    try {
        $b = Get-CimInstance Win32_Battery -ErrorAction Stop
        if (-not $b) { return $true }
        return ($b.BatteryStatus -in 2,6,7,8,9)
    } catch { return $true }
}

<#
.SYNOPSIS
    Validates a user-supplied path to a setup.exe file.
.PARAMETER Path
    The full path to verify. The function checks: not empty, file exists,
    and filename is exactly "setup.exe" (case-insensitive).
#>
function Test-SetupExePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (!(Test-Path $Path))                  { return $false }
    return ([IO.Path]::GetFileName($Path).ToLower() -eq "setup.exe")
}
#endregion ==============================================================
#endregion ==============================================================

#region ============================= UI ================================

# WPF requires an STA thread, and we also want a session transcript for
# post-mortem analysis. Both helpers are no-ops when their preconditions
# are already satisfied.
Ensure-STA
Start-SessionLog

# Load WPF (presentation) and WinForms (for OpenFileDialog). Out-Null
# suppresses the noisy "GAC" version lines that Add-Type prints by default.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase | Out-Null
Add-Type -AssemblyName System.Windows.Forms | Out-Null

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Windows 11 Upgrade"
        Width="1200" Height="770"
        WindowStartupLocation="CenterScreen"
        Background="#F4F7FB"
        FontFamily="Segoe UI"
        FontSize="13"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True">
  <Window.Resources>
    <DropShadowEffect x:Key="ShadowPrimary" BlurRadius="10" ShadowDepth="0" Opacity="0.55" Color="#9FAEF7"/>
    <DropShadowEffect x:Key="ShadowBlue" BlurRadius="10" ShadowDepth="0" Opacity="0.55" Color="#8FB4FF"/>
    <DropShadowEffect x:Key="ShadowGreen" BlurRadius="10" ShadowDepth="0" Opacity="0.55" Color="#9FD7B8"/>
    <Style x:Key="BtnBase" TargetType="Button">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="12,6"/>
      <Style.Triggers>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Effect" Value="{x:Null}"/>
          <Setter Property="Background" Value="#ECEFF3"/>
          <Setter Property="Foreground" Value="#9CA3AF"/>
          <Setter Property="BorderBrush" Value="#ECEFF3"/>
          <Setter Property="Opacity" Value="0.75"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="Button" BasedOn="{StaticResource BtnBase}"/>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#9FAEF7"/>
      <Setter Property="Foreground" Value="#1F2D3A"/>
      <Setter Property="Effect" Value="{StaticResource ShadowPrimary}"/>
    </Style>
    <Style x:Key="BtnBlue" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#8FB4FF"/>
      <Setter Property="Foreground" Value="#1F2D3A"/>
      <Setter Property="Effect" Value="{StaticResource ShadowBlue}"/>
    </Style>
    <Style x:Key="BtnGreen" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#9FD7B8"/>
      <Setter Property="Foreground" Value="#1F2D3A"/>
      <Setter Property="Effect" Value="{StaticResource ShadowGreen}"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#DEE6F1"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="14"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#0F172A"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
    <Style x:Key="ValuePill" TargetType="Border">
      <Setter Property="Background" Value="#EEF2FF"/>
      <Setter Property="CornerRadius" Value="0"/>
      <Setter Property="Padding" Value="8,4"/>
    </Style>
    <SolidColorBrush x:Key="SidebarCardBackground" Color="#F9FBFF"/>
    <SolidColorBrush x:Key="SidebarCardBorder" Color="#E4E9F0"/>
    <Style x:Key="SidebarCard" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource SidebarCardBackground}"/>
      <Setter Property="BorderBrush" Value="{StaticResource SidebarCardBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="Padding" Value="12"/>
      <Setter Property="Margin" Value="12,10,12,0"/>
    </Style>
    <Style x:Key="SidebarTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#0F172A"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style x:Key="SidebarText" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#4B5563"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
  </Window.Resources>
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="260"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>
    <Border Grid.Column="0" Background="#FFFFFF" BorderBrush="#E4E9F0" BorderThickness="0,0,1,0">
      <DockPanel LastChildFill="True">
        <StackPanel DockPanel.Dock="Top" Margin="18,18,18,12">
          <StackPanel Orientation="Horizontal">
            <Border Width="34" Height="34" Background="#8FB4FF" CornerRadius="5">
              <TextBlock Text="W" Foreground="#1F2D3A" FontSize="18" FontWeight="Bold" VerticalAlignment="Center" HorizontalAlignment="Center"/>
            </Border>
            <StackPanel Margin="10,0,0,0">
              <TextBlock Name="sbAppTitle" Text="Windows 11 Upgrade" FontSize="16" FontWeight="SemiBold" Foreground="#1F2D3A"/>
              <TextBlock Name="sbAppSub" Text="Upgrade Assistant" FontSize="11" Foreground="#5F6B7A"/>
            </StackPanel>
          </StackPanel>
        </StackPanel>
        <StackPanel DockPanel.Dock="Top" Margin="8,8">
          <TextBlock Name="sbToolsTitle" Text="TOOLS" Margin="14,10,0,6" FontSize="11" FontWeight="SemiBold" Foreground="#7C8BA1"/>
          <Button Name="sbUpgradeBtn" Content="Upgrade" FontWeight="SemiBold" Height="38" Margin="6" Padding="12,0"
                  HorizontalContentAlignment="Left" Background="#d5ddeb" Foreground="#1F2D3A" BorderThickness="0"
                  ToolTip="Upgrade tools"/>
        </StackPanel>
        <Grid>
          <StackPanel VerticalAlignment="Bottom">
            <!-- Session info -->
            <Border Style="{StaticResource SidebarCard}" Margin="12,0,12,8">
              <StackPanel>
                <TextBlock Name="sbSessionTitle" Text="Session" Style="{StaticResource SidebarTitle}"/>
                <Grid Margin="0,4,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>

                  <TextBlock Name="sbMachineLabel" Grid.Row="0" Grid.Column="0" Text="Machine:" Style="{StaticResource SidebarText}" FontWeight="SemiBold" Foreground="#111827" Margin="0,0,6,4"/>
                  <Border Grid.Row="0" Grid.Column="1" Background="#EEF2FF" Padding="6,2" CornerRadius="4" Margin="0,0,0,4">
                    <TextBlock Name="SessionMachineTxt" Text="..." Style="{StaticResource SidebarText}" Foreground="#1D4ED8"/>
                  </Border>

                  <TextBlock Name="sbUserLabel" Grid.Row="1" Grid.Column="0" Text="User:" Style="{StaticResource SidebarText}" FontWeight="SemiBold" Foreground="#111827" Margin="0,0,6,4"/>
                  <Border Grid.Row="1" Grid.Column="1" Background="#ECFDF3" Padding="6,2" CornerRadius="4" Margin="0,0,0,4">
                    <TextBlock Name="SessionUserTxt" Text="..." Style="{StaticResource SidebarText}" Foreground="#166534"/>
                  </Border>

                  <TextBlock Name="sbElevationLabel" Grid.Row="2" Grid.Column="0" Text="Elevation:" Style="{StaticResource SidebarText}" FontWeight="SemiBold" Foreground="#111827" Margin="0,0,6,0"/>
                  <Border Grid.Row="2" Grid.Column="1" Name="SessionElevationPill" Background="#ECFDF3" Padding="6,2" CornerRadius="4">
                    <TextBlock Name="SessionElevationTxt" Text="..." Style="{StaticResource SidebarText}" Foreground="#166534"/>
                  </Border>
                </Grid>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource SidebarCard}" Margin="12,0,12,14">
              <StackPanel>
                <TextBlock Name="sbAboutTitle" Text="About this tool" Style="{StaticResource SidebarTitle}"/>
                <TextBlock Name="sbAboutBody" Style="{StaticResource SidebarText}" Text="For unsupported hardware: bypasses TPM 2.0, Secure Boot, and CPU checks. Runs readiness checks, validates setup media, and launches the upgrade safely."/>
              </StackPanel>
            </Border>

            <!-- Footer -->
            <Border BorderBrush="#E6EBF4" BorderThickness="0,1,0,0" Padding="14" Background="#FFFFFF">
              <StackPanel>
                <TextBlock Name="sbFooterOrg" Text="Windows 11 Upgrade" FontSize="13" FontWeight="Bold" Foreground="#1F2D3A"/>
                <!-- Footer version is bound to $UiVersion at runtime; the literal below is the fallback if binding is bypassed. -->
                <TextBlock Name="sbFooterVersion" Text="Version 1.1" FontSize="11" Foreground="#5F6B7A" Margin="0,4,0,0"/>
                <TextBlock FontSize="11" Foreground="#7C8BA1" Margin="0,8,0,0">
                  <Run Text="© 2025-2026 "/>
                  <Hyperlink x:Name="FooterLink" NavigateUri="https://www.linkedin.com/in/mabdulkadr/">Mohammad Omar</Hyperlink>
                </TextBlock>
              </StackPanel>
            </Border>
          </StackPanel>
        </Grid>
      </DockPanel>
    </Border>
    <Grid Grid.Column="1" Name="mainContentGrid">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <Border Grid.Row="0" Margin="16,12,16,10" Padding="16,12" Background="#FFFFFF" BorderBrush="#DCE8F2" BorderThickness="1" CornerRadius="6">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0">
            <TextBlock Name="tHeaderTitle" Text="Windows 11 Upgrade  -  Unsupported Devices" FontSize="20" FontWeight="Bold" Foreground="#1F2D3A"/>
            <TextBlock Name="tHeaderSub" Text="Bypasses TPM 2.0, Secure Boot, and CPU checks. Preserves your files and applications." FontSize="13" Foreground="#5F6B7A" Margin="0,6,0,0"/>
          </StackPanel>
          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
            <Button Name="btnRecheck" Content="Re-check" Height="30" MinWidth="96" Margin="0,0,10,0" Padding="12,0"
                    Style="{StaticResource BtnPrimary}" ToolTip="Re-scan device info and readiness"/>
          </StackPanel>
        </Grid>
      </Border>
      <Grid Grid.Row="1" Margin="16,0,16,14">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="1.10*"/>
          <ColumnDefinition Width="0.95*"/>
        </Grid.ColumnDefinitions>
        <Border Grid.Row="0" Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,12,10" VerticalAlignment="Stretch">
          <Grid Grid.IsSharedSizeScope="True">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="100" SharedSizeGroup="LabelCol"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <TextBlock Name="lblDeviceTitle" Grid.Row="0" Grid.ColumnSpan="2" Text="OS Details" FontWeight="Bold" Foreground="#111827" FontSize="13" Margin="0,0,0,10"/>
            <TextBlock Name="lblWindows" Grid.Row="1" Grid.Column="0" Text="Windows" Foreground="#6B7280"/>
            <Border Grid.Row="1" Grid.Column="1" Style="{StaticResource ValuePill}"><TextBlock Name="tOS" Text="—" FontWeight="SemiBold" Foreground="#111827"/></Border>
            <TextBlock Name="lblVersion" Grid.Row="2" Grid.Column="0" Text="Version" Foreground="#6B7280"/>
            <Border Grid.Row="2" Grid.Column="1" Style="{StaticResource ValuePill}"><TextBlock Name="tVer" Text="—" FontWeight="SemiBold" Foreground="#111827"/></Border>
            <TextBlock Name="lblBuild" Grid.Row="3" Grid.Column="0" Text="Build (UBR)" Foreground="#6B7280"/>
            <Border Grid.Row="3" Grid.Column="1" Style="{StaticResource ValuePill}"><TextBlock Name="tBuild" Text="—" FontWeight="SemiBold" Foreground="#111827"/></Border>
            <TextBlock Name="lblInstallDate" Grid.Row="4" Grid.Column="0" Text="Install Date" Foreground="#6B7280"/>
            <Border Grid.Row="4" Grid.Column="1" Style="{StaticResource ValuePill}"><TextBlock Name="tInstall" Text="—" FontWeight="SemiBold" Foreground="#111827"/></Border>
            
            <TextBlock Name="lblModel" Grid.Row="6" Grid.Column="0" Text="Model" Foreground="#6B7280"/>
            <Border Grid.Row="6" Grid.Column="1" Style="{StaticResource ValuePill}"><TextBlock Name="tModel" Text="—" FontWeight="SemiBold" Foreground="#111827"/></Border>
          </Grid>
        </Border>
        <Border Grid.Row="0" Grid.Column="1" Style="{StaticResource Card}" Margin="0,0,0,10" VerticalAlignment="Stretch">
          <StackPanel>
            <TextBlock Name="tReadinessTitle" Text="Readiness Checks" Style="{StaticResource CardTitle}"/>
            <TextBlock Name="tReadinessSummary" Foreground="#6B7280" TextWrapping="Wrap"/>
            <Grid Margin="0,10,0,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="110"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>

              <TextBlock Name="tChkRamLabel" Grid.Row="0" Grid.Column="0" Text="RAM:"
                         FontWeight="SemiBold" Foreground="#111827" Margin="0,0,8,6"/>
              <Border Name="bChkRam" Grid.Row="0" Grid.Column="1"
                      CornerRadius="0" Padding="8,4" Background="#EEF2F7" BorderBrush="#E4E9F0" BorderThickness="1" Margin="0,0,0,6">
                <TextBlock Name="tChkRam" Text="-" Foreground="#374151"/>
              </Border>

              <TextBlock Name="tChkDiskLabel" Grid.Row="1" Grid.Column="0" Text="Free Disk (C:):"
                         FontWeight="SemiBold" Foreground="#111827" Margin="0,0,8,6"/>
              <Border Name="bChkDisk" Grid.Row="1" Grid.Column="1"
                      CornerRadius="0" Padding="8,4" Background="#EEF2F7" BorderBrush="#E4E9F0" BorderThickness="1" Margin="0,0,0,6">
                <TextBlock Name="tChkDisk" Text="-" Foreground="#374151"/>
              </Border>

              <TextBlock Name="tChkACLabel" Grid.Row="2" Grid.Column="0" Text="Power (AC):"
                         FontWeight="SemiBold" Foreground="#111827" Margin="0,0,8,0"/>
              <Border Name="bChkAC" Grid.Row="2" Grid.Column="1"
                      CornerRadius="0" Padding="8,4" Background="#EEF2F7" BorderBrush="#E4E9F0" BorderThickness="1">
                <TextBlock Name="tChkAC" Text="-" Foreground="#374151"/>
              </Border>
            </Grid>
          </StackPanel>
        </Border>
        <Border Grid.Row="1" Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,12,0" VerticalAlignment="Stretch">
          <StackPanel>
            <TextBlock Name="tMediaTitle" Text="Windows Media" Style="{StaticResource CardTitle}"/>
            <TextBlock Name="tMediaHelp" Foreground="#6B7280" TextWrapping="Wrap" Margin="0,0,0,6" FontSize="12"/>
            <Grid Margin="0,4,0,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="100"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>

              <TextBlock Name="tSetupPathLabel" Grid.Row="0" Grid.Column="0" Foreground="#111827" FontWeight="SemiBold"
                         Margin="0,6,8,6" VerticalAlignment="Center"/>
              <TextBox Name="tbSetupPath" Grid.Row="0" Grid.Column="1" Height="30" Background="White" BorderBrush="#DDE6F2" BorderThickness="1"
                       Padding="4" VerticalContentAlignment="Center" FlowDirection="LeftToRight" TextAlignment="Left"
                       ToolTip="Select setup.exe from a mounted ISO or USB media"/>
              <StackPanel Grid.Row="0" Grid.Column="2" Orientation="Horizontal" Margin="8,0,0,0">
                <Button Name="btnBrowse" Content="Browse..." Height="30" MinWidth="70" Padding="12,0"
                        Style="{StaticResource BtnGreen}" ToolTip="Browse for setup.exe on local media"/>
                <Button Name="btnClearSetup" Content="Clear" Height="30" MinWidth="50" Margin="6,0,0,0" Padding="12,0"
                        Style="{StaticResource BtnBlue}" ToolTip="Clear the current setup.exe path"/>
              </StackPanel>

              <TextBlock Name="tIsoPathLabel" Grid.Row="1" Grid.Column="0" Foreground="#111827" FontWeight="SemiBold"
                         Margin="0,10,8,6" VerticalAlignment="Center"/>
              <StackPanel Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="2" Orientation="Horizontal" Margin="0,8,0,0">
                <Button Name="btnIsoBrowse" Content="Choose ISO" Height="30" MinWidth="110" Padding="12,0"
                        Style="{StaticResource BtnGreen}" ToolTip="Select an ISO file, mount it, and fill setup.exe"/>
                <Button Name="btnIsoDismount" Content="Unmount ISO" Height="30" MinWidth="130" Margin="8,0,0,0" Padding="12,0"
                        Style="{StaticResource BtnBlue}" Visibility="Collapsed"
                        ToolTip="Release the currently mounted ISO"/>
                <Button Name="btnIsoDownload" Content="Download ISO" Height="30" MinWidth="170" Margin="8,0,0,0" Padding="12,0"
                        Style="{StaticResource BtnBlue}" ToolTip="Open Microsoft Windows 11 download page (official)"/>
              </StackPanel>

            </Grid>
            <TextBlock Foreground="#6B7280" FontSize="11" TextWrapping="Wrap" Margin="0,8,0,0"
                       Text="Tip: Use Download for fresh ISO, or Browse to use a local file."/>
          </StackPanel>
        </Border>
        <Border Grid.Row="1" Grid.Column="1" Style="{StaticResource Card}" Margin="0,0,0,0" VerticalAlignment="Stretch">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
            <TextBlock Name="tCmdProfileTitle" Margin="0,0,0,4" Foreground="#111827" FontWeight="SemiBold"/>
            <TextBlock Name="tCmdProfileHelp" Foreground="#6B7280" TextWrapping="Wrap" FontSize="12" Margin="0,0,0,6"/>
            <ComboBox Name="cbSetupProfile" Height="30" Background="White" BorderBrush="#DDE6F2" BorderThickness="1" Padding="4" Margin="0,0,0,4"
                      ToolTip="Choose the base setup arguments preset"/>
            <Border Background="#F3F7FF" BorderBrush="#E1E8F5" BorderThickness="1" CornerRadius="4" Padding="3" Margin="0,0,0,5">
              <TextBlock Name="tCmdProfileDesc" Foreground="#6B7280" TextWrapping="Wrap" FontSize="12"/>
            </Border>
              <TextBlock Name="tExtraArgsLabel" Margin="0,8,0,4" Foreground="#111827" FontWeight="SemiBold"/>
            <TextBlock Name="tExtraArgsHelp" Foreground="#6B7280" TextWrapping="Wrap" FontSize="12" Margin="0,0,0,6">
              <Hyperlink Name="ExtraArgsLink" NavigateUri="https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-command-line-options?view=windows-11">
                Windows Setup command-line options
              </Hyperlink>
            </TextBlock>
            <TextBox Name="tbExtraArgs" Height="30" Background="White" BorderBrush="#DDE6F2" BorderThickness="1"
                       Padding="4" VerticalContentAlignment="Center" FlowDirection="LeftToRight" TextAlignment="Left"
                       ToolTip="Optional: add extra setup.exe switches"/>
            </StackPanel>
          </Grid>
        </Border>
      </Grid>
      <Border Grid.Row="2" Margin="16,0,16,10" Padding="12" Background="#FFFFFF" BorderBrush="#DCE8F2" BorderThickness="1" CornerRadius="6">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="8"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <Grid Grid.Row="0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Name="tPlannedTitle" Text="Planned command" HorizontalAlignment="left"
                       VerticalAlignment="Center" Foreground="#111827" FontWeight="SemiBold" Margin="12,2,0,0"
                       ToolTip="Full setup.exe command that will be executed"/>
            <Button Grid.Column="1" Name="btnCopyCmd" Content="Copy" Height="28" Width="84" Padding="12,0" HorizontalAlignment="Right"
                    Style="{StaticResource BtnBlue}" ToolTip="Copy the full command to the clipboard"/>
          </Grid>
          <TextBox Grid.Row="2" Name="tbCmd" Height="74" MinHeight="74" MaxHeight="74"
                   Background="#F3F7FF" BorderBrush="#DDE6F2" BorderThickness="1" Padding="8"
                   FontFamily="Consolas" TextWrapping="Wrap" IsReadOnly="True"
                   VerticalContentAlignment="Top" VerticalScrollBarVisibility="Auto"
                   ToolTip="Copy or review the exact command"/>
        </Grid>
      </Border>
      <Grid Grid.Row="3" Margin="16,0,16,10" >
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Border Grid.Column="0" Background="#FFFFFF" BorderBrush="#DCE8F2" BorderThickness="1" CornerRadius="6" Margin="0,0,12,0" Padding="12,8">
          <TextBlock Name="tMediaStatus" Foreground="#6B7280" FontSize="12" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        </Border>
        <Button Grid.Column="1" Name="btnClose" Content="Close" Height="36" MinWidth="120" Margin="0,0,8,0" Padding="12,0"
                Style="{StaticResource BtnBlue}" ToolTip="Close this window"/>
        <Button Grid.Column="2" Name="btnUpgrade" Content="Start Upgrade" MinHeight="36" MinWidth="160" Padding="14,0"
                Style="{StaticResource BtnPrimary}" IsEnabled="False" ToolTip="Start Windows Setup"/>
      </Grid>
    </Grid>
  </Grid>
</Window>
"@
#endregion ==============================================================

#region ========================= CONTROL REFS ==========================
# ---------------------------------------------------------------------------
# Bind to the XAML.
# XamlReader.Load expects an XmlReader, hence the XmlNodeReader wrapper.
# ---------------------------------------------------------------------------
$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$win    = [Windows.Markup.XamlReader]::Load($reader)

$tHeaderTitle = $win.FindName("tHeaderTitle")
$tHeaderSub   = $win.FindName("tHeaderSub")
$btnRecheck   = $win.FindName("btnRecheck")
$mainContentGrid = $win.FindName("mainContentGrid")

$tTopHint     = $win.FindName("tTopHint")

$tReadinessTitle   = $win.FindName("tReadinessTitle")
$tReadinessSummary = $win.FindName("tReadinessSummary")
$tChkRamLabel = $win.FindName("tChkRamLabel")
$tChkDiskLabel = $win.FindName("tChkDiskLabel")
$tChkACLabel = $win.FindName("tChkACLabel")
$bChkRam = $win.FindName("bChkRam")
$bChkDisk = $win.FindName("bChkDisk")
$bChkAC = $win.FindName("bChkAC")
$tChkRam  = $win.FindName("tChkRam")
$tChkDisk = $win.FindName("tChkDisk")
$tChkAC   = $win.FindName("tChkAC")

$lblDeviceTitle = $win.FindName("lblDeviceTitle")
$lblHardwareTitle = $win.FindName("lblHardwareTitle")
$lblWindows = $win.FindName("lblWindows")
$lblVersion = $win.FindName("lblVersion")
$lblBuild = $win.FindName("lblBuild")
$lblInstallDate = $win.FindName("lblInstallDate")
$lblModel = $win.FindName("lblModel")
$lblRam = $win.FindName("lblRam")
$lblFreeDisk = $win.FindName("lblFreeDisk")

$tOS = $win.FindName("tOS")
$tVer = $win.FindName("tVer")
$tBuild = $win.FindName("tBuild")
$tInstall = $win.FindName("tInstall")
$tModel = $win.FindName("tModel")
$tMediaTitle = $win.FindName("tMediaTitle")
$tMediaHelp  = $win.FindName("tMediaHelp")
$tSetupPathLabel = $win.FindName("tSetupPathLabel")
$tbSetupPath = $win.FindName("tbSetupPath")
$btnBrowse   = $win.FindName("btnBrowse")
$btnClearSetup = $win.FindName("btnClearSetup")
$tMediaStatus= $win.FindName("tMediaStatus")
$tIsoPathLabel = $win.FindName("tIsoPathLabel")
$btnIsoBrowse = $win.FindName("btnIsoBrowse")
$btnIsoDismount = $win.FindName("btnIsoDismount")
$btnIsoDownload = $win.FindName("btnIsoDownload")
$tCmdProfileTitle = $win.FindName("tCmdProfileTitle")
$tCmdProfileHelp = $win.FindName("tCmdProfileHelp")
$tCmdProfileDesc = $win.FindName("tCmdProfileDesc")
$cbSetupProfile = $win.FindName("cbSetupProfile")
$tExtraArgsLabel = $win.FindName("tExtraArgsLabel")
$tExtraArgsHelp = $win.FindName("tExtraArgsHelp")
$ExtraArgsLink = $win.FindName("ExtraArgsLink")
$tbExtraArgs = $win.FindName("tbExtraArgs")
$tPlannedTitle = $win.FindName("tPlannedTitle")
$btnCopyCmd   = $win.FindName("btnCopyCmd")
$tbCmd       = $win.FindName("tbCmd")

$btnClose    = $win.FindName("btnClose")
$btnUpgrade  = $win.FindName("btnUpgrade")

$sessionMachineTxt = $win.FindName("SessionMachineTxt")
$sessionUserTxt = $win.FindName("SessionUserTxt")
$sessionElevationTxt = $win.FindName("SessionElevationTxt")
$sessionElevationPill = $win.FindName("SessionElevationPill")

$sbAppTitle = $win.FindName("sbAppTitle")
$sbAppSub = $win.FindName("sbAppSub")
$sbToolsTitle = $win.FindName("sbToolsTitle")
$sbUpgradeBtn = $win.FindName("sbUpgradeBtn")
$sbSessionTitle = $win.FindName("sbSessionTitle")
$sbMachineLabel = $win.FindName("sbMachineLabel")
$sbUserLabel = $win.FindName("sbUserLabel")
$sbElevationLabel = $win.FindName("sbElevationLabel")
$sbAboutTitle = $win.FindName("sbAboutTitle")
$sbAboutBody = $win.FindName("sbAboutBody")
$sbFooterOrg = $win.FindName("sbFooterOrg")
$sbFooterVersion = $win.FindName("sbFooterVersion")
$FooterLink = $win.FindName("FooterLink")

# ---------------------------------------------------------------------------
# Script-level state.
# These are $script: scoped so event-handler scriptblocks (which run in a
# child scope) can read/write them without re-importing.
# ---------------------------------------------------------------------------
# $script:SetupOk     : True when the path in $tbSetupPath passes Test-SetupExePath.
# $script:IsAdmin     : True when the current process is elevated.
# $script:Device      : The PSCustomObject returned by Get-DeviceInfo.
# $script:IsLoading   : True while a background device-info job is running.
# $script:BgPs        : The PowerShell instance used for the background runspace.
# $script:BgAsync     : IAsyncResult returned by BeginInvoke on $script:BgPs.
# $script:BgTimer     : DispatcherTimer that polls the background job.
# $script:SetupPathBorderDefault / SetupPathBgDefault : Cached brushes so we
#                       can restore the original look when validation fails.
# $script:MountedIso  : The DiskImage object returned by Mount-DiskImage, kept
#                       so Dismount-DiskImage can be issued later.
# ---------------------------------------------------------------------------
$script:SetupOk     = $false
$script:IsAdmin     = $false
$script:Device      = $null
$script:IsLoading   = $false
$script:BgPs        = $null
$script:BgAsync     = $null
$script:BgTimer     = $null
$script:SetupPathBorderDefault = $null
$script:SetupPathBgDefault     = $null
$script:MountedIso  = $null

# Cache the original brushes of the setup-path textbox so Update-SetupState
# can switch it to "valid" (green) and back to "default" without losing
# the original styling.
if ($tbSetupPath) {
    $script:SetupPathBorderDefault = $tbSetupPath.BorderBrush
    $script:SetupPathBgDefault     = $tbSetupPath.Background
}
#endregion ==============================================================

#region ============================ BINDINGS ===========================

<#
.SYNOPSIS
    Applies the English UI labels and triggers the first paint of dynamic
    content (profile list, device info, status bar). The script is
    English-only by design; this function exists to centralise every
    string so a future translation can be plugged in by replacing this
    function body.
#>
function Apply-Lang {
    $win.Title = "Windows 11 Upgrade"
    if ($tHeaderTitle) { $tHeaderTitle.Text = "Welcome  -  Unsupported Devices" }
    if ($tHeaderSub) { $tHeaderSub.Text = "Upgrade unsupported PCs to Windows 11 (bypasses TPM 2.0, Secure Boot, and CPU checks). Preserves your files and applications." }
    if ($tTopHint) { $tTopHint.Text = "Pick the Windows setup.exe file to enable Start Upgrade." }

    if ($tMediaTitle) { $tMediaTitle.Text = "Windows Media" }
    if ($tMediaHelp) { $tMediaHelp.Text = "Browse to setup.exe on your USB or mounted ISO." }
    if ($tSetupPathLabel) { $tSetupPathLabel.Text = "setup.exe path:" }
    if ($tIsoPathLabel) { $tIsoPathLabel.Text = "ISO actions:" }
    if ($btnIsoBrowse) { $btnIsoBrowse.Content = "Choose ISO" }
    if ($btnIsoDownload) { $btnIsoDownload.Content = "ISO Download" }
    if ($tPlannedTitle) { $tPlannedTitle.Text = "Planned command" }
    if ($btnCopyCmd) { $btnCopyCmd.Content = "Copy" }
    if ($tCmdProfileTitle) { $tCmdProfileTitle.Text = "Setup options" }
    if ($tCmdProfileHelp) { $tCmdProfileHelp.Text = "Choose a preset from the list." }
    Update-ProfileDescription
    if ($tExtraArgsLabel) { $tExtraArgsLabel.Text = "Extra arguments (optional)" }
    # tExtraArgsHelp uses a hyperlink in XAML; no text assignment here.
    if ($tReadinessTitle) { $tReadinessTitle.Text = "Readiness Checks" }
    if ($tChkRamLabel) { $tChkRamLabel.Text = "RAM:" }
    if ($tChkDiskLabel) { $tChkDiskLabel.Text = "Free Disk (C:):" }
    if ($tChkACLabel) { $tChkACLabel.Text = "Power (AC):" }

    if ($btnBrowse) { $btnBrowse.Content = "Browse..." }
    if ($btnClearSetup) { $btnClearSetup.Content = "Clear" }
    if ($btnIsoDismount) { $btnIsoDismount.Content = "Unmount ISO" }
    if ($btnRecheck) { $btnRecheck.Content = "Re-check" }
    if ($btnUpgrade) { $btnUpgrade.Content = "Start Upgrade" }
    if ($btnClose) { $btnClose.Content = "Close" }

    if ($lblDeviceTitle) { $lblDeviceTitle.Text = "Device & OS Details" }
    if ($lblHardwareTitle) { $lblHardwareTitle.Text = "Hardware" }
    if ($lblRam) { $lblRam.Text = "RAM (GB)" }
    if ($lblFreeDisk) { $lblFreeDisk.Text = "Free Disk C: (GB)" }
    if ($lblWindows) { $lblWindows.Text = "Windows" }
    if ($lblVersion) { $lblVersion.Text = "Version" }
    if ($lblBuild) { $lblBuild.Text = "Build (UBR)" }
    if ($lblInstallDate) { $lblInstallDate.Text = "Install Date" }
    if ($lblModel) { $lblModel.Text = "Model" }
    if ($lblRam) { $lblRam.Text = "RAM (GB)" }
    if ($lblFreeDisk) { $lblFreeDisk.Text = "Free Disk C: (GB)" }

    if ($sbAppTitle) { $sbAppTitle.Text = "Windows 11 Upgrade" }
    if ($sbAppSub) { $sbAppSub.Text = "Upgrade Assistant" }
    if ($sbToolsTitle) { $sbToolsTitle.Text = "TOOLS" }
    if ($sbUpgradeBtn) { $sbUpgradeBtn.Content = "Upgrade" }
    if ($sbSessionTitle) { $sbSessionTitle.Text = "Session" }
    if ($sbMachineLabel) { $sbMachineLabel.Text = "Machine:" }
    if ($sbUserLabel) { $sbUserLabel.Text = "User:" }
    if ($sbElevationLabel) { $sbElevationLabel.Text = "Elevation:" }
    if ($sbAboutTitle) { $sbAboutTitle.Text = "About this tool" }
    if ($sbAboutBody) { $sbAboutBody.Text = "For unsupported hardware: bypasses TPM 2.0, Secure Boot, and CPU checks to upgrade this PC to Windows 11 while preserving files and applications." }
    if ($sbFooterOrg) { $sbFooterOrg.Text = "Windows 11 Upgrade" }
    if ($sbFooterVersion) { $sbFooterVersion.Text = ("Version {0}" -f $UiVersion) }

    if ($sessionElevationTxt) {
        $sessionElevationTxt.Text = if ($script:IsAdmin) { "Administrator" } else { "Standard" }
    }

    Update-ProfileItems
    Update-DeviceUI
    Update-SetupState
    Set-IsoButtonsEnabled -Enabled $true
}

<#
.SYNOPSIS
    Rebuilds the Setup-Profile ComboBox from $script:SetupProfiles.
    Preserves the current selection whenever possible, otherwise falls back
    to $script:DefaultProfileKey.
#>
function Update-ProfileItems {
    if (-not $cbSetupProfile) { return }
    $currentKey = $null
    if ($cbSetupProfile.SelectedItem -and $cbSetupProfile.SelectedItem.Tag) {
        $currentKey = [string]$cbSetupProfile.SelectedItem.Tag
    }
    $cbSetupProfile.Items.Clear()
    foreach ($p in $script:SetupProfiles) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $p.LabelEN
        $item.Tag = $p.Key
        if ($p.Desc) { $item.ToolTip = $p.Desc }
        $null = $cbSetupProfile.Items.Add($item)
    }
    $targetKey = if ($currentKey) { $currentKey } else { $script:DefaultProfileKey }
    for ($i = 0; $i -lt $cbSetupProfile.Items.Count; $i++) {
        $it = $cbSetupProfile.Items[$i]
        if ($it -and $it.Tag -eq $targetKey) {
            $cbSetupProfile.SelectedIndex = $i
            return
        }
    }
    if ($cbSetupProfile.Items.Count -gt 0) { $cbSetupProfile.SelectedIndex = 0 }
    Update-ProfileDescription
}

<#
.SYNOPSIS
    Returns the Args string of the currently selected setup profile, or
    the default profile's args if no selection is present.
#>
function Get-SelectedProfileArgs {
    $key = $script:DefaultProfileKey
    if ($cbSetupProfile -and $cbSetupProfile.SelectedItem -and $cbSetupProfile.SelectedItem.Tag) {
        $key = [string]$cbSetupProfile.SelectedItem.Tag
    }
    $profile = $script:SetupProfiles | Where-Object { $_.Key -eq $key } | Select-Object -First 1
    if (-not $profile) {
        $profile = $script:SetupProfiles | Where-Object { $_.Key -eq $script:DefaultProfileKey } | Select-Object -First 1
    }
    if ($profile) { return $profile.Args }
    return ""
}

<#
.SYNOPSIS
    Returns the human-readable description (Desc) of the currently
    selected setup profile, or an empty string.
#>
function Get-SelectedProfileDescription {
    $key = $script:DefaultProfileKey
    if ($cbSetupProfile -and $cbSetupProfile.SelectedItem -and $cbSetupProfile.SelectedItem.Tag) {
        $key = [string]$cbSetupProfile.SelectedItem.Tag
    }
    $profile = $script:SetupProfiles | Where-Object { $_.Key -eq $key } | Select-Object -First 1
    if (-not $profile) {
        $profile = $script:SetupProfiles | Where-Object { $_.Key -eq $script:DefaultProfileKey } | Select-Object -First 1
    }
    if ($profile -and $profile.Desc) { return [string]$profile.Desc }
    return ""
}

<#
.SYNOPSIS
    Refreshes the small "description" textbox below the profile combobox
    to match the currently selected profile.
#>
function Update-ProfileDescription {
    if (-not $tCmdProfileDesc) { return }
    $desc = Get-SelectedProfileDescription
    if ([string]::IsNullOrWhiteSpace($desc)) {
        $tCmdProfileDesc.Text = "Select an option to view its details."
    } else {
        $tCmdProfileDesc.Text = $desc
    }
}

<#
.SYNOPSIS
    Joins the selected profile args with any user-provided extra args
    (from the "Extra arguments" textbox). Trailing/leading whitespace is
    trimmed; only one space separates the two segments.
#>
function Get-CombinedSetupArgs {
    $baseArgs = Get-SelectedProfileArgs
    $extraArgs = ""
    if ($tbExtraArgs) { $extraArgs = $tbExtraArgs.Text.Trim() }
    if ([string]::IsNullOrWhiteSpace($extraArgs)) { return $baseArgs }
    if ([string]::IsNullOrWhiteSpace($baseArgs)) { return $extraArgs }
    return ($baseArgs + " " + $extraArgs)
}

<#
.SYNOPSIS
    Returns the parent directory of the given setup.exe path, or $null if
    the path is empty or the file does not exist. Used as the working
    directory when launching setup.exe (so it can find its sibling files).
.PARAMETER SetupPath
    Absolute path to setup.exe.
#>
function Get-SetupWorkingDirectory {
    param([string]$SetupPath)
    try {
        if ([string]::IsNullOrWhiteSpace($SetupPath)) { return $null }
        if (!(Test-Path $SetupPath)) { return $null }
        return (Split-Path -Parent $SetupPath)
    } catch { return $null }
}

<#
.SYNOPSIS
    Maps a launch-time ErrorRecord to a short, end-user friendly message
    that the status bar can display. Falls back to a generic "could not
    open" message when the error text is empty or unrecognised.
#>
function Get-LaunchErrorText {
    param([object]$ErrorRecord)
    $msg = ""
    try {
        if ($ErrorRecord -and $ErrorRecord.Exception) { $msg = [string]$ErrorRecord.Exception.Message }
    } catch {}

    if ($msg -match "access is denied|denied") { return "Access denied. Run as administrator or check policy/AppLocker." }
    if ($msg -match "requires elevation|elevation") { return "Administrator permission is required to start setup." }
    if ($msg -match "canceled|cancelled") { return "UAC prompt was canceled." }
    if ($msg -match "cannot find the file|not find the file") { return "setup.exe not found or media disconnected." }
    if ($msg -match "blocked") { return "Windows blocked setup.exe. Check AppLocker/Defender policy." }

    if (-not [string]::IsNullOrWhiteSpace($msg)) { return ("Could not open Windows Setup: {0}" -f $msg) }
    return "Could not open Windows Setup."
}

<#
.SYNOPSIS
    Launches setup.exe with the provided argument list. The working
    directory is automatically set to the directory containing setup.exe
    so its sibling files (sources, boot, etc.) are resolvable.

.PARAMETER SetupPath
    Absolute path to setup.exe.
.PARAMETER SetupArgs
    The argument string to pass (already combined via Get-CombinedSetupArgs).
.PARAMETER RunAs
    When present, the process is started with the "RunAs" verb, which
    triggers a UAC elevation prompt.
#>
function Start-WindowsSetup {
    param(
        [Parameter(Mandatory)][string]$SetupPath,
        [string]$SetupArgs,
        [switch]$RunAs
    )
    $startParams = @{
        FilePath = $SetupPath
        ArgumentList = $SetupArgs
        ErrorAction = "Stop"
        PassThru = $true
    }
    $workDir = Get-SetupWorkingDirectory -SetupPath $SetupPath
    if ($workDir) { $startParams.WorkingDirectory = $workDir }
    if ($RunAs) { $startParams.Verb = "RunAs" }
    return (Start-Process @startParams)
}

<#
.SYNOPSIS
    Creates a frozen SolidColorBrush from a #RRGGBB hex string. Frozen
    brushes are thread-safe and slightly faster to draw; failures fall
    back to Transparent so the UI never crashes on a malformed colour.
#>
function New-Brush {
    param([string]$Hex)
    try {
        $c = [Windows.Media.ColorConverter]::ConvertFromString($Hex)
        $b = New-Object Windows.Media.SolidColorBrush $c
        $b.Freeze()
        return $b
    } catch { return [Windows.Media.Brushes]::Transparent }
}

# Pre-build the three states' brush pairs so Set-CheckPill never has to.
$script:ChkOkBg  = New-Brush "#DCF5E6"
$script:ChkOkFg  = New-Brush "#1F6A3A"
$script:ChkBadBg = New-Brush "#FAD3D3"
$script:ChkBadFg = New-Brush "#8A1C1C"
$script:ChkNeuBg = New-Brush "#EEF2F7"
$script:ChkNeuFg = New-Brush "#374151"

<#
.SYNOPSIS
    Paints one of the readiness pills (RAM / Disk / Power) with the
    appropriate colour/text for the given state.
.PARAMETER Border
    The Border element that owns the background colour.
.PARAMETER TextBlock
    The inner TextBlock whose Text and Foreground are updated.
.PARAMETER State
    One of: OK (green), FAIL (red), NEUTRAL (grey).
.PARAMETER Text
    The human-readable text to display inside the pill.
#>
function Set-CheckPill {
    param(
        [Parameter(Mandatory)][System.Windows.Controls.Border]$Border,
        [Parameter(Mandatory)][System.Windows.Controls.TextBlock]$TextBlock,
        [Parameter(Mandatory)][ValidateSet("OK","FAIL","NEUTRAL")]$State,
        [Parameter(Mandatory)][string]$Text
    )
    $TextBlock.Text = $Text
    switch ($State) {
        "OK" {
            $Border.Background   = $script:ChkOkBg
            $TextBlock.Foreground = $script:ChkOkFg
        }
        "FAIL" {
            $Border.Background   = $script:ChkBadBg
            $TextBlock.Foreground = $script:ChkBadFg
        }
        default {
            $Border.Background   = $script:ChkNeuBg
            $TextBlock.Foreground = $script:ChkNeuFg
        }
    }
}

<#
.SYNOPSIS
    Repaints the entire readiness panel from $script:Device. Called by
    Update-DeviceUI and by the background-checks completion callback.

.DESCRIPTION
    Behaviour:
      * If $script:Device is null and a check is in flight, show
        "Checking device readiness..." in dark grey and render three
        neutral em-dash pills.
      * If $script:Device is null and no check is running, show the
        "Checks failed" hint in red (typically: WMI is disabled, or the
        script was started without the rights to query the registry).
      * Otherwise, each pill is OK if the measured value meets
        $MinRamGB / $MinDiskGB / AC power, else FAIL.
      * The summary line is red when any pill is FAIL or when both RAM
        and disk readings are missing, otherwise dark green.
#>
function Update-ReadinessUI {
    $d = $script:Device
    if (-not $d) {
        if ($script:IsLoading) {
            $tReadinessSummary.Text       = "Checking device readiness..."
            $tReadinessSummary.Foreground = [System.Windows.Media.Brushes]::DarkSlateGray
        } else {
            $tReadinessSummary.Text       = "Checks failed. Try as admin or ensure WMI is running."
            $tReadinessSummary.Foreground = [System.Windows.Media.Brushes]::Firebrick
        }
        Set-CheckPill $bChkRam  $tChkRam  "NEUTRAL" "—"
        Set-CheckPill $bChkDisk $tChkDisk "NEUTRAL" "—"
        Set-CheckPill $bChkAC   $tChkAC   "NEUTRAL" "—"
        return
    }

    $ramVal  = $d.RamGB
    $diskVal = $d.FreeC

    # RAM pill: OK when at/above the configured minimum.
    $ramState = "NEUTRAL"
    if ($ramVal -ne $null -and $ramVal -ne "") {
        $ramState = if ([double]$ramVal -ge [double]$MinRamGB) { "OK" } else { "FAIL" }
    }
    # Disk pill: OK when C: has at/above the configured minimum free space.
    $diskState = "NEUTRAL"
    if ($diskVal -ne $null -and $diskVal -ne "") {
        $diskState = if ([double]$diskVal -ge [double]$MinDiskGB) { "OK" } else { "FAIL" }
    }

    $ramText  = if ($ramVal  -ne $null -and $ramVal  -ne "") { "{0} GB (Min {1})" -f $ramVal,  $MinRamGB  } else { "—" }
    $diskText = if ($diskVal -ne $null -and $diskVal -ne "") { "{0} GB (Min {1})" -f $diskVal, $MinDiskGB } else { "—" }

    Set-CheckPill $bChkRam  $tChkRam  $ramState  $ramText
    Set-CheckPill $bChkDisk $tChkDisk $diskState $diskText

    # AC power is only consulted when the script requires it.
    $acState = "NEUTRAL"
    $acText  = "—"
    if ($RequireACPower) {
        $okAC    = Get-AcPowerStatus
        $acState = if ($okAC) { "OK" } else { "FAIL" }
        $acText  = if ($okAC) { "OK" } else { "Not on AC" }
    }
    Set-CheckPill $bChkAC $tChkAC $acState $acText

    $hasFail = ($ramState -eq "FAIL" -or $diskState -eq "FAIL" -or ($RequireACPower -and $acState -eq "FAIL"))
    if (($ramVal -eq $null -or $ramVal -eq "") -and ($diskVal -eq $null -or $diskVal -eq "")) {
        $tReadinessSummary.Text       = "Checks failed. Try as admin or ensure WMI is running."
        $tReadinessSummary.Foreground = [System.Windows.Media.Brushes]::Firebrick
    } elseif ($hasFail) {
        $tReadinessSummary.Text       = "One or more requirements are not met."
        $tReadinessSummary.Foreground = [System.Windows.Media.Brushes]::Firebrick
    } else {
        $tReadinessSummary.Text       = "This device meets minimum requirements."
        $tReadinessSummary.Foreground = [System.Windows.Media.Brushes]::DarkGreen
    }
}

<#
.SYNOPSIS
    Repaints the OS Details card from $script:Device, then delegates the
    readiness panel to Update-ReadinessUI.
#>
function Update-DeviceUI {
    $d = $script:Device

    if ($tOS) { $tOS.Text = if ($d -and $d.ProductName) { $d.ProductName } else { "—" } }
    if ($tVer) { $tVer.Text = if ($d -and $d.Version) { $d.Version } else { "—" } }
    if ($tBuild) { $tBuild.Text = if ($d -and $d.Build) { $d.Build } else { "—" } }
    if ($tInstall) { $tInstall.Text = if ($d -and $d.InstallDate) { $d.InstallDate } else { "—" } }
    if ($tModel) { $tModel.Text = if ($d -and $d.Model) { $d.Model } else { "—" } }

    Update-ReadinessUI
}

<#
.SYNOPSIS
    Writes a message into the bottom status bar (tMediaStatus). If no
    colour is supplied the text is rendered in DimGray (neutral).
#>
function Set-StatusBar {
    param(
        [string]$Text,
        [System.Windows.Media.Brush]$Color = $null
    )
    if ($tMediaStatus) {
        $tMediaStatus.Text = $Text
        if ($Color) {
            $tMediaStatus.Foreground = $Color
        } else {
            $tMediaStatus.Foreground = [System.Windows.Media.Brushes]::DimGray
        }
    }
}

<#
.SYNOPSIS
    Recomputes everything that depends on the setup-path textbox:
      * Updates $script:SetupOk via Test-SetupExePath.
      * Repaints the path textbox (green border/bg on success, default on fail).
      * Refreshes the planned-command preview.
      * Enables or disables the "Start Upgrade" button.

    Called whenever the user types in the path field, selects an ISO, or
    changes the profile/extra-args textboxes.
#>
function Update-SetupState {
    $setupPath = $tbSetupPath.Text.Trim()
    $script:SetupOk = Test-SetupExePath $setupPath

    if ($script:SetupOk) {
        Set-StatusBar "setup.exe selected and ready." ([System.Windows.Media.Brushes]::DarkGreen)
    } else {
        $statusText = if ([string]::IsNullOrWhiteSpace($setupPath)) { "Waiting for you to select setup.exe..." } else { "Select a valid setup.exe file." }
        Set-StatusBar $statusText ([System.Windows.Media.Brushes]::Firebrick)
    }

    if ($tbSetupPath) {
        if ($script:SetupOk) {
            $tbSetupPath.BorderBrush = (New-Brush "#8ACFA3")
            $tbSetupPath.Background = (New-Brush "#F0FFF5")
        } else {
            if ($script:SetupPathBorderDefault) { $tbSetupPath.BorderBrush = $script:SetupPathBorderDefault }
            if ($script:SetupPathBgDefault) { $tbSetupPath.Background = $script:SetupPathBgDefault }
        }
    }

    if ($tbCmd) {
        $cmdPath = if ([string]::IsNullOrWhiteSpace($setupPath)) { "<setup.exe path>" } else { $setupPath }
        $setupArgs = Get-CombinedSetupArgs
        $tbCmd.Text = ('{0} {1}' -f $cmdPath, $setupArgs)
    }

    Update-ProfileDescription
    $btnUpgrade.IsEnabled = $script:SetupOk
}

<#
.SYNOPSIS
    Thin alias around Set-StatusBar used by the ISO/mount workflow so
    the call sites read as a logical group.
#>
function Set-IsoStatus {
    param(
        [string]$Text,
        [System.Windows.Media.Brush]$Color = $null
    )
    Set-StatusBar -Text $Text -Color $Color
}

<#
.SYNOPSIS
    Enables or disables the "Choose ISO" and "Download ISO" buttons in
    unison. The Unmount button is left alone - it has its own lifecycle
    driven by Mount-IsoAndSetSetupPath.
#>
function Set-IsoButtonsEnabled {
    param([bool]$Enabled)
    if ($btnIsoBrowse) { $btnIsoBrowse.IsEnabled = $Enabled }
    if ($btnIsoDownload) { $btnIsoDownload.IsEnabled = $Enabled }
}

<#
.SYNOPSIS
    Shows a small, owner-attached Yes/No/Cancel dialog that visually
    matches the main window. Returns one of: "Yes", "No", "Cancel".

.DESCRIPTION
    The dialog uses an in-memory XAML definition so it does not require
    any external file. The result is communicated via the dialog's Tag
    property (set on each button's Click handler) and read by the caller
    once ShowDialog() returns.
.PARAMETER Title
    Window title and bold heading text.
.PARAMETER Message
    Body text shown below the title (wraps automatically).
.PARAMETER YesText
    Caption of the primary action button.
.PARAMETER NoText
    Caption of the secondary action button (often used as "Copy").
.PARAMETER CancelText
    Caption of the cancel button.
#>
function Show-CustomChoiceDialog {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [string]$YesText = "Yes",
        [string]$NoText = "No",
        [string]$CancelText = "Cancel"
    )
    $xamlDialog = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Dialog"
        Width="500"
        SizeToContent="Height"
        MinHeight="220"
        MaxHeight="520"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize"
        Background="#F6F8FB"
        FontFamily="Segoe UI"
        FontSize="13"
        ShowInTaskbar="False">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Border Background="White" BorderBrush="#DCE8F2" BorderThickness="1" CornerRadius="6" Padding="14">
      <StackPanel>
        <TextBlock Name="dlgTitle" FontSize="16" FontWeight="SemiBold" Foreground="#1F2D3A" Margin="0,0,0,8"/>
        <ScrollViewer MaxHeight="280" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <TextBlock Name="dlgMessage" TextWrapping="Wrap" Foreground="#4B5563"/>
        </ScrollViewer>
      </StackPanel>
    </Border>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <Button Name="btnNo" Content="No" Width="90" Height="30" Margin="0,0,8,0"
              Background="#FFFFFF" Foreground="#111827" BorderBrush="#E5E7EB" BorderThickness="1"/>
      <Button Name="btnYes" Content="Yes" Width="90" Height="30" Margin="0,0,8,0"
              Background="#9FAEF7" Foreground="#1F2D3A" BorderThickness="0"/>
      <Button Name="btnCancel" Content="Cancel" Width="90" Height="30"
              Background="#8FB4FF" Foreground="#1F2D3A" BorderThickness="0"/>
    </StackPanel>
  </Grid>
</Window>
"@
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xamlDialog)
    $dlg = [Windows.Markup.XamlReader]::Load($reader)
    if ($win) { $dlg.Owner = $win }
    $dlg.Title = $Title
    $dlg.FindName("dlgTitle").Text = $Title
    $dlg.FindName("dlgMessage").Text = $Message
    $dlg.FindName("btnYes").Content = $YesText
    $dlg.FindName("btnNo").Content = $NoText
    $dlg.FindName("btnCancel").Content = $CancelText

    $dlg.Tag = "Cancel"
    $dlg.FindName("btnYes").Add_Click({ $dlg.Tag = "Yes"; $dlg.Close() })
    $dlg.FindName("btnNo").Add_Click({ $dlg.Tag = "No"; $dlg.Close() })
    $dlg.FindName("btnCancel").Add_Click({ $dlg.Tag = "Cancel"; $dlg.Close() })
    $null = $dlg.ShowDialog()
    return $dlg.Tag
}

<#
.SYNOPSIS
    Opens the official Microsoft Windows 11 download page in the user's
    default browser. Surfaces success/failure in the status bar.
#>
function Open-MicrosoftDownloadPage {
    $url = "https://www.microsoft.com/ar-sa/software-download/windows11"
    try {
        Set-IsoStatus "Opening Microsoft Windows 11 download page..." ([System.Windows.Media.Brushes]::DarkSlateGray)
        Start-Process -FilePath $url | Out-Null
        Set-IsoStatus "Microsoft Windows 11 download page opened." ([System.Windows.Media.Brushes]::DarkGreen)
    } catch {
        Set-IsoStatus "Failed to open Microsoft Windows 11 download page." ([System.Windows.Media.Brushes]::Firebrick)
    }
}

<#
.SYNOPSIS
    Mounts the given ISO with Mount-DiskImage, waits briefly for the
    volume to materialise, and writes the discovered setup.exe path
    into $tbSetupPath. The DiskImage is stored in $script:MountedIso so
    the Unmount button can release it later.

.PARAMETER IsoPath
    Absolute path to a .iso file.
#>
function Mount-IsoAndSetSetupPath {
    param([Parameter(Mandatory)][string]$IsoPath)
    if ([string]::IsNullOrWhiteSpace($IsoPath) -or !(Test-Path $IsoPath)) {
        Set-IsoStatus "ISO file not found." ([System.Windows.Media.Brushes]::Firebrick)
        return
    }
    try {
        Dismount-MountedIso -Silent
        $img = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
        Start-Sleep -Milliseconds 600
        $script:MountedIso = $img
        $vol = $img | Get-Volume
        $drive = $vol.DriveLetter
        if (-not $drive) {
            $drive = (Get-Volume | Where-Object { $_.FileSystemLabel -eq $vol.FileSystemLabel } | Select-Object -First 1).DriveLetter
        }
        if ($drive) {
            $setup = "$drive`:\setup.exe"
            if (Test-Path $setup) {
                $tbSetupPath.Text = $setup
                Set-IsoStatus ("ISO mounted on {0}:. Click 'Unmount' to release." -f $drive) ([System.Windows.Media.Brushes]::DarkGreen)
                if ($btnIsoDismount) { $btnIsoDismount.Visibility = [System.Windows.Visibility]::Visible }
            } else {
                Set-IsoStatus "setup.exe not found on ISO." ([System.Windows.Media.Brushes]::Firebrick)
            }
        } else {
            Set-IsoStatus "Mounted, but drive letter not found." ([System.Windows.Media.Brushes]::Firebrick)
        }
    } catch {
        Set-IsoStatus "Mount failed." ([System.Windows.Media.Brushes]::Firebrick)
    }
}

<#
.SYNOPSIS
    Dismounts the ISO stored in $script:MountedIso, if any, and hides
    the Unmount button. -Silent suppresses the status bar update so the
    function can be called from startup/shutdown code paths.
#>
function Dismount-MountedIso {
    param([switch]$Silent)
    if (-not $script:MountedIso) { return }
    try {
        Dismount-DiskImage -ImagePath $script:MountedIso.ImagePath -ErrorAction Stop
        $script:MountedIso = $null
        if ($btnIsoDismount) { $btnIsoDismount.Visibility = [System.Windows.Visibility]::Collapsed }
        if (-not $Silent) { Set-IsoStatus "ISO dismounted." ([System.Windows.Media.Brushes]::DarkGreen) }
    } catch {
        if (-not $Silent) { Set-IsoStatus "Dismount failed: $($_.Exception.Message)" ([System.Windows.Media.Brushes]::Firebrick) }
    }
}

<#
.SYNOPSIS
    Kicks off Get-DeviceInfo on a dedicated MTA runspace so the WMI/CIM
    calls never block the UI thread, then repaints the UI when they
    complete.

.DESCRIPTION
    The function:
      1. Marks the UI as "loading" and clears the previous device snapshot.
      2. Disposes any prior background PowerShell instance and timer.
      3. Creates a new [powershell] instance bound to an MTA runspace with
         ReuseThread, and passes Get-DeviceInfo's source as a string
         argument (Invoke-Expression materialises it inside the runspace).
      4. Starts a DispatcherTimer that polls the async result every 150 ms.
         When the runspace reports IsCompleted, the result is materialised
         into $script:Device, the timer stops, and the UI is refreshed.
#>
function Start-BackgroundChecks {
    $script:IsLoading = $true
    $script:Device = $null
    Update-DeviceUI
    Update-SetupState

    if ($script:BgTimer) { try { $script:BgTimer.Stop() } catch {} }
    if ($script:BgPs) { try { $script:BgPs.Dispose() } catch {} }

    $script:BgPs = [powershell]::Create()
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = "MTA"
    $runspace.ThreadOptions = "ReuseThread"
    $runspace.Open()
    $script:BgPs.Runspace = $runspace
    $null = $script:BgPs.AddScript({
        param([string]$FuncDef)
        Invoke-Expression $FuncDef
        Get-DeviceInfo
    }).AddArgument(${function:Get-DeviceInfo})
    $script:BgAsync = $script:BgPs.BeginInvoke()

    $script:BgTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:BgTimer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:BgTimer.Add_Tick({
        if ($script:BgAsync -and $script:BgAsync.IsCompleted) {
            $device = $null
            try {
                $result = $script:BgPs.EndInvoke($script:BgAsync)
                if ($result -and $result.Count -gt 0) { $device = $result[0] }
            } catch {}
            try { $script:BgPs.Dispose() } catch {}
            $script:BgPs = $null
            $script:BgAsync = $null
            $script:BgTimer.Stop()
            $script:IsLoading = $false
            $script:Device = $device
            Update-DeviceUI
            Update-SetupState
        }
    })
    $script:BgTimer.Start()
}

#endregion ==============================================================

#region ============================= EVENTS ============================
# ---------------------------------------------------------------------------
# Wire UI events to handlers. Each block is guarded with -not $null checks
# so a missing control (e.g. after a future XAML refactor) does not throw.
# ---------------------------------------------------------------------------

# Re-check button -> re-run device info on the background runspace.
if ($btnRecheck) {
    $btnRecheck.Add_Click({
        Start-BackgroundChecks
    })
}

# Setup path textbox -> revalidate the path and refresh the preview.
# NOTE: We deliberately do NOT call Update-DeviceUI here; that would
# re-trigger the readiness panel on every keystroke and stutter the UI.
$tbSetupPath.Add_TextChanged({
    Update-SetupState
})

# Profile combobox -> rebuild the planned command with the new args.
if ($cbSetupProfile) {
    $cbSetupProfile.Add_SelectionChanged({
        Update-SetupState
    })
}

# Extra-args textbox -> append user switches to the planned command.
if ($tbExtraArgs) {
    $tbExtraArgs.Add_TextChanged({
        Update-SetupState
    })
}

# Choose ISO -> file picker, then mount and auto-fill setup.exe path.
if ($btnIsoBrowse) {
    $btnIsoBrowse.Add_Click({
        try {
            Set-IsoButtonsEnabled -Enabled $false
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = "Select ISO file"
            $dlg.Filter = "ISO (*.iso)|*.iso|All files (*.*)|*.*"
            $dlg.CheckFileExists = $true
            $dlg.Multiselect = $false
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                Set-IsoStatus "Mounting ISO..." ([System.Windows.Media.Brushes]::DarkSlateGray)
                Mount-IsoAndSetSetupPath -IsoPath $dlg.FileName
                Update-SetupState
            } else {
                Set-IsoButtonsEnabled -Enabled $true
            }
        } catch {
            Set-IsoStatus "ISO selection failed." ([System.Windows.Media.Brushes]::Firebrick)
            Set-IsoButtonsEnabled -Enabled $true
        }
    })
}

# Download ISO -> open the Microsoft download page in the default browser.
if ($btnIsoDownload) {
    $btnIsoDownload.Add_Click({
        Open-MicrosoftDownloadPage
    })
}

# Unmount ISO -> release the previously mounted image and hide the button.
if ($btnIsoDismount) {
    $btnIsoDismount.Add_Click({
        Dismount-MountedIso
    })
}

# Clear path -> blank the setup path textbox and reset the status bar.
if ($btnClearSetup) {
    $btnClearSetup.Add_Click({
        $tbSetupPath.Text = ""
        Set-StatusBar "Path cleared." ([System.Windows.Media.Brushes]::DarkSlateGray)
    })
}

# Copy -> push the planned command onto the system clipboard.
if ($btnCopyCmd) {
    $btnCopyCmd.Add_Click({
        try {
            if ($tbCmd -and -not [string]::IsNullOrWhiteSpace($tbCmd.Text)) {
                [System.Windows.Clipboard]::SetText($tbCmd.Text)
                Set-StatusBar "Command copied to clipboard." ([System.Windows.Media.Brushes]::DarkGreen)
            }
        } catch {
            Set-StatusBar "Could not copy the command to the clipboard." ([System.Windows.Media.Brushes]::Firebrick)
        }
    })
}

# Browse -> file picker restricted to setup.exe (with sensible fallbacks).
$btnBrowse.Add_Click({
    try {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = "Select setup.exe"
        $dlg.Filter = "setup.exe (setup.exe)|setup.exe|Executable (*.exe)|*.exe|All files (*.*)|*.*"
        $dlg.CheckFileExists = $true
        $dlg.Multiselect = $false
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $tbSetupPath.Text = $dlg.FileName
        }
    } catch {}
})

<#
   The Start Upgrade flow:
     1. Re-validate the path (defence in depth - the button is already
        disabled when the path is bad, but a focused user could trigger
        this via keyboard just as it becomes invalid).
     2. If not elevated, ask the user whether to RunAs, Continue as-is,
        or Cancel. The script never forces elevation.
     3. Show a final confirmation dialog that displays the exact command
        about to be executed. The "Copy" option copies the command
        without launching it - useful when the operator wants to run it
        manually or audit it first.
     4. Launch setup.exe with the chosen verb and surface the result.
#>
$btnUpgrade.Add_Click({
    $setupPath = $tbSetupPath.Text.Trim()
    if (!(Test-SetupExePath $setupPath)) {
        Set-StatusBar "Select a valid setup.exe file." ([System.Windows.Media.Brushes]::Firebrick)
        return
    }

    $useRunAs = $false
    if (-not $script:IsAdmin) {
        $choice = Show-CustomChoiceDialog -Title "Administrator Required" `
            -Message "Windows Setup usually requires admin rights. Run the upgrade as administrator?" `
            -YesText "Run as admin" -NoText "Continue" -CancelText "Cancel"
        if ($choice -eq "Cancel") { return }
        if ($choice -eq "Yes") { $useRunAs = $true }
    }

    $setupArgs = Get-CombinedSetupArgs
    $fullCmd = ('"{0}" {1}' -f $setupPath, $setupArgs)
    Write-Host "Executing: $fullCmd  (RunAs=$useRunAs)"

    $confirm = Show-CustomChoiceDialog -Title "Confirm Upgrade Launch" `
        -Message ("Windows Setup will now start with the following command:`n`n{0}`n`nContinue?" -f $fullCmd) `
        -YesText "Launch" -NoText "Copy" -CancelText "Cancel"
    if ($confirm -eq "Cancel") { return }
    if ($confirm -eq "No") {
        try { [System.Windows.Clipboard]::SetText($fullCmd); Set-StatusBar "Command copied to clipboard." ([System.Windows.Media.Brushes]::DarkGreen) } catch {}
        return
    }

    try {
        Set-StatusBar "Launching Windows Setup..." ([System.Windows.Media.Brushes]::DarkGreen)
        $null = Start-WindowsSetup -SetupPath $setupPath -SetupArgs $setupArgs -RunAs:$useRunAs
        Set-StatusBar "Windows Setup launched. If nothing appears, check for a UAC or SmartScreen prompt." ([System.Windows.Media.Brushes]::DarkGreen)
    } catch {
        Set-StatusBar (Get-LaunchErrorText $_) ([System.Windows.Media.Brushes]::Firebrick)
    }
})

# Close -> just close the window (the Closed handler performs the cleanup).
$btnClose.Add_Click({ $win.Close() })

# Footer hyperlink -> open the author's LinkedIn in the default browser.
if ($FooterLink) {
    $FooterLink.Add_RequestNavigate({
        param($sender,$e)
        try { Start-Process -FilePath $e.Uri.AbsoluteUri | Out-Null } catch {}
        $e.Handled = $true
    })
}

# Extra-args "learn more" hyperlink -> open the official docs page.
if ($ExtraArgsLink) {
    $ExtraArgsLink.Add_RequestNavigate({
        param($sender,$e)
        try { Start-Process -FilePath $e.Uri.AbsoluteUri | Out-Null } catch {}
        $e.Handled = $true
    })
}

#endregion ==============================================================

#region ============================== ON LOAD ===========================
# ---------------------------------------------------------------------------
# ContentRendered fires once the visual tree is fully realised. This is
# the earliest point at which it is safe to populate dynamic content
# (sidebar session info, device info, profile list, etc.).
# ---------------------------------------------------------------------------
$win.Add_ContentRendered({
    try {
        $win.Activate() | Out-Null
        if ($sessionMachineTxt) { $sessionMachineTxt.Text = $env:COMPUTERNAME }
        if ($sessionUserTxt) {
            $u = if ($env:USERDOMAIN -and $env:USERNAME) { "{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME } else { $env:USERNAME }
            $sessionUserTxt.Text = $u
        }
        if ($sessionElevationTxt -and $sessionElevationPill) {
            $script:IsAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            $sessionElevationTxt.Text = if ($script:IsAdmin) { "Administrator" } else { "Standard" }
            $sessionElevationPill.Background = if ($script:IsAdmin) { (New-Brush "#ECFDF3") } else { (New-Brush "#FEF2F2") }
            $sessionElevationTxt.Foreground = if ($script:IsAdmin) { (New-Brush "#166534") } else { (New-Brush "#991B1B") }
        }
    } catch {}

    Apply-Lang
    Start-BackgroundChecks
})

# ---------------------------------------------------------------------------
# Closed handler: tear down everything we own so the process can exit.
#   * Dismount the ISO (best-effort, silent).
#   * Stop the background dispatcher timer.
#   * Stop and dispose the background PowerShell instance.
#   * Stop the session transcript.
# Environment.Exit is used (not just exit) so we do not return to the
# WPF message loop, which would otherwise keep the host process alive.
# ---------------------------------------------------------------------------
$win.Add_Closed({
    try {
        Dismount-MountedIso -Silent
        if ($script:BgTimer) { $script:BgTimer.Stop() }
        if ($script:BgPs) {
            try { $script:BgPs.Stop() } catch {}
            try { $script:BgPs.Dispose() } catch {}
        }
    } catch {}
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
    [System.Environment]::Exit(0)
})

$null = $win.ShowDialog()
exit 0
#endregion ==============================================================
