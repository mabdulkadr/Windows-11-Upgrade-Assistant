<#!
.SYNOPSIS
    Launches a guided Windows 11 in-place upgrade from local installation media.

.DESCRIPTION
    Windows 11 Upgrade Assistant provides a WPF-based interface to prepare and start
    a Windows 11 upgrade using setup.exe from a mounted ISO, USB media, or another
    local source.

    The script performs basic readiness checks, displays current device and OS details,
    lets the operator choose from predefined setup command profiles, and builds the
    final command line before execution.

    It also supports selecting an ISO file, opening the Microsoft download page,
    copying the planned command, and optionally prompting to relaunch Windows Setup
    with administrator rights when elevation is required.

    Exit codes:
    - Exit 0: The script completed or the UI was closed without a fatal error
    - Exit 1: The script failed or could not continue

.RUN AS
    User context is supported. Administrator rights may be required by Windows Setup
    depending on the selected action and local policy.

.EXAMPLE
    .\Windows-11-Upgrade-Assistant-v1.0.ps1

    Opens the upgrade assistant UI, allows you to select setup.exe or an ISO,
    review the generated command, and start Windows Setup.

.NOTES
    Author  : Mohammad Abdelkader
    Website : momar.tech
    Date    : 2026-02-25
    Version : 1.0
#>
#region ======================== SETTINGS ============================

# Preset setup.exe command templates (selectable in the UI).
# Some profiles use /Product server and /compat IgnoreWarning to relax hardware checks on older devices.
# Use only if approved by your org policy.
# setup.exe /Product server /compat IgnoreWarning /MigrateDrivers All
# setup.exe /auto upgrade /Product server /migratedrivers all /dynamicupdate disable /eula accept /compat ignorewarning /copylogs C:\WinSetup.log
# setup.exe /auto Upgrade /migratedrivers all /ShowOOBE none /Telemetry Disable /dynamicupdate disable /eula accept /quiet /noreboot /compat ignorewarning /copylogs C:\WinSetup.log

$script:SetupProfiles = @(
    [pscustomobject]@{
        Key = "OPT1"
        Args = "/Product server /compat IgnoreWarning /MigrateDrivers All"
        LabelEN = "Option 1 - Basic (Clean Install + driver migration)"
        Desc = "Basic upgrade; Clean Install and migrates drivers."
    }
    [pscustomobject]@{
        Key = "OPT2"
        Args = "/auto upgrade /Product server /compat ignorewarning /migratedrivers all /eula accept /copylogs C:\WinSetup.log"
        LabelEN = "Option 2 - Standard In-Place Upgrade (Keep data/apps + logs)"
        Desc = "Standard in-place upgrade; keeps data/apps and saves logs."
    }
    [pscustomobject]@{
        Key = "OPT3"
        Args = "/auto Upgrade /Product server /compat ignorewarning /migratedrivers all /eula accept /ShowOOBE none /Telemetry Disable /quiet /noreboot /copylogs C:\WinSetup.log"
        LabelEN = "Option 3 - Silent In-Place Upgrade (No reboot + no user prompts)"
        Desc = "Silent in-place upgrade; no prompts and no automatic reboot."
    }
)
$script:DefaultProfileKey = "OPT2"

# Readiness thresholds (informational only)
$MinRamGB  = 8
$MinDiskGB = 30
$RequireACPower = $true
$UiVersion = "1.0"
#endregion ==============================================================

#region ===================== ENVIRONMENT HELPERS ======================
function Ensure-STA {
    $state = $null
    try { $state = [System.Threading.Thread]::CurrentThread.ApartmentState } catch {}
    if ($state -ne "STA") {
        $self = $MyInvocation.MyCommand.Path
        if ([string]::IsNullOrWhiteSpace($self) -or !(Test-Path $self)) { return }
        $arg = "-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File `"$self`""
        $p = Start-Process -FilePath "powershell.exe" -ArgumentList $arg -Wait -PassThru
        exit $p.ExitCode
    }
}
#endregion ==============================================================

#region ============================ DATA ================================
# Collect OS + hardware info for the UI cards.
function Get-DeviceInfo {
    $cv = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue

    $version = $cv.DisplayVersion
    if ([string]::IsNullOrWhiteSpace($version)) { $version = $cv.ReleaseId }
    if ([string]::IsNullOrWhiteSpace($version) -and $os) { $version = $os.Version }

    $build = $cv.CurrentBuild
    $ubr = $cv.UBR
    if (-not $build -and $os) { $build = $os.BuildNumber }
    $buildText = if ($build -and $ubr) { "$build.$ubr" } elseif ($build) { "$build" } else { $null }
    $buildNum = $null
    try { if ($build) { $buildNum = [int]$build } } catch {}

    $installDate = $null
    try { if ($cv.InstallDate) { $installDate = (Get-Date "1970-01-01").AddSeconds([int64]$cv.InstallDate).ToString("yyyy-MM-dd") } } catch {}

    $modelText = ""
    if ($cs) { $modelText = ("{0} / {1}" -f $cs.Manufacturer, $cs.Model).Trim() }

    $productName = if ($cv.ProductName) { $cv.ProductName } elseif ($os) { $os.Caption } else { $null }
    if ($productName -and $buildNum -ge 22000 -and $productName -match "Windows 10") {
        $productName = $productName -replace "Windows 10", "Windows 11"
    }

    [pscustomobject]@{
        ProductName = $productName
        Version     = $version
        Build       = $buildText
        InstallDate = $installDate
        Model       = $modelText
        RamGB       = if ($cs.TotalPhysicalMemory) { [math]::Round($cs.TotalPhysicalMemory/1GB,2) } else { $null }
        FreeC       = if ($disk.FreeSpace) { [math]::Round($disk.FreeSpace/1GB,2) } else { $null }
    }
}

# Check AC power status (best-effort on desktops).
function Get-AcPowerStatus {
    try {
        $b = Get-CimInstance Win32_Battery -ErrorAction Stop
        if (-not $b) { return $true }
        return ($b.BatteryStatus -in 2,6,7,8,9)
    } catch { return $true }
}

# Validate user-selected setup.exe path.
function Test-SetupExePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (!(Test-Path $Path)) { return $false }
    return ([IO.Path]::GetFileName($Path).ToLower() -eq "setup.exe")
}
#endregion ==============================================================

#region ============================= UI ================================
Ensure-STA
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase | Out-Null
Add-Type -AssemblyName System.Windows.Forms | Out-Null

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Windows 11 Upgrade"
        Width="1040" Height="740"
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
                <TextBlock Name="sbAboutBody" Style="{StaticResource SidebarText}" Text="Runs readiness checks, validates setup media, and launches the upgrade safely."/>
              </StackPanel>
            </Border>

            <!-- Footer -->
            <Border BorderBrush="#E6EBF4" BorderThickness="0,1,0,0" Padding="14" Background="#FFFFFF">
              <StackPanel>
                <TextBlock Name="sbFooterOrg" Text="Windows 11 Upgrade" FontSize="13" FontWeight="Bold" Foreground="#1F2D3A"/>
                <TextBlock Name="sbFooterVersion" Text="Version 1.4" FontSize="11" Foreground="#5F6B7A" Margin="0,4,0,0"/>
                <TextBlock FontSize="11" Foreground="#7C8BA1" Margin="0,8,0,0">
                  <Run Text="© 2025 "/>
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
            <TextBlock Name="tHeaderTitle" Text="Windows 11 Upgrade" FontSize="20" FontWeight="Bold" Foreground="#1F2D3A"/>
            <TextBlock Name="tHeaderSub" Text="Quick checklist to upgrade safely." FontSize="13" Foreground="#5F6B7A" Margin="0,6,0,0"/>
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
          <ColumnDefinition Width="1.15*"/>
          <ColumnDefinition Width="0.85*"/>
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
              <Button Grid.Row="0" Grid.Column="2" Name="btnBrowse" Content="Browse..." Height="30" MinWidth="110" Margin="8,0,0,0" Padding="12,0"
                      Style="{StaticResource BtnGreen}" ToolTip="Browse for setup.exe on local media"/>

              <TextBlock Name="tIsoPathLabel" Grid.Row="1" Grid.Column="0" Foreground="#111827" FontWeight="SemiBold"
                         Margin="0,10,8,6" VerticalAlignment="Center"/>
              <StackPanel Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="2" Orientation="Horizontal" Margin="0,8,0,0">
                <Button Name="btnIsoBrowse" Content="Choose ISO" Height="30" MinWidth="110" Padding="12,0"
                        Style="{StaticResource BtnGreen}" ToolTip="Select an ISO file, mount it, and fill setup.exe"/>
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
# Controls
$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$win = [Windows.Markup.XamlReader]::Load($reader)

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
$tRam = $win.FindName("tRam")
$tFree = $win.FindName("tFree")

$tMediaTitle = $win.FindName("tMediaTitle")
$tMediaHelp  = $win.FindName("tMediaHelp")
$tSetupPathLabel = $win.FindName("tSetupPathLabel")
$tbSetupPath = $win.FindName("tbSetupPath")
$btnBrowse   = $win.FindName("btnBrowse")
$tMediaStatus= $win.FindName("tMediaStatus")
$tIsoPathLabel = $win.FindName("tIsoPathLabel")
$btnIsoBrowse = $win.FindName("btnIsoBrowse")
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

# State
$script:SetupOk = $false
$script:IsAdmin = $false
$script:Device = $null
$script:IsLoading = $false
$script:BgPs = $null
$script:BgAsync = $null
$script:BgTimer = $null
$script:SetupPathBorderDefault = $null
$script:SetupPathBgDefault = $null

if ($tbSetupPath) {
    $script:SetupPathBorderDefault = $tbSetupPath.BorderBrush
    $script:SetupPathBgDefault = $tbSetupPath.Background
}
#endregion ==============================================================

#region ============================ BINDINGS ===========================
# Apply UI labels (English only).
function Apply-Lang {
    $win.Title = "Windows 11 Upgrade"
    if ($tHeaderTitle) { $tHeaderTitle.Text = "Welcome" }
    if ($tHeaderSub) { $tHeaderSub.Text = "Perform an in-place upgrade to Windows 11 while preserving files and applications." }
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
    if ($btnRecheck) { $btnRecheck.Content = "Re-check" }
    if ($btnUpgrade) { $btnUpgrade.Content = "Start Upgrade" }
    if ($btnClose) { $btnClose.Content = "Close" }

    if ($lblDeviceTitle) { $lblDeviceTitle.Text = "Device & OS Details" }
    if ($lblHardwareTitle) { $lblHardwareTitle.Text = "Hardware" }
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
    if ($sbAboutBody) { $sbAboutBody.Text = "Perform an in-place upgrade to Windows 11 while preserving files and applications." }
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

# Build profile list for setup presets.
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

# Function: Get-SelectedProfileArgs
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

# Function: Get-SelectedProfileDescription
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

# Function: Update-ProfileDescription
function Update-ProfileDescription {
    if (-not $tCmdProfileDesc) { return }
    $desc = Get-SelectedProfileDescription
    if ([string]::IsNullOrWhiteSpace($desc)) {
        $tCmdProfileDesc.Text = "Select an option to view its details."
    } else {
        $tCmdProfileDesc.Text = $desc
    }
}

# Function: Get-CombinedSetupArgs
function Get-CombinedSetupArgs {
    $baseArgs = Get-SelectedProfileArgs
    $extraArgs = ""
    if ($tbExtraArgs) { $extraArgs = $tbExtraArgs.Text.Trim() }
    if ([string]::IsNullOrWhiteSpace($extraArgs)) { return $baseArgs }
    if ([string]::IsNullOrWhiteSpace($baseArgs)) { return $extraArgs }
    return ($baseArgs + " " + $extraArgs)
}

# Function: Get-SetupWorkingDirectory
function Get-SetupWorkingDirectory {
    param([string]$SetupPath)
    try {
        if ([string]::IsNullOrWhiteSpace($SetupPath)) { return $null }
        if (!(Test-Path $SetupPath)) { return $null }
        return (Split-Path -Parent $SetupPath)
    } catch { return $null }
}

# Function: Get-LaunchErrorText
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

# Function: Start-WindowsSetup
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

# Color helpers for readiness pills.
function New-Brush {
    param([string]$Hex)
    try {
        $c = [Windows.Media.ColorConverter]::ConvertFromString($Hex)
        $b = New-Object Windows.Media.SolidColorBrush $c
        $b.Freeze()
        return $b
    } catch { return [Windows.Media.Brushes]::Transparent }
}
$script:ChkOkBg  = New-Brush "#DCF5E6"
$script:ChkOkFg  = New-Brush "#1F6A3A"
$script:ChkBadBg = New-Brush "#FAD3D3"
$script:ChkBadFg = New-Brush "#8A1C1C"
$script:ChkNeuBg = New-Brush "#EEF2F7"
$script:ChkNeuFg = New-Brush "#374151"

# Format a readiness pill with state color.
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
            $Border.Background = $script:ChkOkBg
            $TextBlock.Foreground = $script:ChkOkFg
        }
        "FAIL" {
            $Border.Background = $script:ChkBadBg
            $TextBlock.Foreground = $script:ChkBadFg
        }
        default {
            $Border.Background = $script:ChkNeuBg
            $TextBlock.Foreground = $script:ChkNeuFg
        }
    }
}

# Update readiness summary + minimums.
function Update-ReadinessUI {
    $d = $script:Device
    if (-not $d) {
        if ($script:IsLoading) {
            $tReadinessSummary.Text = "Checking device readiness..."
            $tReadinessSummary.Foreground = [System.Windows.Media.Brushes]::DarkSlateGray
        } else {
            $tReadinessSummary.Text = "Checks failed. Try as admin or ensure WMI is running."
            $tReadinessSummary.Foreground = [System.Windows.Media.Brushes]::Firebrick
        }
        Set-CheckPill $bChkRam $tChkRam "NEUTRAL" "—"
        Set-CheckPill $bChkDisk $tChkDisk "NEUTRAL" "—"
        Set-CheckPill $bChkAC $tChkAC "NEUTRAL" "—"
        return
    }

    $ramVal = $d.RamGB
    $diskVal = $d.FreeC

    $ramState = "NEUTRAL"
    if ($ramVal -ne $null -and $ramVal -ne "") {
        $ramState = if ([double]$ramVal -ge [double]$MinRamGB) { "OK" } else { "FAIL" }
    }
    $diskState = "NEUTRAL"
    if ($diskVal -ne $null -and $diskVal -ne "") {
        $diskState = if ([double]$diskVal -ge [double]$MinDiskGB) { "OK" } else { "FAIL" }
    }

    $ramText = if ($ramVal -ne $null -and $ramVal -ne "") { "{0} GB (Min {1})" -f $ramVal, $MinRamGB } else { "—" }
    $diskText = if ($diskVal -ne $null -and $diskVal -ne "") { "{0} GB (Min {1})" -f $diskVal, $MinDiskGB } else { "—" }

    Set-CheckPill $bChkRam  $tChkRam  $ramState  $ramText
    Set-CheckPill $bChkDisk $tChkDisk $diskState $diskText

    $acState = "NEUTRAL"
    $acText = "—"
    if ($RequireACPower) {
        $okAC = Get-AcPowerStatus
        $acState = if ($okAC) { "OK" } else { "FAIL" }
        $acText = if ($okAC) { "OK" } else { "Not on AC" }
    }
    Set-CheckPill $bChkAC $tChkAC $acState $acText

    $hasFail = ($ramState -eq "FAIL" -or $diskState -eq "FAIL" -or ($RequireACPower -and $acState -eq "FAIL"))
    if (($ramVal -eq $null -or $ramVal -eq "") -and ($diskVal -eq $null -or $diskVal -eq "")) {
        $tReadinessSummary.Text = "Checks failed. Try as admin or ensure WMI is running."
        $tReadinessSummary.Foreground = [System.Windows.Media.Brushes]::Firebrick
    } elseif ($hasFail) {
        $tReadinessSummary.Text = "One or more requirements are not met."
        $tReadinessSummary.Foreground = [System.Windows.Media.Brushes]::Firebrick
    } else {
        $tReadinessSummary.Text = "This device meets minimum requirements."
        $tReadinessSummary.Foreground = [System.Windows.Media.Brushes]::DarkGreen
    }
}

# Update device details on the right card.
function Update-DeviceUI {
    $d = $script:Device

    if ($tOS) { $tOS.Text = if ($d -and $d.ProductName) { $d.ProductName } else { "—" } }
    if ($tVer) { $tVer.Text = if ($d -and $d.Version) { $d.Version } else { "—" } }
    if ($tBuild) { $tBuild.Text = if ($d -and $d.Build) { $d.Build } else { "—" } }
    if ($tInstall) { $tInstall.Text = if ($d -and $d.InstallDate) { $d.InstallDate } else { "—" } }
    if ($tModel) { $tModel.Text = if ($d -and $d.Model) { $d.Model } else { "—" } }
    if ($tRam) { $tRam.Text = if ($d -and $d.RamGB -ne $null) { [string]$d.RamGB } else { "—" } }
    if ($tFree) { $tFree.Text = if ($d -and $d.FreeC -ne $null) { [string]$d.FreeC } else { "—" } }

    Update-ReadinessUI
}

# Update setup path, command preview, and button state.
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

# Update setup path, command preview, and button state.
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

# Function: Set-IsoStatus
function Set-IsoStatus {
    param(
        [string]$Text,
        [System.Windows.Media.Brush]$Color = $null
    )
    Set-StatusBar -Text $Text -Color $Color
}

# Enable/disable ISO action buttons together.
function Set-IsoButtonsEnabled {
    param([bool]$Enabled)
    if ($btnIsoBrowse) { $btnIsoBrowse.IsEnabled = $Enabled }
    if ($btnIsoDownload) { $btnIsoDownload.IsEnabled = $Enabled }
}

# Custom dialog to match the main UI style.
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
        Width="460" Height="240"
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
        <TextBlock Name="dlgMessage" TextWrapping="Wrap" Foreground="#4B5563"/>
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

# Open the official Microsoft Windows 11 download page.
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

# Mount an ISO and set setup.exe automatically.
function Mount-IsoAndSetSetupPath {
    param([Parameter(Mandatory)][string]$IsoPath)
    if ([string]::IsNullOrWhiteSpace($IsoPath) -or !(Test-Path $IsoPath)) {
        Set-IsoStatus "ISO file not found." ([System.Windows.Media.Brushes]::Firebrick)
        return
    }
    try {
        $img = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
        Start-Sleep -Milliseconds 600
        $vol = $img | Get-Volume
        $drive = $vol.DriveLetter
        if (-not $drive) {
            $drive = (Get-Volume | Where-Object { $_.FileSystemLabel -eq $vol.FileSystemLabel } | Select-Object -First 1).DriveLetter
        }
        if ($drive) {
            $setup = "$drive`:\setup.exe"
            if (Test-Path $setup) {
                $tbSetupPath.Text = $setup
                Set-IsoStatus "ISO mounted." ([System.Windows.Media.Brushes]::DarkGreen)
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

# Run device checks in a background worker and update UI when done.
function Start-BackgroundChecks {
    $script:IsLoading = $true
    $script:Device = $null
    Update-DeviceUI
    Update-SetupState

    if ($script:BgTimer) { try { $script:BgTimer.Stop() } catch {} }
    if ($script:BgPs) { try { $script:BgPs.Dispose() } catch {} }

    $scriptBlockText = @'
$cv = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue

$version = $cv.DisplayVersion
if ([string]::IsNullOrWhiteSpace($version)) { $version = $cv.ReleaseId }
if ([string]::IsNullOrWhiteSpace($version) -and $os) { $version = $os.Version }

$build = $cv.CurrentBuild
$ubr = $cv.UBR
if (-not $build -and $os) { $build = $os.BuildNumber }
$buildText = if ($build -and $ubr) { "$build.$ubr" } elseif ($build) { "$build" } else { $null }
$buildNum = $null
try { if ($build) { $buildNum = [int]$build } } catch {}

$installDate = $null
try { if ($cv.InstallDate) { $installDate = (Get-Date "1970-01-01").AddSeconds([int64]$cv.InstallDate).ToString("yyyy-MM-dd") } } catch {}

$modelText = ""
if ($cs) { $modelText = ("{0} / {1}" -f $cs.Manufacturer, $cs.Model).Trim() }

$productName = if ($cv.ProductName) { $cv.ProductName } elseif ($os) { $os.Caption } else { $null }
if ($productName -and $buildNum -ge 22000 -and $productName -match "Windows 10") {
    $productName = $productName -replace "Windows 10", "Windows 11"
}

[pscustomobject]@{
    ProductName = $productName
    Version     = $version
    Build       = $buildText
    InstallDate = $installDate
    Model       = $modelText
    RamGB       = if ($cs.TotalPhysicalMemory) { [math]::Round($cs.TotalPhysicalMemory/1GB,2) } else { $null }
    FreeC       = if ($disk.FreeSpace) { [math]::Round($disk.FreeSpace/1GB,2) } else { $null }
}
'@

    $script:BgPs = [powershell]::Create()
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = "MTA"
    $runspace.ThreadOptions = "ReuseThread"
    $runspace.Open()
    $script:BgPs.Runspace = $runspace
    $null = $script:BgPs.AddScript($scriptBlockText)
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
if ($btnRecheck) {
    $btnRecheck.Add_Click({
        Start-BackgroundChecks
    })
}

$tbSetupPath.Add_TextChanged({
    Update-SetupState
    Update-DeviceUI
})

if ($cbSetupProfile) {
    $cbSetupProfile.Add_SelectionChanged({
        Update-SetupState
    })
}

if ($tbExtraArgs) {
    $tbExtraArgs.Add_TextChanged({
        Update-SetupState
    })
}

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

if ($btnIsoDownload) {
    $btnIsoDownload.Add_Click({
        Open-MicrosoftDownloadPage
    })
}

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

    try {
        Set-StatusBar "Launching Windows Setup..." ([System.Windows.Media.Brushes]::DarkGreen)
        $setupArgs = Get-CombinedSetupArgs
        $null = Start-WindowsSetup -SetupPath $setupPath -SetupArgs $setupArgs -RunAs:$useRunAs
        Set-StatusBar "Windows Setup launched. If nothing appears, check for a UAC or SmartScreen prompt." ([System.Windows.Media.Brushes]::DarkGreen)
    } catch {
        Set-StatusBar (Get-LaunchErrorText $_) ([System.Windows.Media.Brushes]::Firebrick)
    }
})

$btnClose.Add_Click({ $win.Close() })

# Footer hyperlink
if ($FooterLink) {
    $FooterLink.Add_RequestNavigate({
        param($sender,$e)
        try { Start-Process -FilePath $e.Uri.AbsoluteUri | Out-Null } catch {}
        $e.Handled = $true
    })
}

# Extra arguments link
if ($ExtraArgsLink) {
    $ExtraArgsLink.Add_RequestNavigate({
        param($sender,$e)
        try { Start-Process -FilePath $e.Uri.AbsoluteUri | Out-Null } catch {}
        $e.Handled = $true
    })
}

#endregion ==============================================================

#region ============================== ON LOAD ===========================
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

$win.Add_Closed({
    try {
        if ($script:BgTimer) { $script:BgTimer.Stop() }
        if ($script:BgPs) {
            try { $script:BgPs.Stop() } catch {}
            try { $script:BgPs.Dispose() } catch {}
        }
        # No background download jobs to clean up.
    } catch {}
    [System.Environment]::Exit(0)
})

$null = $win.ShowDialog()
exit 0
#endregion ==============================================================
