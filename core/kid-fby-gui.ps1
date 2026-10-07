#Requires -Version 5.1
<#
  Kid FB.Y - Giao dien tai video Facebook & Long tieng Meta AI
  Cap nhat moi:
  - Bo cai dat day du thu vien sang may moi (1-Click Portable hoac cai tung cong cu).
  - Ngay thang xuat video to ro rang, noi bat.
  - Bo loc video theo ngay ro rang (Tat ca, Hom nay, Hom qua, 7 ngay qua, Ngay cu the).
  - Nut luu noi bo danh dau "Da dang TikTok" (luu persistent JSON).
  - Bo loc video theo trang thai TikTok (Tat ca, Chua dang, Da dang).
  - Chuyen tab Terminal Logs xuong cuoi cung: Tien trinh -> Kho Video -> Bo Thu Vien -> Terminal Logs.
  - Toi uu video player mui tua sieu muot, loai bo giut lag.
  Chay Kid-FB.Y.exe de khoi dong.
#>
param([switch]$SelfTest)

# SelfTest phai that bai ngay khi co loi khoi tao, khong bao BOOT_OK gia.
if ($SelfTest) { $ErrorActionPreference = 'Stop' }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$scriptPath = if ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } elseif ($PSScriptRoot) { Join-Path $PSScriptRoot 'kid-fby-gui.ps1' } else { (Get-Location).Path }
$scriptDir = Split-Path $scriptPath -Parent
if (-not (Test-Path (Join-Path $scriptDir 'kid-fby.ps1'))) {
    if (Test-Path (Join-Path $scriptDir 'core\kid-fby.ps1')) {
        $scriptDir = Join-Path $scriptDir 'core'
    }
}
$engine = Join-Path $scriptDir 'kid-fby.ps1'
$linkHelper = Join-Path $scriptDir 'facebook-links.ps1'
if (Test-Path -LiteralPath $linkHelper) { . $linkHelper }
if (-not (Test-Path $engine)) {
    $cand = Join-Path (Split-Path $scriptDir -Parent) 'core\kid-fby.ps1'
    if (Test-Path $cand) { $engine = $cand }
}
$root = if ((Split-Path $scriptDir -Leaf) -in @('core','src','app')) {
    Split-Path $scriptDir -Parent
} else {
    $scriptDir
}
$script:whisperLanguageHelperAvailable = $false
$whisperLanguageHelper = Join-Path $scriptDir 'whisper-language.ps1'
if (Test-Path -LiteralPath $whisperLanguageHelper) {
    try {
        . $whisperLanguageHelper
        $script:whisperLanguageHelperAvailable = [bool](Get-Command 'Get-WhisperPaths' -ErrorAction SilentlyContinue)
    } catch { $script:whisperLanguageHelperAvailable = $false }
}
$script:verLocal = '1.0.0'
try {
    $vf = Join-Path $scriptDir 'version.txt'
    if (Test-Path $vf) { $script:verLocal = (Get-Content $vf -Raw).Trim() }
} catch { }

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:shell="clr-namespace:System.Windows.Shell;assembly=PresentationFramework"
        Title="Kid FB.Y"
        Height="900" Width="1380" MinHeight="760" MinWidth="1120"
        WindowStartupLocation="CenterScreen" Background="#0A0E17"
        FontFamily="Segoe UI" FontSize="13" Foreground="#F0F4F8">
  <shell:WindowChrome.WindowChrome>
    <shell:WindowChrome CaptionHeight="46" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0"/>
  </shell:WindowChrome.WindowChrome>

  <Window.Resources>
    <!-- Base Button -->
    <Style TargetType="Button">
      <Setter Property="Background" Value="#151C2A"/>
      <Setter Property="Foreground" Value="#D8E2EC"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush" Value="#253248"/>
      <Setter Property="Padding" Value="10,5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="border" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="border" Property="Background" Value="#222D42"/>
                <Setter TargetName="border" Property="BorderBrush" Value="#38BDF8"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="border" Property="Background" Value="#0E1420"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="border" Property="Opacity" Value="0.38"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Danger Button -->
    <Style x:Key="BtnDanger" TargetType="Button">
      <Setter Property="Background" Value="#241418"/>
      <Setter Property="Foreground" Value="#F87171"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush" Value="#7F1D1D"/>
      <Setter Property="Padding" Value="10,5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#38181F"/>
                <Setter TargetName="b" Property="BorderBrush" Value="#EF4444"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="b" Property="Background" Value="#1C0D11"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Window Titlebar Buttons -->
    <Style x:Key="WinBtn" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#94A3B8"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#222B3D"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="b" Property="Background" Value="#151C2A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="WinBtnClose" TargetType="Button" BasedOn="{StaticResource WinBtn}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#E11D48"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="b" Property="Background" Value="#BE123C"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- TextBox -->
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#0D121D"/>
      <Setter Property="Foreground" Value="#F1F5F9"/>
      <Setter Property="CaretBrush" Value="#38BDF8"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush" Value="#222D42"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="border" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ScrollViewer x:Name="PART_ContentHost" Focusable="False" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsFocused" Value="True">
                <Setter TargetName="border" Property="BorderBrush" Value="#0284C7"/>
                <Setter TargetName="border" Property="Background" Value="#101726"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="border" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="Slider">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>

    <!-- Dark ComboBox Styles -->
    <Style x:Key="LogoSlider" TargetType="Slider" BasedOn="{StaticResource {x:Type Slider}}">
      <Setter Property="Height" Value="20"/>
      <Setter Property="IsMoveToPointEnabled" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid x:Name="SliderRoot" VerticalAlignment="Center">
              <Track x:Name="PART_Track" Minimum="{TemplateBinding Minimum}" Maximum="{TemplateBinding Maximum}"
                     Value="{Binding Value,RelativeSource={RelativeSource TemplatedParent},Mode=TwoWay}" IsDirectionReversed="{TemplateBinding IsDirectionReversed}">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="Slider.DecreaseLarge" Focusable="False">
                    <RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Background="#38BDF8" Height="4" CornerRadius="2"/></ControlTemplate></RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="Slider.IncreaseLarge" Focusable="False">
                    <RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Background="#334155" Height="4" CornerRadius="2"/></ControlTemplate></RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Width="12" Height="12">
                    <Thumb.Template><ControlTemplate TargetType="Thumb"><Ellipse Fill="#E0F2FE" Stroke="#38BDF8" StrokeThickness="2"/></ControlTemplate></Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
            <ControlTemplate.Triggers><Trigger Property="IsEnabled" Value="False"><Setter TargetName="SliderRoot" Property="Opacity" Value="0.4"/></Trigger></ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <ControlTemplate x:Key="ComboBoxToggleButton" TargetType="ToggleButton">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition />
          <ColumnDefinition Width="24" />
        </Grid.ColumnDefinitions>
        <Border x:Name="Border" Grid.ColumnSpan="2" CornerRadius="6"
                Background="#101726" BorderBrush="#253248" BorderThickness="1" />
        <Path x:Name="Arrow" Grid.Column="1" HorizontalAlignment="Center" VerticalAlignment="Center"
              Data="M 0 0 L 4 4 L 8 0 Z" Fill="#60A5FA" />
      </Grid>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter TargetName="Border" Property="BorderBrush" Value="#38BDF8" />
          <Setter TargetName="Border" Property="Background" Value="#172236" />
        </Trigger>
        <Trigger Property="IsChecked" Value="True">
          <Setter TargetName="Border" Property="BorderBrush" Value="#0284C7" />
          <Setter TargetName="Border" Property="Background" Value="#0B1220" />
        </Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>

    <Style TargetType="ComboBoxItem">
      <Setter Property="Background" Value="#0F172A"/>
      <Setter Property="Foreground" Value="#CBD5E1"/>
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}" Margin="1,1">
              <ContentPresenter />
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#1E293B"/>
                <Setter Property="Foreground" Value="#38BDF8"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="b" Property="Background" Value="#0284C7"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="#F1F5F9"/>
      <Setter Property="Background" Value="#101726"/>
      <Setter Property="BorderBrush" Value="#253248"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="ToggleButton" Template="{StaticResource ComboBoxToggleButton}"
                            Focusable="False" IsChecked="{Binding Path=IsDropDownOpen,Mode=TwoWay,RelativeSource={RelativeSource TemplatedParent}}"
                            ClickMode="Press"/>
              <ContentPresenter x:Name="ContentSite" IsHitTestVisible="False" Margin="10,3,24,3"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"
                                VerticalAlignment="Center" HorizontalAlignment="Left" />
              <Popup x:Name="PART_Popup" AllowsTransparency="True" Focusable="False"
                     IsOpen="{TemplateBinding IsDropDownOpen}"
                     Placement="Bottom" PopupAnimation="Slide">
                <Border x:Name="DropDownBorder" Background="#0C101B" BorderBrush="#2A3854" BorderThickness="1"
                        CornerRadius="7" MinWidth="180" MaxHeight="260"
                        Margin="0,3,0,0" Padding="4">
                  <ScrollViewer SnapsToDevicePixels="True" VerticalScrollBarVisibility="Auto">
                    <ItemsPresenter SnapsToDevicePixels="{TemplateBinding SnapsToDevicePixels}" KeyboardNavigation.DirectionalNavigation="Contained"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="0">
    <Grid.RowDefinitions>
      <RowDefinition Height="46"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- ROW 0: INTEGRATED CHROME TITLEBAR & HUD -->
    <Border Grid.Row="0" Background="#0C101A" BorderBrush="#1B2334" BorderThickness="0,0,0,1">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <!-- Brand Identity -->
        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="14,0,0,0">
          <Border Width="28" Height="28" CornerRadius="7" Margin="0,0,10,0">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#0066FF" Offset="0.0"/>
                <GradientStop Color="#00C2FF" Offset="1.0"/>
              </LinearGradientBrush>
            </Border.Background>
            <TextBlock Text="⚡" FontSize="15" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock Text="Kid FB.Y" Foreground="#FFFFFF" FontSize="15" FontWeight="Bold" VerticalAlignment="Center"/>
          <Border Background="#131F33" BorderBrush="#1E3A5F" BorderThickness="1" CornerRadius="4" Padding="6,2" Margin="8,0,0,0" VerticalAlignment="Center">
            <TextBlock x:Name="TxtAppVersion" Text="v1.0.0" Foreground="#38BDF8" FontSize="10.5" FontWeight="SemiBold"/>
          </Border>
        </StackPanel>

        <!-- Space for dragging window -->
        <Grid Grid.Column="1" Background="Transparent"/>

        <!-- Real-time HUD Chips -->
        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,12,0">
          <Border Background="#131A28" BorderBrush="#233048" BorderThickness="1" CornerRadius="12" Padding="10,4" Margin="0,0,8,0">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="● " Foreground="#10B981" FontSize="10" VerticalAlignment="Center"/>
              <TextBlock Text="LDPlayer 9 (Android 14)" Foreground="#CBD5E1" FontSize="11" FontWeight="Medium"/>
            </StackPanel>
          </Border>
          <Border Background="#131A28" BorderBrush="#233048" BorderThickness="1" CornerRadius="12" Padding="10,4" Margin="0,0,8,0">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="● " Foreground="#38BDF8" FontSize="10" VerticalAlignment="Center"/>
              <TextBlock Text="scrcpy Direct Socket" Foreground="#CBD5E1" FontSize="11" FontWeight="Medium"/>
            </StackPanel>
          </Border>
          <Border Background="#131A28" BorderBrush="#233048" BorderThickness="1" CornerRadius="12" Padding="10,4">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="● " Foreground="#A855F7" FontSize="10" VerticalAlignment="Center"/>
              <TextBlock Text="H.264 Universal Lossless" Foreground="#CBD5E1" FontSize="11" FontWeight="Medium"/>
            </StackPanel>
          </Border>
        </StackPanel>

        <!-- Window Minimize/Maximize/Close Buttons -->
        <StackPanel Grid.Column="3" Orientation="Horizontal" shell:WindowChrome.IsHitTestVisibleInChrome="True">
          <Button x:Name="BtnWinMin" Style="{StaticResource WinBtn}" Content="─" FontSize="11"/>
          <Button x:Name="BtnWinMax" Style="{StaticResource WinBtn}" Content="☐" FontSize="12"/>
          <Button x:Name="BtnWinClose" Style="{StaticResource WinBtnClose}" Content="✕" FontSize="12"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- ROW 1: INPUT DECK -->
    <Border Grid.Row="1" Background="#111724" BorderBrush="#1E293E" BorderThickness="1" CornerRadius="10" Margin="16,10,16,6" Padding="16,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <!-- Left inputs -->
        <StackPanel Grid.Column="0" Margin="0,0,16,0">
          <Grid Margin="0,0,0,6">
            <TextBlock Text="DANH SÁCH LIÊN KẾT FACEBOOK (REEL / VIDEO)" FontWeight="Bold" FontSize="11" Foreground="#94A3B8"/>
            <TextBlock x:Name="TxtQueueCount" Text="Chưa có liên kết nào" HorizontalAlignment="Right" Foreground="#64748B" FontSize="11"/>
          </Grid>
          <TextBox x:Name="TxtLinks" Height="60" AcceptsReturn="True" TextWrapping="NoWrap"
                   VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12.5"/>

          <Grid Margin="0,8,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="Thư mục xuất:" VerticalAlignment="Center" Foreground="#94A3B8" FontWeight="SemiBold" Margin="0,0,10,0"/>
            <TextBox   Grid.Column="1" x:Name="TxtOut" VerticalContentAlignment="Center"/>
            <Button    Grid.Column="2" x:Name="BtnPick" Content="📂 Chọn..." Margin="8,0,0,0" Padding="12,6"/>
            <Button    Grid.Column="3" x:Name="BtnOpenOut" Content="↗ Mở" Margin="6,0,0,0" Padding="10,6"/>
          </Grid>
          <CheckBox x:Name="ChkLanguage" Content="Nhận diện tiếng Việt bằng tiny" IsChecked="True"
                    ToolTip="Thử tối đa 2 đoạn audio ngắn; kết quả ước tính, vẫn nghe nghiệm thu."
                    Foreground="#CBD5E1" FontSize="11" Margin="0,7,0,0"/>
          <Border Background="#0C1320" BorderBrush="#223149" BorderThickness="1" CornerRadius="8" Padding="10" Margin="0,7,0,0">
            <StackPanel>
              <CheckBox x:Name="ChkWatermark" Content="Chèn logo vào video" IsChecked="True" Foreground="#E2E8F0" FontWeight="SemiBold" FontSize="12"/>
              <Grid Margin="0,8,0,0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="56"/><ColumnDefinition Width="*"/><ColumnDefinition Width="112"/></Grid.ColumnDefinitions>
                <Border Width="46" Height="46" Background="#172235" CornerRadius="6" BorderBrush="#2C3D55" BorderThickness="1" HorizontalAlignment="Left" VerticalAlignment="Center" Padding="3">
                  <Image x:Name="ImgLogoPreview" Stretch="Uniform"/>
                </Border>
                <StackPanel Grid.Column="1" Margin="0,0,8,0">
                  <TextBlock x:Name="TxtLogoName" Text="Đang dùng: Logo Kid" Foreground="#6EE7B7" FontWeight="SemiBold" FontSize="11.5" TextTrimming="CharacterEllipsis" Margin="0,0,0,4"/>
                  <Grid>
                    <TextBox x:Name="TxtLogoPath" Height="32" Padding="8,3" FontSize="11" IsReadOnly="True" VerticalContentAlignment="Center" ToolTip="Đường dẫn đầy đủ của logo PNG đã chọn."/>
                    <TextBlock x:Name="TxtLogoDefaultHint" Text="Logo Kid mặc định · ảnh số 5" Foreground="#94A3B8" FontSize="11" Margin="9,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
                  </Grid>
                </StackPanel>
                <StackPanel Grid.Column="2">
                  <Button x:Name="BtnPickLogo" Content="Chọn ảnh PNG…" Height="27" Padding="8,3" FontSize="11" Margin="0,0,0,4"/>
                  <Button x:Name="BtnDefaultLogo" Content="✓ Logo Kid" Height="27" Padding="8,3" FontSize="11" Background="#133A32" BorderBrush="#34D399" Foreground="#6EE7B7"/>
                </StackPanel>
              </Grid>
              <WrapPanel Margin="0,8,0,0">
                <StackPanel Orientation="Horizontal" Margin="0,0,16,0" VerticalAlignment="Center">
                  <TextBlock Text="Kích thước" Foreground="#94A3B8" FontSize="11" VerticalAlignment="Center" Margin="0,0,6,0"/>
                  <Slider x:Name="SldLogoSize" Style="{StaticResource LogoSlider}" Minimum="5" Maximum="60" Value="30" TickFrequency="1" IsSnapToTickEnabled="True" Width="110" VerticalAlignment="Center"/>
                  <TextBlock x:Name="TxtLogoSize" Text="30%" Foreground="#7DD3FC" FontWeight="SemiBold" FontSize="11" Width="35" VerticalAlignment="Center" Margin="6,0,0,0" ToolTip="Phần trăm chiều rộng video; ảnh giữ nguyên tỷ lệ."/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                  <TextBlock Text="Độ mờ" Foreground="#94A3B8" FontSize="11" VerticalAlignment="Center" Margin="0,0,6,0"/>
                  <Slider x:Name="SldLogoFade" Style="{StaticResource LogoSlider}" Minimum="0" Maximum="95" Value="60" TickFrequency="1" IsSnapToTickEnabled="True" Width="110" VerticalAlignment="Center"/>
                  <TextBlock x:Name="TxtLogoFade" Text="60%" Foreground="#7DD3FC" FontWeight="SemiBold" FontSize="11" Width="35" VerticalAlignment="Center" Margin="6,0,0,0"/>
                </StackPanel>
              </WrapPanel>
              <WrapPanel Margin="0,8,0,0" VerticalAlignment="Center">
                <TextBlock Text="Chuyển động" Foreground="#94A3B8" FontSize="11" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <ComboBox x:Name="CmbLogoMode" Width="152" Height="32" SelectedIndex="0" VerticalContentAlignment="Center" Margin="0,0,14,0">
                  <ComboBoxItem Content="Tự do · di chuyển"/>
                  <ComboBoxItem Content="Cố định · đứng yên"/>
                </ComboBox>
                <StackPanel x:Name="PanelLogoPosition" Orientation="Horizontal" Visibility="Collapsed">
                  <TextBlock Text="Vị trí" Foreground="#94A3B8" FontSize="11" VerticalAlignment="Center" Margin="0,0,8,0"/>
                  <ComboBox x:Name="CmbLogoPosition" Width="125" Height="32" SelectedIndex="3" VerticalContentAlignment="Center" IsEnabled="False">
                    <ComboBoxItem Content="Trên trái"/><ComboBoxItem Content="Trên phải"/>
                    <ComboBoxItem Content="Dưới trái"/><ComboBoxItem Content="Dưới phải"/><ComboBoxItem Content="Giữa"/>
                  </ComboBox>
                </StackPanel>
              </WrapPanel>
            </StackPanel>
          </Border>
        </StackPanel>

        <!-- Right actions -->
        <StackPanel Grid.Column="1" VerticalAlignment="Center">
          <Button x:Name="BtnStart" Height="48" MinWidth="220" FontWeight="Bold" FontSize="14" Foreground="#FFFFFF" BorderThickness="1" BorderBrush="#38BDF8">
            <Button.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#0062E0" Offset="0.0"/>
                <GradientStop Color="#0099FF" Offset="1.0"/>
              </LinearGradientBrush>
            </Button.Background>
            <Button.Effect>
              <DropShadowEffect Color="#0077FE" BlurRadius="18" ShadowDepth="0" Opacity="0.45"/>
            </Button.Effect>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
              <TextBlock Text="⚡ " FontSize="16" VerticalAlignment="Center"/>
              <TextBlock Text="BẮT ĐẦU TỰ ĐỘNG HÓA" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>

          <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
            <Button x:Name="BtnCheck" Content="🔍 Kiểm tra máy" MinWidth="105" Margin="0,0,6,0"/>
            <Button x:Name="BtnOpenTools" Content="📦 Cài thư viện" MinWidth="95" Margin="0,0,6,0"
                    Background="#162030" BorderBrush="#3B82F6" Foreground="#60A5FA"/>
            <Button x:Name="BtnStop"  Content="⏹ Dừng" IsEnabled="False" MinWidth="75" Margin="0,0,6,0" Style="{StaticResource BtnDanger}"/>
            <Button x:Name="BtnUpdate" Content="🔄 Cập nhật" MinWidth="90" ToolTip="Kiểm tra bản mới trên GitHub"
                    Background="#132A1F" BorderBrush="#10B981" Foreground="#34D399"/>
          </StackPanel>
        </StackPanel>
      </Grid>
    </Border>

    <!-- ROW 2: WORKSPACE (STAGE PIPELINE / GALLERY / TOOLS / LOGS vs STUDIO VIEWPORT) -->
    <Grid Grid.Row="2" Margin="16,4,16,6">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="1.2*"/>
        <ColumnDefinition Width="8"/>
        <ColumnDefinition Width="1*"/>
      </Grid.ColumnDefinitions>

      <!-- LEFT: WORKFLOW & PROGRESS / GALLERY / TOOLS / LOGS -->
      <Border Grid.Column="0" Background="#111724" BorderBrush="#1E293E" BorderThickness="1" CornerRadius="10" Padding="14,12">
        <DockPanel>
          <!-- Top bar with tabs: Tien trinh -> Kho Video -> Bo Thu Vien -> Terminal Logs (CUOI CUNG) -->
          <Grid DockPanel.Dock="Top" Margin="0,0,0,8">
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
              <Button x:Name="BtnTabPipeline" Content="📊 Tiến trình" Padding="10,5" Margin="0,0,5,0"
                      Background="#1E293E" Foreground="#38BDF8" BorderBrush="#3B82F6"/>
              <Button x:Name="BtnTabGallery" Content="📁 Kho Video Đã Xuất" Padding="10,5" Margin="0,0,5,0"
                      Background="Transparent" Foreground="#94A3B8" BorderBrush="#253248"/>
              <Button x:Name="BtnTabTools" Content="📦 Bộ Thư Viện" Padding="10,5" Margin="0,0,5,0"
                      Background="Transparent" Foreground="#94A3B8" BorderBrush="#253248"/>
              <Button x:Name="BtnTabLogs" Content="💻 Terminal Logs" Padding="10,5"
                      Background="Transparent" Foreground="#94A3B8" BorderBrush="#253248"/>
            </StackPanel>
            <TextBlock x:Name="TxtStat" HorizontalAlignment="Right" VerticalAlignment="Center" Text="Chưa kiểm tra máy"
                       Foreground="#7E8B9F" FontSize="12" FontWeight="SemiBold"/>
          </Grid>

          <!-- Fluid Progress Bar -->
          <ProgressBar x:Name="Bar" DockPanel.Dock="Top" Height="4" IsIndeterminate="True"
                       Visibility="Collapsed" Margin="0,0,0,8" Foreground="#0099FF" Background="#1A2234" BorderThickness="0"/>

          <!-- Content View 1: Visual Pipeline Cards -->
          <ScrollViewer x:Name="ViewPipeline" VerticalScrollBarVisibility="Auto">
            <StackPanel Margin="0,2,4,0">
              <!-- Stage 1 -->
              <Border Background="#0C101A" BorderBrush="#1C2436" BorderThickness="1" CornerRadius="8" Padding="12,9" Margin="0,0,0,6">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="34"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Grid.Column="0" Text="📱" FontSize="18" VerticalAlignment="Center"/>
                  <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="6,0,0,0">
                    <TextBlock Text="1. Khởi tạo &amp; Thiết bị LDPlayer" FontWeight="SemiBold" Foreground="#F1F5F9" FontSize="12.5"/>
                    <TextBlock x:Name="TxtStage1Info" Text="Android 14 · ADB Online · scrcpy HAL Sẵn sàng" Foreground="#64748B" FontSize="11" Margin="0,2,0,0"/>
                  </StackPanel>
                  <Border Grid.Column="2" x:Name="BadgeStage1" Background="#162030" BorderBrush="#25354F" BorderThickness="1" CornerRadius="10" Padding="8,2" VerticalAlignment="Center">
                    <TextBlock x:Name="TxtStage1Status" Text="Sẵn sàng ✔" Foreground="#10B981" FontSize="11" FontWeight="Bold"/>
                  </Border>
                </Grid>
              </Border>

              <!-- Stage 2 -->
              <Border Background="#0C101A" BorderBrush="#1C2436" BorderThickness="1" CornerRadius="8" Padding="12,9" Margin="0,0,0,6">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="34"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Grid.Column="0" Text="📥" FontSize="18" VerticalAlignment="Center"/>
                  <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="6,0,0,0">
                    <TextBlock Text="2. Tải Video Gốc (Max Quality)" FontWeight="SemiBold" Foreground="#F1F5F9" FontSize="12.5"/>
                    <TextBlock x:Name="TxtStage2Info" Text="Tự động bắt 4K / 2K / 1080p Ultra HD · Bitrate cao nhất" Foreground="#64748B" FontSize="11" Margin="0,2,0,0"/>
                  </StackPanel>
                  <Border Grid.Column="2" x:Name="BadgeStage2" Background="#161B26" BorderBrush="#252D3D" BorderThickness="1" CornerRadius="10" Padding="8,2" VerticalAlignment="Center">
                    <TextBlock x:Name="TxtStage2Status" Text="Chờ thực hiện" Foreground="#64748B" FontSize="11" FontWeight="Bold"/>
                  </Border>
                </Grid>
              </Border>

              <!-- Stage 3 -->
              <Border Background="#0C101A" BorderBrush="#1C2436" BorderThickness="1" CornerRadius="8" Padding="12,9" Margin="0,0,0,6">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="34"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Grid.Column="0" Text="🌐" FontSize="18" VerticalAlignment="Center"/>
                  <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="6,0,0,0">
                    <TextBlock Text="3. Kích hoạt Lồng tiếng Meta AI" FontWeight="SemiBold" Foreground="#F1F5F9" FontSize="12.5"/>
                    <TextBlock x:Name="TxtStage3Info" Text="Nhận diện giao diện Reel · Tự động chọn Tiếng Việt (Ưu tiên)" Foreground="#64748B" FontSize="11" Margin="0,2,0,0"/>
                  </StackPanel>
                  <Border Grid.Column="2" x:Name="BadgeStage3" Background="#161B26" BorderBrush="#252D3D" BorderThickness="1" CornerRadius="10" Padding="8,2" VerticalAlignment="Center">
                    <TextBlock x:Name="TxtStage3Status" Text="Chờ thực hiện" Foreground="#64748B" FontSize="11" FontWeight="Bold"/>
                  </Border>
                </Grid>
              </Border>

              <!-- Stage 4 -->
              <Border Background="#0C101A" BorderBrush="#1C2436" BorderThickness="1" CornerRadius="8" Padding="12,9" Margin="0,0,0,6">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="34"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Grid.Column="0" Text="🎙" FontSize="18" VerticalAlignment="Center"/>
                  <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="6,0,0,0">
                    <TextBlock Text="4. Thu âm Kỹ thuật số Bit-Perfect" FontWeight="SemiBold" Foreground="#F1F5F9" FontSize="12.5"/>
                    <TextBlock x:Name="TxtStage4Info" Text="Thu từ Android HAL PCM · Độc lập 100% PC · Buffer +10s" Foreground="#64748B" FontSize="11" Margin="0,2,0,0"/>
                  </StackPanel>
                  <Border Grid.Column="2" x:Name="BadgeStage4" Background="#161B26" BorderBrush="#252D3D" BorderThickness="1" CornerRadius="10" Padding="8,2" VerticalAlignment="Center">
                    <TextBlock x:Name="TxtStage4Status" Text="Chờ thực hiện" Foreground="#64748B" FontSize="11" FontWeight="Bold"/>
                  </Border>
                </Grid>
              </Border>

              <!-- Stage 5 -->
              <Border Background="#0C101A" BorderBrush="#1C2436" BorderThickness="1" CornerRadius="8" Padding="12,9">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="34"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Grid.Column="0" Text="⚡" FontSize="18" VerticalAlignment="Center"/>
                  <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="6,0,0,0">
                    <TextBlock Text="5. Căn chỉnh Giây 0 &amp; Xuất bản MP4" FontWeight="SemiBold" Foreground="#F1F5F9" FontSize="12.5"/>
                    <TextBlock x:Name="TxtStage5Info" Text="Khớp thời lượng mili-giây · Chuẩn hóa -16 LUFS · Faststart" Foreground="#64748B" FontSize="11" Margin="0,2,0,0"/>
                  </StackPanel>
                  <Border Grid.Column="2" x:Name="BadgeStage5" Background="#161B26" BorderBrush="#252D3D" BorderThickness="1" CornerRadius="10" Padding="8,2" VerticalAlignment="Center">
                    <TextBlock x:Name="TxtStage5Status" Text="Chờ thực hiện" Foreground="#64748B" FontSize="11" FontWeight="Bold"/>
                  </Border>
                </Grid>
              </Border>
            </StackPanel>
          </ScrollViewer>

          <!-- Content View 2: Video Gallery / History (Toggled) -->
          <Border x:Name="ViewGallery" Visibility="Collapsed" Background="#070A0F" BorderBrush="#182030" BorderThickness="1" CornerRadius="7" Padding="10">
            <DockPanel>
              <!-- Filter Deck -->
              <StackPanel DockPanel.Dock="Top" Margin="0,0,0,8">
                <!-- Row 1: Header + Refresh -->
                <Grid Margin="0,0,0,6">
                  <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="🎬 TÁC PHẨM ĐÃ XUẤT: " FontWeight="Bold" Foreground="#94A3B8" FontSize="11"/>
                    <TextBlock x:Name="TxtGalleryCount" Text="0 video" Foreground="#38BDF8" FontWeight="Bold" FontSize="11"/>
                  </StackPanel>
                  <Button x:Name="BtnRefreshGallery" Content="🔄 Làm mới" HorizontalAlignment="Right" Padding="8,3" FontSize="11"/>
                </Grid>

                <!-- Row 2: Bộ lọc ngày rõ ràng -->
                <WrapPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,0,6">
                  <TextBlock Text="LỌC NGÀY:" Foreground="#64748B" FontSize="11" FontWeight="Bold" VerticalAlignment="Center" Margin="0,0,6,0"/>
                  <Button x:Name="BtnFilterAllDate" Content="🔘 Tất cả" Padding="7,2" Margin="0,0,4,2" FontSize="11"
                          Background="#1E293B" Foreground="#38BDF8" BorderBrush="#3B82F6"/>
                  <Button x:Name="BtnFilterToday" Content="📅 Hôm nay" Padding="7,2" Margin="0,0,4,2" FontSize="11"
                          Background="#121824" Foreground="#94A3B8" BorderBrush="#253248"/>
                  <Button x:Name="BtnFilterYesterday" Content="📅 Hôm qua" Padding="7,2" Margin="0,0,4,2" FontSize="11"
                          Background="#121824" Foreground="#94A3B8" BorderBrush="#253248"/>
                  <Button x:Name="BtnFilter7Days" Content="📅 7 ngày qua" Padding="7,2" Margin="0,0,8,2" FontSize="11"
                          Background="#121824" Foreground="#94A3B8" BorderBrush="#253248"/>
                  
                  <ComboBox x:Name="CmbFilterSpecificDate" Width="175" Height="25" FontSize="11" Margin="0,0,8,2"
                            ToolTip="Chọn ngày xuất cụ thể để lọc danh sách"/>
                </WrapPanel>

                <!-- Row 3: Bộ lọc trạng thái TikTok -->
                <WrapPanel Orientation="Horizontal" VerticalAlignment="Center">
                  <TextBlock Text="TIKTOK:" Foreground="#64748B" FontSize="11" FontWeight="Bold" VerticalAlignment="Center" Margin="0,0,6,0"/>
                  <Button x:Name="BtnFilterTikTokAll" Content="🔘 Tất cả" Padding="7,2" Margin="0,0,4,2" FontSize="11"
                          Background="#1E293B" Foreground="#38BDF8" BorderBrush="#3B82F6"/>
                  <Button x:Name="BtnFilterTikTokUnposted" Content="⏳ Chưa đăng TikTok" Padding="7,2" Margin="0,0,4,2" FontSize="11"
                          Background="#121824" Foreground="#FBBF24" BorderBrush="#253248"/>
                  <Button x:Name="BtnFilterTikTokPosted" Content="✅ Đã đăng TikTok" Padding="7,2" Margin="0,0,4,2" FontSize="11"
                          Background="#121824" Foreground="#34D399" BorderBrush="#253248"/>
                </WrapPanel>
              </StackPanel>

              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel x:Name="GalleryPanel" Margin="0,0,4,0"/>
              </ScrollViewer>
            </DockPanel>
          </Border>

          <!-- Content View 3: Tools & Setup Manager (Toggled) -->
          <Border x:Name="ViewTools" Visibility="Collapsed" Background="#070A0F" BorderBrush="#182030" BorderThickness="1" CornerRadius="7" Padding="12">
            <DockPanel>
              <!-- Header & 1-Click All Installer -->
              <StackPanel DockPanel.Dock="Top" Margin="0,0,0,10">
                <Grid Margin="0,0,0,8">
                  <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="📦 TRUNG TÂM QUẢN LÝ BỘ THƯ VIỆN &amp; CÔNG CỤ" FontWeight="Bold" Foreground="#F1F5F9" FontSize="12.5"/>
                  </StackPanel>
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                    <Button x:Name="BtnCheckTools" Content="🔍 Kiểm tra lại" Padding="8,4" Margin="0,0,6,0" FontSize="11"/>
                    <Button x:Name="BtnOpenUninstall" Content="🗑 Gỡ cài đặt" Padding="8,4" FontSize="11" Style="{StaticResource BtnDanger}"/>
                  </StackPanel>
                </Grid>

                <!-- 1-Click All Installer Banner -->
                <Border Background="#0C1B2E" BorderBrush="#0284C7" BorderThickness="1" CornerRadius="8" Padding="14,10">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" VerticalAlignment="Center">
                      <TextBlock Text="CÀI ĐẶT TRỌN GÓI CHO MÁY MỚI (1-CLICK PORTABLE)" FontWeight="Bold" Foreground="#38BDF8" FontSize="13"/>
                      <TextBlock Text="Tự động tải &amp; cấu hình tất cả công cụ vào thư mục tools. Mang sang máy khác chạy được ngay!"
                                 Foreground="#94A3B8" FontSize="11" Margin="0,3,0,0"/>
                    </StackPanel>
                    <Button Grid.Column="1" x:Name="BtnInstallAllTools" Content="⚡ TẢI &amp; CÀI ĐẶT TẤT CẢ" Height="36" Padding="14,6"
                            FontWeight="Bold" FontSize="12" Foreground="White" BorderBrush="#38BDF8">
                      <Button.Background>
                        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                          <GradientStop Color="#0284C7" Offset="0.0"/>
                          <GradientStop Color="#0066FF" Offset="1.0"/>
                        </LinearGradientBrush>
                      </Button.Background>
                    </Button>
                  </Grid>
                </Border>
              </StackPanel>

              <!-- Individual Tool Cards -->
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel Margin="0,0,4,0">
                  <!-- Tool: scrcpy -->
                  <Border Background="#0C101A" BorderBrush="#1C2436" BorderThickness="1" CornerRadius="8" Padding="12,10" Margin="0,0,0,8">
                    <Grid>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="36"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                      </Grid.ColumnDefinitions>
                      <TextBlock Grid.Column="0" Text="🎙" FontSize="20" VerticalAlignment="Center"/>
                      <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="6,0,10,0">
                        <TextBlock Text="scrcpy (Trích xuất âm thanh PCM trực tiếp)" FontWeight="Bold" Foreground="#F1F5F9" FontSize="12.5"/>
                        <TextBlock Text="Bắt luồng âm thanh kỹ thuật số sạch từ Android HAL, độc lập PC 100%." Foreground="#64748B" FontSize="11" Margin="0,2,0,0"/>
                      </StackPanel>
                      <Border Grid.Column="2" x:Name="BadgeStatusScrcpy" Background="#161B26" BorderBrush="#252D3D" BorderThickness="1" CornerRadius="8" Padding="8,3" VerticalAlignment="Center" Margin="0,0,8,0">
                        <TextBlock x:Name="TxtStatusScrcpy" Text="Kiểm tra..." Foreground="#64748B" FontSize="11" FontWeight="Bold"/>
                      </Border>
                      <Button Grid.Column="3" x:Name="BtnInstallScrcpy" Content="📥 Cài đặt" Padding="10,5" VerticalAlignment="Center"/>
                    </Grid>
                  </Border>

                  <!-- Tool: adb -->
                  <Border Background="#0C101A" BorderBrush="#1C2436" BorderThickness="1" CornerRadius="8" Padding="12,10" Margin="0,0,0,8">
                    <Grid>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="36"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                      </Grid.ColumnDefinitions>
                      <TextBlock Grid.Column="0" Text="📱" FontSize="20" VerticalAlignment="Center"/>
                      <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="6,0,10,0">
                        <TextBlock Text="ADB (Android Debug Bridge)" FontWeight="Bold" Foreground="#F1F5F9" FontSize="12.5"/>
                        <TextBlock Text="Giao tiếp, điều khiển tự động hóa và thao tác LDPlayer / thiết bị Android." Foreground="#64748B" FontSize="11" Margin="0,2,0,0"/>
                      </StackPanel>
                      <Border Grid.Column="2" x:Name="BadgeStatusAdb" Background="#161B26" BorderBrush="#252D3D" BorderThickness="1" CornerRadius="8" Padding="8,3" VerticalAlignment="Center" Margin="0,0,8,0">
                        <TextBlock x:Name="TxtStatusAdb" Text="Kiểm tra..." Foreground="#64748B" FontSize="11" FontWeight="Bold"/>
                      </Border>
                      <Button Grid.Column="3" x:Name="BtnInstallAdb" Content="📥 Cài đặt" Padding="10,5" VerticalAlignment="Center"/>
                    </Grid>
                  </Border>

                  <!-- Tool: yt-dlp -->
                  <Border Background="#0C101A" BorderBrush="#1C2436" BorderThickness="1" CornerRadius="8" Padding="12,10" Margin="0,0,0,8">
                    <Grid>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="36"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                      </Grid.ColumnDefinitions>
                      <TextBlock Grid.Column="0" Text="📥" FontSize="20" VerticalAlignment="Center"/>
                      <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="6,0,10,0">
                        <TextBlock Text="yt-dlp (Trình tải Video Facebook Ultra HD)" FontWeight="Bold" Foreground="#F1F5F9" FontSize="12.5"/>
                        <TextBlock Text="Tải video Facebook với độ phân giải cao nhất (4K, 2K, 1080p) và bitrate gốc." Foreground="#64748B" FontSize="11" Margin="0,2,0,0"/>
                      </StackPanel>
                      <Border Grid.Column="2" x:Name="BadgeStatusYtdlp" Background="#161B26" BorderBrush="#252D3D" BorderThickness="1" CornerRadius="8" Padding="8,3" VerticalAlignment="Center" Margin="0,0,8,0">
                        <TextBlock x:Name="TxtStatusYtdlp" Text="Kiểm tra..." Foreground="#64748B" FontSize="11" FontWeight="Bold"/>
                      </Border>
                      <Button Grid.Column="3" x:Name="BtnInstallYtdlp" Content="📥 Cài đặt" Padding="10,5" VerticalAlignment="Center"/>
                    </Grid>
                  </Border>

                  <!-- Tool: FFmpeg -->
                  <Border Background="#0C101A" BorderBrush="#1C2436" BorderThickness="1" CornerRadius="8" Padding="12,10" Margin="0,0,0,8">
                    <Grid>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="36"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                      </Grid.ColumnDefinitions>
                      <TextBlock Grid.Column="0" Text="🎬" FontSize="20" VerticalAlignment="Center"/>
                      <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="6,0,10,0">
                        <TextBlock Text="FFmpeg &amp; ffprobe (Xử lý âm thanh &amp; Video)" FontWeight="Bold" Foreground="#F1F5F9" FontSize="12.5"/>
                        <TextBlock Text="Ghép luồng video, chuẩn hóa âm thanh -16 LUFS và chuyển mã H.264 tương thích 100%." Foreground="#64748B" FontSize="11" Margin="0,2,0,0"/>
                      </StackPanel>
                      <Border Grid.Column="2" x:Name="BadgeStatusFfmpeg" Background="#161B26" BorderBrush="#252D3D" BorderThickness="1" CornerRadius="8" Padding="8,3" VerticalAlignment="Center" Margin="0,0,8,0">
                        <TextBlock x:Name="TxtStatusFfmpeg" Text="Kiểm tra..." Foreground="#64748B" FontSize="11" FontWeight="Bold"/>
                      </Border>
                      <Button Grid.Column="3" x:Name="BtnInstallFfmpeg" Content="📥 Cài đặt" Padding="10,5" VerticalAlignment="Center"/>
                    </Grid>
                  </Border>

                  <!-- Tool: Whisper tiny -->
                  <Border Background="#0C101A" BorderBrush="#1C2436" BorderThickness="1" CornerRadius="8" Padding="12,10">
                    <Grid>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="36"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                      </Grid.ColumnDefinitions>
                      <TextBlock Grid.Column="0" Text="🌐" FontSize="20" VerticalAlignment="Center"/>
                      <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="6,0,10,0">
                        <TextBlock Text="Whisper tiny · Nhận diện ngôn ngữ" FontWeight="Bold" Foreground="#F1F5F9" FontSize="12.5"/>
                        <TextBlock Text="Ước tính ngôn ngữ audio bằng model tiny; vẫn cần nghe nghiệm thu." Foreground="#64748B" FontSize="11" Margin="0,2,0,0"/>
                      </StackPanel>
                      <Border Grid.Column="2" x:Name="BadgeStatusWhisper" Background="#161B26" BorderBrush="#252D3D" BorderThickness="1" CornerRadius="8" Padding="8,3" VerticalAlignment="Center" Margin="0,0,8,0">
                        <TextBlock x:Name="TxtStatusWhisper" Text="Kiểm tra..." Foreground="#64748B" FontSize="11" FontWeight="Bold"/>
                      </Border>
                      <Button Grid.Column="3" x:Name="BtnInstallWhisper" Content="📥 Cài đặt" Padding="10,5" VerticalAlignment="Center"/>
                    </Grid>
                  </Border>
                </StackPanel>
              </ScrollViewer>
            </DockPanel>
          </Border>

          <!-- Content View 4: Raw Terminal Console (Toggled - O CUOI CUNG) -->
          <Border x:Name="ViewLogs" Visibility="Collapsed" Background="#070A0F" BorderBrush="#182030" BorderThickness="1" CornerRadius="7">
            <DockPanel>
              <!-- Action Toolbar for Terminal Logs -->
              <Border DockPanel.Dock="Top" Background="#0F141C" BorderBrush="#1E293B" BorderThickness="0,0,0,1" Padding="12,8">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="💻 " FontSize="14" VerticalAlignment="Center"/>
                    <TextBlock Text="TERMINAL LOGS (NHẬT KÝ HỆ THỐNG)" FontWeight="Bold" FontSize="11.5" Foreground="#38BDF8" VerticalAlignment="Center"/>
                    <TextBlock Text=" · Có thể bôi đen chuột để chép hoặc bấm nút bên phải" FontSize="11" Foreground="#64748B" VerticalAlignment="Center" Margin="10,0,0,0"/>
                  </StackPanel>
                  <StackPanel Grid.Column="1" Orientation="Horizontal">
                    <Button x:Name="BtnCopyLog" Content="📋 Sao chép toàn bộ log" Padding="12,5" Margin="0,0,8,0" FontSize="11.5" FontWeight="SemiBold"
                            Background="#0284C7" Foreground="#FFFFFF" BorderBrush="#38BDF8" Cursor="Hand" ToolTip="Sao chép toàn bộ nội dung nhật ký vào Clipboard"/>
                    <Button x:Name="BtnClearLog" Content="🗑 Xóa log" Padding="10,5" FontSize="11.5"
                            Background="#1E293B" Foreground="#94A3B8" BorderBrush="#334155" Cursor="Hand" ToolTip="Xóa sạch các dòng nhật ký hiện tại"/>
                  </StackPanel>
                </Grid>
              </Border>

              <!-- Log Content (TextBox allows full mouse drag selection, Ctrl+A, Ctrl+C, Right-click copy) -->
              <TextBox x:Name="TxtLog" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap"
                       VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                       Background="#070A0F" Foreground="#E2E8F0" BorderThickness="0"
                       FontFamily="Consolas, Cascadia Code, Courier New" FontSize="12"
                       Padding="14,12" Cursor="IBeam" SelectionBrush="#0284C7"/>
            </DockPanel>
          </Border>
        </DockPanel>
      </Border>

      <!-- SPLITTER -->
      <GridSplitter Grid.Column="1" Width="8" HorizontalAlignment="Stretch" Background="Transparent" Cursor="SizeWE"/>

      <!-- RIGHT: STUDIO CINEMA VIEWPORT -->
      <Border Grid.Column="2" Background="#111724" BorderBrush="#1E293E" BorderThickness="1" CornerRadius="10" Padding="14,12">
        <DockPanel>
          <!-- Viewport Header: Title + A/B Switcher + Resolution Badge -->
          <Grid DockPanel.Dock="Top" Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
              <TextBlock Text="🎬 " FontSize="13" VerticalAlignment="Center"/>
              <TextBlock Text="XEM TRƯỚC VIDEO" FontWeight="Bold" FontSize="11.5" Foreground="#94A3B8" VerticalAlignment="Center"/>
            </StackPanel>

            <!-- A/B Audio Switcher -->
            <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
              <Button x:Name="BtnTrackA" Content="🎧 Audio Tách" Padding="8,3" Margin="0,0,4,0" FontSize="11"
                      Background="Transparent" Foreground="#64748B" BorderBrush="#253248" ToolTip="Nghe âm thanh lồng tiếng đã tách và chuẩn hóa"/>
              <Button x:Name="BtnTrackB" Content="🎙 Meta AI Dub" Padding="8,3" FontSize="11"
                      Background="#064E3B" Foreground="#34D399" BorderBrush="#059669" ToolTip="Nghe bản lồng tiếng Việt chuẩn Meta AI"/>
            </StackPanel>

            <!-- Resolution Badge -->
            <Border Grid.Column="2" x:Name="BadgeRes" Background="#1E293B" BorderBrush="#3B82F6"
                    BorderThickness="1" CornerRadius="10" Padding="10,2" Visibility="Collapsed">
              <TextBlock x:Name="TxtRes" Text="1080x1920 Ultra HD" Foreground="#60A5FA" FontSize="11" FontWeight="Bold"/>
            </Border>
          </Grid>

          <!-- Audio Telemetry (Static - ZERO Layout Shifts) -->
          <Border DockPanel.Dock="Bottom" Background="#0C101A" BorderBrush="#1C2436" BorderThickness="1" CornerRadius="8" Padding="12,7" Margin="0,6,0,0">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock Text="AUDIO TELEMETRY: " Foreground="#475569" FontSize="10.5" FontWeight="Bold" VerticalAlignment="Center"/>
                <TextBlock Text="AAC Stereo · 48 kHz · 192 kbps · EBU R128 (-16.0 LUFS)" Foreground="#94A3B8" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/>
              </StackPanel>
              <Border Grid.Column="1" Background="#162030" BorderBrush="#25354F" BorderThickness="1" CornerRadius="4" Padding="6,2">
                <TextBlock Text="BIT-PERFECT" Foreground="#10B981" FontSize="9.5" FontWeight="Bold"/>
              </Border>
            </Grid>
          </Border>

          <!-- Playback controls -->
          <Border DockPanel.Dock="Bottom" x:Name="PanelPlay" Background="#0C101A" BorderBrush="#1C2436"
                  BorderThickness="1" CornerRadius="8" Padding="10,8" Margin="0,6,0,0" Visibility="Collapsed">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <Button Grid.Column="0" x:Name="BtnPlay" Content="▶ Phát" Width="82" Height="30" FontSize="12" Margin="0,0,10,0"/>
              <!-- IsMoveToPointEnabled allows instant, smooth click-to-seek -->
              <Slider Grid.Column="1" x:Name="Seek" IsMoveToPointEnabled="True" VerticalAlignment="Center" Margin="4,0"/>
              <TextBlock Grid.Column="2" x:Name="TxtTime" Text="0:00 / 0:00" VerticalAlignment="Center"
                         Margin="10,0,10,0" FontFamily="Consolas" Foreground="#94A3B8" FontSize="12"/>
              <Button Grid.Column="3" x:Name="BtnOpenExt" Content="↗ Mở ngoài" Padding="8,4" FontSize="11" ToolTip="Mở video bằng trình phát mặc định của Windows"/>
            </Grid>
          </Border>

          <!-- Cinema Viewport: Phone Frame Mockup Container -->
          <Border Background="#06090E" BorderBrush="#19202E" BorderThickness="1" CornerRadius="8" ClipToBounds="True">
            <Grid>
              <!-- Toast Notification Overlay -->
              <Border x:Name="BorderToast" HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,14,0,0"
                      Background="#0F2D1E" BorderBrush="#10B981" BorderThickness="1" CornerRadius="8" Padding="14,6"
                      Panel.ZIndex="99" Visibility="Collapsed">
                <TextBlock x:Name="TxtToast" Text="✔ ĐÃ COPY FILE ĐỂ RE-UP! BẤM CTRL+V ĐỂ TẢI LÊN NGAY"
                           Foreground="#34D399" FontSize="11.5" FontWeight="Bold"/>
              </Border>

              <!-- Vertical Smartphone Bezel Wrapper (iPhone 16 Pro Max Style - Fixed Size to Eliminate Layout Shifts) -->
              <Border HorizontalAlignment="Center" VerticalAlignment="Center" Width="310" Height="530"
                      Background="#000000" BorderBrush="#253248" BorderThickness="3" CornerRadius="24" ClipToBounds="True">
                <Border.Effect>
                  <DropShadowEffect Color="#000000" BlurRadius="28" ShadowDepth="0" Opacity="0.85"/>
                </Border.Effect>
                <Grid>
                  <!-- Dynamic Island Pill Mockup -->
                  <Border HorizontalAlignment="Center" VerticalAlignment="Top" Width="76" Height="14"
                          Background="#111724" CornerRadius="7" Margin="0,8,0,0" Panel.ZIndex="10"/>

                  <!-- The Video Player -->
                  <MediaElement x:Name="Player" LoadedBehavior="Manual" UnloadedBehavior="Stop"
                                Stretch="Uniform" ScrubbingEnabled="True" Margin="0,22,0,4"/>

                  <!-- Standby Placeholder Overlay -->
                  <StackPanel x:Name="TxtNoVid" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="16" Panel.ZIndex="5">
                    <TextBlock Text="📱" FontSize="42" Foreground="#334155" HorizontalAlignment="Center" Margin="0,0,0,10"/>
                    <TextBlock Text="Sẵn Sàng Phát Video"
                               Foreground="#64748B" FontSize="13.5" FontWeight="Bold" HorizontalAlignment="Center"/>
                    <TextBlock Text="Video hoàn tất sẽ hiển thị chuẩn dọc Reel tại đây"
                               Foreground="#475569" FontSize="11" HorizontalAlignment="Center" Margin="0,5,0,0" TextWrapping="Wrap" TextAlignment="Center"/>
                  </StackPanel>
                </Grid>
              </Border>
            </Grid>
          </Border>
        </DockPanel>
      </Border>
    </Grid>

    <!-- ROW 3: QUALITY QA DECISION PANEL -->
    <Border Grid.Row="3" x:Name="PanelRev" BorderThickness="1" BorderBrush="#059669" CornerRadius="10"
            Margin="16,4,16,12" Padding="14,10" Visibility="Collapsed">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
          <GradientStop Color="#0B2317" Offset="0.0"/>
          <GradientStop Color="#0F2D1E" Offset="1.0"/>
        </LinearGradientBrush>
      </Border.Background>
      <Border.Effect>
        <DropShadowEffect Color="#059669" BlurRadius="16" ShadowDepth="0" Opacity="0.35"/>
      </Border.Effect>
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
          <Border Width="20" Height="20" Background="#10B981" CornerRadius="10" Margin="0,0,8,0">
            <TextBlock Text="✔" Foreground="White" FontSize="11" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock Text="XỬ LÝ HOÀN TẤT - HÃY NGHE KIỂM TRA ĐỂ NGHIỆM THU"
                     FontWeight="Bold" Foreground="#34D399" FontSize="12" VerticalAlignment="Center"/>
          <TextBlock x:Name="TxtRev" Foreground="#A7F3D0" FontSize="11.5" Margin="12,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>

        <StackPanel Grid.Row="1" Orientation="Horizontal">
          <!-- 1-Click Re-Up Clipboard Copy Button -->
          <Button x:Name="BtnCopyReup" Height="34" MinWidth="200" FontWeight="Bold" FontSize="12.5" Foreground="White"
                  BorderThickness="1" BorderBrush="#38BDF8" Margin="0,0,8,0">
            <Button.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#0284C7" Offset="0.0"/>
                <GradientStop Color="#0369A1" Offset="1.0"/>
              </LinearGradientBrush>
            </Button.Background>
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="🚀 " FontWeight="Bold"/>
              <TextBlock Text="COPY FILE ĐỂ RE-UP (Ctrl+V)"/>
            </StackPanel>
          </Button>

          <!-- Keep & Next -->
          <Button x:Name="BtnKeep" Height="34" MinWidth="175" FontWeight="Bold" FontSize="12.5" Foreground="White"
                  BorderThickness="1" BorderBrush="#34D399" Margin="0,0,8,0">
            <Button.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#059669" Offset="0.0"/>
                <GradientStop Color="#10B981" Offset="1.0"/>
              </LinearGradientBrush>
            </Button.Background>
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="✔ " FontWeight="Bold"/>
              <TextBlock Text="DÙNG BẢN NÀY &amp; TIẾP TỤC"/>
            </StackPanel>
          </Button>

          <Button x:Name="BtnRedo" Content="🔄 Ghi âm lại" Height="34" MinWidth="110" Margin="0,0,8,0"/>
          <Button x:Name="BtnDeleteCurrent" Content="🗑 Xoá video này" Height="34" MinWidth="120" Margin="0,0,8,0" Style="{StaticResource BtnDanger}"/>
          <Button x:Name="BtnSkip" Content="⏭ Bỏ qua" Height="34" MinWidth="95" Margin="0,0,8,0"/>
          <Button x:Name="BtnFolder" Content="📂 Mở thư mục xuất" Height="34" MinWidth="135"
                  Background="#1A2436" BorderBrush="#3B82F6" Foreground="#60A5FA"/>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in @('BtnWinMin','BtnWinMax','BtnWinClose',
                 'TxtQueueCount','TxtLinks','TxtOut','BtnPick','BtnOpenOut','BtnStart','BtnCheck','BtnOpenTools','BtnStop','BtnUpdate',
                 'BtnTabPipeline','BtnTabGallery','BtnTabTools','BtnTabLogs','TxtStat','Bar',
                 'ViewPipeline','ViewGallery','ViewTools','ViewLogs',
                 'GalleryPanel','TxtGalleryCount','BtnRefreshGallery',
                 'BtnFilterAllDate','BtnFilterToday','BtnFilterYesterday','BtnFilter7Days','CmbFilterSpecificDate',
                 'BtnFilterTikTokAll','BtnFilterTikTokUnposted','BtnFilterTikTokPosted',
                 'BtnInstallAllTools','BtnCheckTools','BtnOpenUninstall',
                 'BtnInstallScrcpy','BadgeStatusScrcpy','TxtStatusScrcpy',
                 'BtnInstallAdb','BadgeStatusAdb','TxtStatusAdb',
                 'BtnInstallYtdlp','BadgeStatusYtdlp','TxtStatusYtdlp',
                  'BtnInstallFfmpeg','BadgeStatusFfmpeg','TxtStatusFfmpeg',
                  'BtnInstallWhisper','BadgeStatusWhisper','TxtStatusWhisper','ChkLanguage',
                 'ChkWatermark','TxtLogoPath','BtnPickLogo','BtnDefaultLogo','SldLogoSize','TxtLogoSize',
                 'SldLogoFade','TxtLogoFade','CmbLogoMode','CmbLogoPosition',
                 'ImgLogoPreview','TxtLogoName','TxtLogoDefaultHint','PanelLogoPosition',
                 'BadgeStage1','TxtStage1Status','TxtStage1Info',
                 'BadgeStage2','TxtStage2Status','TxtStage2Info',
                 'BadgeStage3','TxtStage3Status','TxtStage3Info',
                 'BadgeStage4','TxtStage4Status','TxtStage4Info',
                 'BadgeStage5','TxtStage5Status','TxtStage5Info',
                 'TxtLog','BtnCopyLog','BtnClearLog','BadgeRes','TxtRes','BtnTrackA','BtnTrackB',
                 'BorderToast','TxtToast','TxtAppVersion',
                 'Player','TxtNoVid','PanelPlay','BtnPlay','Seek','TxtTime','BtnOpenExt',
                 'PanelRev','TxtRev','BtnCopyReup','BtnKeep','BtnRedo','BtnDeleteCurrent','BtnSkip','BtnFolder')) {
    $ui[$n] = $win.FindName($n)
}
$ui.TxtOut.Text = Join-Path $root 'output'
if ($ui.TxtAppVersion) { $ui.TxtAppVersion.Text = "v$($script:verLocal)" }

# ------------------------------------------------------------- trang thai ----
$script:ps            = $null
$script:handle        = $null
$script:seen          = 0
$script:mode          = ''
$script:queue         = @()
$script:idx           = 0
$script:lastOut       = ''
$script:runLog        = ''
$script:giu           = 0
$script:bo            = 0
$script:keoSeek       = $false
$script:wasPlaying    = $false
$script:stopping      = $false
$script:stopHandle    = $null
$script:childProcesses = [hashtable]::Synchronized(@{})
$script:seenErrors    = 0
$script:loggedErrors  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:cancelRequested = $false
$script:closeAfterStop = $false
$script:txtOutWasEnabled = $true
$script:activeTrack   = 'B'
$script:filterDate    = 'all'
$script:filterTikTok  = 'all'

# ------------------------------------------------------------- ham luu trang thai TikTok ----
function Get-ReupMetadata {
    $p = Join-Path $ui.TxtOut.Text 'reup-status.json'
    if (Test-Path $p) {
        try {
            $json = Get-Content $p -Raw -Encoding UTF8
            return (ConvertFrom-Json $json)
        } catch { }
    }
    return [pscustomobject]@{}
}

function Set-ReupMetadata {
    param([string]$VideoId, [bool]$Posted)
    $dir = $ui.TxtOut.Text
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $p = Join-Path $dir 'reup-status.json'
    $meta = Get-ReupMetadata
    if (-not $meta) { $meta = [pscustomobject]@{} }
    $nowStr = (Get-Date).ToString('dd/MM HH:mm')
    
    # Cap nhat doi tuong
    $item = [pscustomobject]@{
        Posted = $Posted
        Date   = $nowStr
    }
    $meta | Add-Member -Name $VideoId -Value $item -MemberType NoteProperty -Force
    try {
        $json = ConvertTo-Json $meta -Depth 4
        [System.IO.File]::WriteAllText($p, $json, [System.Text.Encoding]::UTF8)
    } catch { }
}

function Set-Stage {
    param([int]$Stage, [string]$StatusText, [string]$StatusColor, [string]$InfoText = $null)
    $badge = $ui["BadgeStage$Stage"]
    $txtStatus = $ui["TxtStage${Stage}Status"]
    $txtInfo = $ui["TxtStage${Stage}Info"]
    if ($txtStatus) {
        $txtStatus.Text = $StatusText
        $txtStatus.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString($StatusColor)
    }
    if ($txtInfo -and $InfoText) { $txtInfo.Text = $InfoText }
    if ($badge) {
        if ($StatusColor -eq '#10B981') {
            $badge.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#162520')
            $badge.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#059669')
        } elseif ($StatusColor -eq '#38BDF8') {
            $badge.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#122238')
            $badge.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#0284C7')
        } elseif ($StatusColor -eq '#F87171') {
            $badge.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#28161A')
            $badge.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#E11D48')
        } else {
            $badge.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#161B26')
            $badge.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#252D3D')
        }
    }
}

function Reset-Stages {
    Set-Stage 1 "Sẵn sàng ✔" "#10B981" "LDPlayer Android 14 · ADB Online · scrcpy HAL"
    Set-Stage 2 "Chờ thực hiện" "#64748B" "Tự động bắt 4K / 2K / 1080p Ultra HD · Bitrate cao nhất"
    Set-Stage 3 "Chờ thực hiện" "#64748B" "Nhận diện giao diện Reel · Tự động chọn Tiếng Việt (Ưu tiên)"
    Set-Stage 4 "Chờ thực hiện" "#64748B" "Thu từ Android HAL PCM · Độc lập 100% PC · Buffer +10s"
    Set-Stage 5 "Chờ thực hiện" "#64748B" "Khớp thời lượng mili-giây · Chuẩn hóa -16 LUFS · Faststart"
}

function Add-Log {
    param([string]$Text, [string]$Mau = '#CBD5E1')
    if ($ui.TxtLog) {
        $ui.TxtLog.AppendText($Text + "`r`n")
        if ($ui.TxtLog.Text.Length -gt 60000) {
            $ui.TxtLog.Text = $ui.TxtLog.Text.Substring($ui.TxtLog.Text.Length - 40000)
        }
        $ui.TxtLog.ScrollToEnd()
    }
}

function Add-Line {
    param([string]$L)
    $script:runLog += $L + "`n"

    if ($L -match '\bDUB_UNVERIFIED\b') {
        Set-Stage 3 "Cần nghe kiểm tra" "#F59E0B" "Chưa xác nhận được tiếng Việt từ giao diện"
    } elseif ($L -match '\bDUB_SELECTED\b') {
        Set-Stage 3 "Đã gửi lựa chọn" "#F59E0B" "Đã chọn trên giao diện; cần nghe nghiệm thu"
    }
    if ($L -match '\bAUDIO_LANG_VI\b') {
        Set-Stage 3 "Ước tính: tiếng Việt" "#10B981" "Whisper tiny · cần nghe nghiệm thu"
    } elseif ($L -match '\bAUDIO_LANG_OTHER\b') {
        $languageCode = ''
        if ($L -match '\blanguage=([a-zA-Z0-9_-]+)\b') { $languageCode = $Matches[1] }
        $languageInfo = 'Whisper tiny · cần nghe nghiệm thu'
        if ($languageCode) { $languageInfo += " · language=$languageCode" }
        Set-Stage 3 "Ước tính: ngôn ngữ khác" "#F59E0B" $languageInfo
    } elseif ($L -match '\bAUDIO_LANG_UNKNOWN\b') {
        Set-Stage 3 "Chưa xác định ngôn ngữ" "#F59E0B" "Whisper tiny · cần nghe nghiệm thu"
    }

    # Cap nhat pipeline stages thoi gian thuc
    if ($L -match '\[1\]|Kiem tra cong cu') { Set-Stage 1 "Đang kiểm tra..." "#38BDF8" }
    if ($L -match 'MAY DA SAN SANG|man hinh sang') { Set-Stage 1 "Sẵn sàng ✔" "#10B981" }

    if ($L -match '\[3\]\s+Tai video') { Set-Stage 2 "Đang tải video..." "#38BDF8" }
    if ($L -match '(\d+x\d+)\s+([a-zA-Z0-9]+)\s+\|\s+([\d.]+)\s+giay\s+\|\s+([\d.]+)\s+MB') {
        Set-Stage 2 "Hoàn tất ✔" "#10B981" "$($Matches[1]) $($Matches[2]) · $($Matches[3])s · $($Matches[4]) MB"
        $ui.TxtRes.Text = "$($Matches[1]) · $($Matches[4]) MB"
        $ui.BadgeRes.Visibility = 'Visible'
    }

    if ($L -match '\[4\]\s+Kiem tra che do long tieng') { Set-Stage 3 "Đang cấu hình AI..." "#38BDF8" }
    if ($L -match 'Tieng Viet da la ngon ngu duoc chon san') {
        Set-Stage 3 "Đã kích hoạt ✔" "#10B981" "Meta AI: Tiếng Việt (Ngôn ngữ ưu tiên)"
    }

    if ($L -match '\[5\]\s+Thu am thanh') {
        Set-Stage 4 "Đang thu âm (Live)..." "#38BDF8" "Đang bắt luồng PCM trực tiếp từ Android HAL (Buffer +10s)..."
    }
    if ($L -match '\[6\]\s+Xac dinh diem khoi dau') {
        Set-Stage 4 "Đã thu xong ✔" "#10B981" "Đã bắt trọn luồng âm thanh nguyên bản 100%"
        Set-Stage 5 "Đang đồng bộ..." "#38BDF8"
    }

    if ($L -match 'Am thanh da cat va chuan hoa xong\s*\(([\d.]+)s,\s*muc am\s*([-\d.]+)\s*dB\)') {
        Set-Stage 5 "Đã chuẩn hóa ✔" "#10B981" "Thời lượng $($Matches[1])s · Mức âm $($Matches[2]) dB"
    }
    if ($L -match 'Video\s*:\s*(.+\.mp4)') {
        Set-Stage 5 "Thành công 🎯" "#10B981" "$([System.IO.Path]::GetFileName($Matches[1]))"
    }

    # Format log
    if ($L -match 'KHONG XONG|^\s*x\s|LỖI')              { Add-Log $L '#F87171'; return }
    if ($L -match '^\s*v\s|XONG|SAN SANG')              { Add-Log $L '#34D399'; return }
    if ($L -match '^\s*!\s|Cach sua:')                  { Add-Log $L '#FBBF24'; return }
    if ($L -match '^\s*-\s')                            { Add-Log $L '#94A3B8'; return }
    if ($L -match '^\[\d+\]')                           { Add-Log $L '#38BDF8'; return }
    if ($L -match '=====\s*video')                      { Add-Log $L '#60A5FA'; return }
    Add-Log $L
}

function Set-Busy {
    param([bool]$On)
    $ui.BtnStart.IsEnabled = -not $On
    $ui.BtnCheck.IsEnabled = -not $On
    $ui.BtnOpenTools.IsEnabled = -not $On
    $ui.BtnStop.IsEnabled  = $On
    $ui.TxtLinks.IsEnabled = -not $On
    if ($On) { $script:txtOutWasEnabled = $ui.TxtOut.IsEnabled; $ui.TxtOut.IsEnabled = $false }
    else { $ui.TxtOut.IsEnabled = $script:txtOutWasEnabled }
    $ui.BtnPick.IsEnabled  = -not $On
    if ($ui.ChkLanguage) { $ui.ChkLanguage.IsEnabled = -not $On }
    if ($ui.ChkWatermark) { $ui.ChkWatermark.IsEnabled = -not $On }
    foreach ($logoControl in @($ui.TxtLogoPath,$ui.BtnPickLogo,$ui.BtnDefaultLogo,$ui.SldLogoSize,$ui.SldLogoFade,$ui.CmbLogoMode,$ui.CmbLogoPosition)) {
        if ($logoControl) { $logoControl.IsEnabled = -not $On }
    }
    if ($ui.CmbLogoPosition) { $ui.CmbLogoPosition.IsEnabled = (-not $On -and $ui.CmbLogoMode.SelectedIndex -eq 1) }
    $ui.Bar.Visibility = $(if ($On) { 'Visible' } else { 'Collapsed' })
}

function Show-Toast {
    param([string]$Message)
    try {
        if ($ui.TxtToast) { $ui.TxtToast.Text = $Message }
        if ($ui.BorderToast) { $ui.BorderToast.Visibility = 'Visible' }
        if ($script:tToast) {
            try { $script:tToast.Stop() } catch { }
        }
        $script:tToast = New-Object Windows.Threading.DispatcherTimer
        $script:tToast.Interval = [TimeSpan]::FromSeconds(3)
        $script:tToast.Add_Tick({
            try {
                if ($ui.BorderToast) { $ui.BorderToast.Visibility = 'Collapsed' }
                if ($script:tToast) { $script:tToast.Stop() }
            } catch { }
        })
        $script:tToast.Start()
    } catch { }
}

function Copy-ToClipboard {
    param([string]$FilePath)
    if (-not $FilePath -or -not (Test-Path $FilePath)) {
        Show-Toast "FILE KHÔNG TỒN TẠI ĐỂ COPY"
        return
    }
    try {
        $col = New-Object System.Collections.Specialized.StringCollection
        $full = [System.IO.Path]::GetFullPath($FilePath)
        $col.Add($full)
        [System.Windows.Forms.Clipboard]::SetFileDropList($col)
        Show-Toast "✔ ĐÃ COPY FILE! BẤM CTRL+V ĐỂ UPLOAD TRỰC TIẾP"
        Add-Log "Đã chép file vào Clipboard: $(Split-Path $FilePath -Leaf) (Sẵn sàng Ctrl+V)" '#38BDF8'
    } catch {
        Add-Log "Lỗi copy clipboard: $($_.Exception.Message)" '#F87171'
    }
}

function Clear-Player {
    try { $ui.Player.Stop() }  catch { }
    try { $ui.Player.Close() } catch { }
    $ui.Player.Source = $null
    $ui.PanelPlay.Visibility = 'Collapsed'
    $ui.TxtNoVid.Visibility  = 'Visible'
    $ui.BadgeRes.Visibility  = 'Collapsed'
    $ui.BtnPlay.Content      = '▶ Phát'
    $ui.TxtTime.Text         = '0:00 / 0:00'
    $ui.PanelRev.Visibility  = 'Collapsed'
    $script:lastOut          = $null
    $script:activeTrack      = 'B'
}

function Load-Player {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) {
        Clear-Player
        return
    }
    try {
        $script:lastOut = $Path
        try { $ui.Player.Stop() }  catch { }
        try { $ui.Player.Close() } catch { }
        $full = [System.IO.Path]::GetFullPath($Path)
        $ui.Player.Source = New-Object Uri($full)
        $ui.PanelPlay.Visibility = 'Visible'
        $ui.Player.Play()
        $ui.BtnPlay.Content = '⏸ Tạm dừng'

        # Dat mac dinh Track B (Tieng Viet)
        $ui.BtnTrackB.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#064E3B')
        $ui.BtnTrackB.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#34D399')
        $ui.BtnTrackB.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#059669')
        $ui.BtnTrackA.Background = [System.Windows.Media.Brushes]::Transparent
        $ui.BtnTrackA.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#64748B')
        $ui.BtnTrackA.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#253248')
        $script:activeTrack = 'B'
    } catch {
        Clear-Player
    }
}

$ui.Player.Add_MediaOpened({
    $ui.TxtNoVid.Visibility = 'Collapsed'
    if ($ui.Player.NaturalDuration.HasTimeSpan) {
        $tot = $ui.Player.NaturalDuration.TimeSpan.TotalSeconds
        $ui.Seek.Maximum = $tot
    }
    if ($ui.Player.NaturalVideoWidth -gt 0) {
        $w = $ui.Player.NaturalVideoWidth
        $h = $ui.Player.NaturalVideoHeight
        $tag = if ($w -ge 2160 -or $h -ge 2160) { "4K UHD" }
               elseif ($w -ge 1440 -or $h -ge 1440) { "2K QHD" }
               elseif ($w -ge 1080 -or $h -ge 1080) { "Full HD" }
               else { "HD" }
        $ui.TxtRes.Text = "$tag · ${w}x${h}"
        $ui.BadgeRes.Visibility = 'Visible'
    }
})

$ui.Player.Add_MediaFailed({
    param($s, $e)
    Clear-Player
    $err = if ($e.ErrorException) { $e.ErrorException.Message } else { 'Lỗi giải mã Windows Media Foundation' }
    Add-Log "Cảnh báo Video Player: $err" '#FBBF24'
})

function Switch-AudioTrack {
    param([string]$Track) # 'A' or 'B'
    if (-not $script:lastOut -or -not (Test-Path $script:lastOut)) {
        Clear-Player
        return
    }
    $dir = Split-Path $script:lastOut -Parent
    $nm  = Split-Path $script:lastOut -Leaf
    $id  = $nm -replace '-3-hoan-chinh\.mp4$', ''

    $targetFile = $null
    if ($Track -eq 'A') {
        $fAm  = Join-Path $dir "$id-2-am-thanh-tho.m4a"
        if (Test-Path $fAm)       { $targetFile = $fAm }
    } else {
        $targetFile = $script:lastOut
    }

    if (-not $targetFile -or -not (Test-Path $targetFile)) {
        Show-Toast "CHƯA TÌM THẤY BẢN TRACK NÀY TRONG OUTPUT"
        return
    }

    try {
        $curPos = $ui.Player.Position
        $isPlaying = ($ui.BtnPlay.Content -match 'Tạm dừng')
        $full = [System.IO.Path]::GetFullPath($targetFile)
        $ui.Player.Source = New-Object Uri($full)
        $script:activeTrack = $Track

        if ($Track -eq 'A') {
            $ui.BtnTrackA.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#1E293B')
            $ui.BtnTrackA.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#38BDF8')
            $ui.BtnTrackA.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#0284C7')
            $ui.BtnTrackB.Background = [System.Windows.Media.Brushes]::Transparent
            $ui.BtnTrackB.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#64748B')
            $ui.BtnTrackB.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#253248')
            Show-Toast "ĐANG NGHE [TRACK A: AUDIO TÁCH]"
        } else {
            $ui.BtnTrackB.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#064E3B')
            $ui.BtnTrackB.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#34D399')
            $ui.BtnTrackB.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#059669')
            $ui.BtnTrackA.Background = [System.Windows.Media.Brushes]::Transparent
            $ui.BtnTrackA.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#64748B')
            $ui.BtnTrackA.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#253248')
            Show-Toast "ĐANG NGHE [TRACK B: META AI TIẾNG VIỆT]"
        }

        if ($curPos.TotalSeconds -gt 0) { $ui.Player.Position = $curPos }
        if ($isPlaying) { $ui.Player.Play() }
    } catch {
        Show-Toast "LỖI KHI ĐỔI TRACK ÂM THANH"
    }
}

function Remove-ReelFiles {
    param([string]$FilePath)
    if (-not $FilePath) { return }
    $dir = Split-Path $FilePath -Parent
    $nm  = Split-Path $FilePath -Leaf
    $id  = $nm -replace '-3-hoan-chinh\.mp4$', ''

    # Giai phong player va file lock truoc khi xoa
    if ($script:lastOut -and ($script:lastOut -like "*$id*" -or $script:lastOut -eq $FilePath)) {
        Clear-Player
    } elseif ($ui.Player.Source -and ($ui.Player.Source.ToString() -like "*$id*")) {
        Clear-Player
    }
    Start-Sleep -Milliseconds 150

    foreach ($f in @("$id-1-video-goc.mp4","$id-2-am-thanh-tho.m4a","$id-3-hoan-chinh.mp4")) {
        $p = Join-Path $dir $f
        if (Test-Path $p) {
            try { Remove-Item $p -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

# ------------------------------------------------------------- cap nhat kho video & loc ----
function Update-Gallery {
    $outDir = $ui.TxtOut.Text
    $ui.GalleryPanel.Children.Clear()
    $ui.TxtGalleryCount.Text = "0 video"
    if ([string]::IsNullOrWhiteSpace($outDir) -or -not (Test-Path -LiteralPath $outDir -PathType Container)) { return }
    $allVids = Get-ChildItem -Path $outDir -Filter '*-3-hoan-chinh.mp4' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if (-not $allVids -or $allVids.Count -eq 0) {
        $tb = New-Object Windows.Controls.TextBlock
        $tb.Text = "Chưa có video nào hoàn tất trong thư mục xuất."
        $tb.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#64748B')
        $tb.FontSize = 12
        $tb.Margin = (New-Object Windows.Thickness(10,20,10,10))
        $tb.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
        [void]$ui.GalleryPanel.Children.Add($tb)
        $ui.TxtGalleryCount.Text = "0 video"
        return
    }

    # Cap nhat ComboBox danh sach cac ngay thuc te
    $script:updatingCombo = $true
    try {
        $dateGroups = $allVids | Group-Object { $_.LastWriteTime.ToString('yyyy-MM-dd') }
        $currSelected = $ui.CmbFilterSpecificDate.SelectedItem
        $ui.CmbFilterSpecificDate.Items.Clear()
        [void]$ui.CmbFilterSpecificDate.Items.Add("📅 Lọc theo ngày...")
        foreach ($grp in ($dateGroups | Sort-Object Name -Descending)) {
            try {
                $pDate = [DateTime]::ParseExact($grp.Name, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
                $label = ("📅 {0:dd/MM/yyyy} ({1} video)" -f $pDate, $grp.Count)
            } catch {
                $label = "📅 $($grp.Name) ($($grp.Count) video)"
            }
            [void]$ui.CmbFilterSpecificDate.Items.Add($label)
        }
        if ($currSelected -and $ui.CmbFilterSpecificDate.Items.Contains($currSelected)) {
            $ui.CmbFilterSpecificDate.SelectedItem = $currSelected
        } else {
            $ui.CmbFilterSpecificDate.SelectedIndex = 0
        }
    } finally {
        $script:updatingCombo = $false
    }

    # Doc du lieu trang thai TikTok
    $metaTikTok = Get-ReupMetadata
    $today = (Get-Date).Date

    # Loc danh sach video
    $vids = @($allVids | Where-Object {
        $v = $_
        $id = $v.BaseName -replace '-3-hoan-chinh$', ''
        
        # 1. Loc theo ngay
        $dateMatch = $true
        if ($script:filterDate -eq 'today') {
            $dateMatch = ($v.LastWriteTime.Date -eq $today)
        } elseif ($script:filterDate -eq 'yesterday') {
            $dateMatch = ($v.LastWriteTime.Date -eq $today.AddDays(-1))
        } elseif ($script:filterDate -eq '7days') {
            $dateMatch = ($v.LastWriteTime.Date -ge $today.AddDays(-6) -and $v.LastWriteTime.Date -le $today)
        } elseif ($script:filterDate -match '^\d{4}-\d{2}-\d{2}$') {
            $dateMatch = ($v.LastWriteTime.ToString('yyyy-MM-dd') -eq $script:filterDate)
        }

        # 2. Loc theo trang thai TikTok
        $tiktokMatch = $true
        $isPosted = ($null -ne $metaTikTok -and $metaTikTok.PSObject.Properties.Name -contains $id -and $metaTikTok.$id.Posted -eq $true)
        if ($script:filterTikTok -eq 'unposted') {
            $tiktokMatch = (-not $isPosted)
        } elseif ($script:filterTikTok -eq 'posted') {
            $tiktokMatch = $isPosted
        }

        $dateMatch -and $tiktokMatch
    })

    $ui.TxtGalleryCount.Text = "Hiển thị $($vids.Count) / $($allVids.Count) video"

    if ($vids.Count -eq 0) {
        $tb = New-Object Windows.Controls.TextBlock
        $tb.Text = "Không có video nào phù hợp với bộ lọc hiện tại."
        $tb.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#64748B')
        $tb.FontSize = 12
        $tb.Margin = (New-Object Windows.Thickness(10,25,10,10))
        $tb.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
        [void]$ui.GalleryPanel.Children.Add($tb)
        return
    }

    foreach ($v in $vids) {
        $idName = $v.BaseName -replace '-3-hoan-chinh$', ''
        $isPosted = ($null -ne $metaTikTok -and $metaTikTok.PSObject.Properties.Name -contains $idName -and $metaTikTok.$idName.Posted -eq $true)
        $postedDate = if ($isPosted -and $metaTikTok.$idName.Date) { $metaTikTok.$idName.Date } else { '' }

        $border = New-Object Windows.Controls.Border
        $border.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#0C101A')
        $border.BorderBrush = if ($isPosted) { (New-Object Windows.Media.BrushConverter).ConvertFromString('#059669') } else { (New-Object Windows.Media.BrushConverter).ConvertFromString('#1C2436') }
        $border.BorderThickness = (New-Object Windows.Thickness(1))
        $border.CornerRadius = (New-Object Windows.CornerRadius(8))
        $border.Padding = (New-Object Windows.Thickness(12,10,12,10))
        $border.Margin = (New-Object Windows.Thickness(0,0,0,8))

        $grid = New-Object Windows.Controls.Grid
        $col0 = New-Object Windows.Controls.ColumnDefinition; $col0.Width = (New-Object Windows.GridLength(32))
        $col1 = New-Object Windows.Controls.ColumnDefinition; $col1.Width = (New-Object Windows.GridLength(1, [Windows.GridUnitType]::Star))
        $col2 = New-Object Windows.Controls.ColumnDefinition; $col2.Width = [Windows.GridLength]::Auto
        [void]$grid.ColumnDefinitions.Add($col0)
        [void]$grid.ColumnDefinitions.Add($col1)
        [void]$grid.ColumnDefinitions.Add($col2)

        $icon = New-Object Windows.Controls.TextBlock
        $icon.Text = if ($isPosted) { "✅" } else { "🎬" }
        $icon.FontSize = 18
        $icon.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [Windows.Controls.Grid]::SetColumn($icon, 0)
        [void]$grid.Children.Add($icon)

        $spInfo = New-Object Windows.Controls.StackPanel
        $spInfo.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $spInfo.Margin = (New-Object Windows.Thickness(6,0,10,0))

        # Dong 1: Reel ID + NGAY THANG TO ROI BAT
        $wpHeader = New-Object Windows.Controls.WrapPanel
        $wpHeader.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $wpHeader.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

        $tTitle = New-Object Windows.Controls.TextBlock
        $tTitle.Text = "Reel #$idName"
        $tTitle.FontWeight = [System.Windows.FontWeights]::Bold
        $tTitle.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#F1F5F9')
        $tTitle.FontSize = 13
        $tTitle.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

        # BADGE NGAY THANG TO & ROI BAT
        $dtBadge = New-Object Windows.Controls.Border
        $dtBadge.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#162536')
        $dtBadge.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#0284C7')
        $dtBadge.BorderThickness = (New-Object Windows.Thickness(1))
        $dtBadge.CornerRadius = (New-Object Windows.CornerRadius(5))
        $dtBadge.Padding = (New-Object Windows.Thickness(8,2,8,2))
        $dtBadge.Margin = (New-Object Windows.Thickness(10,0,0,0))
        $dtBadge.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

        $dtTxt = New-Object Windows.Controls.TextBlock
        $dtTxt.Text = "📅 " + $v.LastWriteTime.ToString('dd/MM/yyyy · HH:mm')
        $dtTxt.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#38BDF8')
        $dtTxt.FontWeight = [System.Windows.FontWeights]::Bold
        $dtTxt.FontSize = 12
        $dtBadge.Child = $dtTxt

        [void]$wpHeader.Children.Add($tTitle)
        [void]$wpHeader.Children.Add($dtBadge)
        [void]$spInfo.Children.Add($wpHeader)

        # Dong 2: Thong so video
        $mb = [Math]::Round($v.Length / 1MB, 1)
        $tSub = New-Object Windows.Controls.TextBlock
        $tSub.Text = "$mb MB · Meta AI Vietnamese Dub · MP4 Universal H.264"
        $tSub.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#64748B')
        $tSub.FontSize = 11
        $tSub.Margin = (New-Object Windows.Thickness(0,3,0,5))
        [void]$spInfo.Children.Add($tSub)

        # Dong 3: NUT LUU NOI BO "DA DANG TIKTOK"
        $spTikTok = New-Object Windows.Controls.StackPanel
        $spTikTok.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        
        $btnTikTok = New-Object Windows.Controls.Button
        if ($isPosted) {
            $btnTikTok.Content = "✅ ĐÃ ĐĂNG TIKTOK ($postedDate)"
            $btnTikTok.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#064E3B')
            $btnTikTok.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#10B981')
            $btnTikTok.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#34D399')
        } else {
            $btnTikTok.Content = "⬜ Chưa đăng TikTok"
            $btnTikTok.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#161E2E')
            $btnTikTok.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#2E3D56')
            $btnTikTok.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#94A3B8')
        }
        $btnTikTok.Padding = (New-Object Windows.Thickness(8,3,8,3))
        $btnTikTok.FontSize = 11.5
        $vidKey = $idName
        $btnTikTok.Add_Click({
            $currState = ($btnTikTok.Content -match 'ĐÃ ĐĂNG')
            $newState = -not $currState
            Set-ReupMetadata -VideoId $vidKey -Posted $newState
            if ($newState) {
                Show-Toast "✔ ĐÃ ĐÁNH DẤU: ĐÃ ĐĂNG TIKTOK (Reel #$vidKey)"
            } else {
                Show-Toast "ĐÃ BỎ ĐÁNH DẤU TIKTOK (Reel #$vidKey)"
            }
            Update-Gallery
        }.GetNewClosure())
        [void]$spTikTok.Children.Add($btnTikTok)
        [void]$spInfo.Children.Add($spTikTok)

        [Windows.Controls.Grid]::SetColumn($spInfo, 1)
        [void]$grid.Children.Add($spInfo)

        # Action Buttons
        $spBtn = New-Object Windows.Controls.StackPanel
        $spBtn.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $spBtn.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

        $fPath = $v.FullName

        # Nut Xem
        $btnPlayThis = New-Object Windows.Controls.Button
        $btnPlayThis.Content = "👁 Xem"
        $btnPlayThis.Padding = (New-Object Windows.Thickness(9,4,9,4))
        $btnPlayThis.Margin = (New-Object Windows.Thickness(0,0,5,0))
        $btnPlayThis.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#162030')
        $btnPlayThis.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#25354F')
        $btnPlayThis.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#38BDF8')
        $btnPlayThis.Add_Click({
            if ($script:ps -or ($script:queue -and $script:queue.Count -gt 0)) {
                Show-Toast 'Hãy hoàn tất hoặc bỏ qua video đang nghiệm thu trước khi xem video khác.'
                return
            }
            $script:lastOut = $fPath
            Load-Player $fPath
            $ui.TxtRev.Text = "Đang xem lại: $(Split-Path $fPath -Leaf)"
            $ui.BtnKeep.Visibility = 'Collapsed'
            $ui.BtnRedo.Content = '🔄 Ghi âm lại'
            $ui.PanelRev.Visibility = 'Visible'
        }.GetNewClosure())

        # Nut Copy Ctrl+V
        $btnCopyThis = New-Object Windows.Controls.Button
        $btnCopyThis.Content = "🚀 Copy"
        $btnCopyThis.Padding = (New-Object Windows.Thickness(9,4,9,4))
        $btnCopyThis.Margin = (New-Object Windows.Thickness(0,0,5,0))
        $btnCopyThis.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#122238')
        $btnCopyThis.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#0284C7')
        $btnCopyThis.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#60A5FA')
        $btnCopyThis.Add_Click({
            Copy-ToClipboard $fPath
        }.GetNewClosure())

        # Nut Mo Explorer
        $btnFileThis = New-Object Windows.Controls.Button
        $btnFileThis.Content = "↗ File"
        $btnFileThis.Padding = (New-Object Windows.Thickness(9,4,9,4))
        $btnFileThis.Margin = (New-Object Windows.Thickness(0,0,5,0))
        $btnFileThis.Add_Click({
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "explorer.exe"
                $psi.Arguments = "/select,`"$fPath`""
                $psi.UseShellExecute = $true
                [System.Diagnostics.Process]::Start($psi) | Out-Null
            } catch {
                Open-FolderSafe (Split-Path $fPath -Parent)
            }
        }.GetNewClosure())

        # Nut XOA VIDEO
        $btnDelThis = New-Object Windows.Controls.Button
        $btnDelThis.Content = "🗑 Xóa"
        $btnDelThis.Padding = (New-Object Windows.Thickness(9,4,9,4))
        $btnDelThis.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#2A1519')
        $btnDelThis.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#7F1D1D')
        $btnDelThis.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#F87171')
        $btnDelThis.Add_Click({
            if ($script:ps -or ($script:queue -and $script:queue.Count -gt 0)) {
                Show-Toast 'Hãy hoàn tất tác vụ và hàng đợi trước khi xóa video trong kho.'
                return
            }
            $ans = [System.Windows.MessageBox]::Show(
                "Bạn có chắc chắn muốn xóa video này khỏi kho xuất?`n`nReel #$idName`nFile: $(Split-Path $fPath -Leaf)",
                "Xác nhận xóa video",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($ans -eq [System.Windows.MessageBoxResult]::Yes) {
                if ($script:lastOut -eq $fPath -or ($script:lastOut -like "*$idName*") -or ($ui.Player.Source -and $ui.Player.Source.ToString() -like "*$idName*")) {
                    Clear-Player
                }
                Remove-ReelFiles $fPath
                Show-Toast "ĐÃ XÓA VIDEO REEL #$idName"
                Add-Log "Đã xóa video khỏi kho: Reel #$idName" '#F87171'
                Update-Gallery
            }
        }.GetNewClosure())

        [void]$spBtn.Children.Add($btnPlayThis)
        [void]$spBtn.Children.Add($btnCopyThis)
        [void]$spBtn.Children.Add($btnFileThis)
        [void]$spBtn.Children.Add($btnDelThis)
        [Windows.Controls.Grid]::SetColumn($spBtn, 2)
        [void]$grid.Children.Add($spBtn)

        $border.Child = $grid
        [void]$ui.GalleryPanel.Children.Add($border)
    }
}

# ------------------------------------------------------------- quan ly cong cu & thu vien ----
function Update-ToolsStatus {
    $inToolsScrcpy = (Test-Path (Join-Path $root 'tools\scrcpy\scrcpy.exe')) -or 
                     (Test-Path (Join-Path $root 'tools\scrcpy\scrcpy-win64-v5.0\scrcpy.exe')) -or 
                     (Test-Path (Join-Path $root 'tools\scrcpy\scrcpy-win64-v4.1\scrcpy.exe')) -or 
                     (Test-Path (Join-Path $root 'tools\scrcpy\scrcpy-win64-v3.1\scrcpy.exe')) -or 
                     (Test-Path (Join-Path $root 'tools\scrcpy\scrcpy-win64-v2.7\scrcpy.exe')) -or 
                     (Test-Path (Join-Path $root 'tools\scrcpy.exe'))
    $hasScrcpy = $inToolsScrcpy -or (Get-Command 'scrcpy' -ErrorAction SilentlyContinue)

    $inToolsAdb    = (Test-Path (Join-Path $root 'tools\scrcpy\adb.exe')) -or 
                     (Test-Path (Join-Path $root 'tools\scrcpy\scrcpy-win64-v5.0\adb.exe')) -or 
                     (Test-Path (Join-Path $root 'tools\scrcpy\scrcpy-win64-v4.1\adb.exe')) -or 
                     (Test-Path (Join-Path $root 'tools\scrcpy\scrcpy-win64-v3.1\adb.exe')) -or 
                     (Test-Path (Join-Path $root 'tools\scrcpy\scrcpy-win64-v2.7\adb.exe')) -or 
                     (Test-Path (Join-Path $root 'tools\adb.exe'))
    $hasAdb = $inToolsAdb -or (Get-Command 'adb' -ErrorAction SilentlyContinue) -or
              (Test-Path 'D:\LDPlayer\LDPlayer14\adb.exe' -ErrorAction SilentlyContinue) -or
              (Test-Path 'D:\LDPlayer\LDPlayer9\adb.exe' -ErrorAction SilentlyContinue) -or
              (Test-Path 'C:\LDPlayer\LDPlayer14\adb.exe' -ErrorAction SilentlyContinue)

    $inToolsYtdlp  = (Test-Path (Join-Path $root 'tools\yt-dlp.exe')) -or 
                     (Test-Path (Join-Path $root 'tools\yt-dlp\yt-dlp.exe'))
    $hasYtdlp = $inToolsYtdlp -or (Get-Command 'yt-dlp' -ErrorAction SilentlyContinue)

    $inToolsFfmpeg = (Test-Path (Join-Path $root 'tools\ffmpeg\ffmpeg.exe')) -or 
                     (Test-Path (Join-Path $root 'tools\ffmpeg\bin\ffmpeg.exe')) -or 
                     (Test-Path (Join-Path $root 'tools\ffmpeg.exe'))
    $hasFfmpeg = $inToolsFfmpeg -or (Get-Command 'ffmpeg' -ErrorAction SilentlyContinue)
    $inToolsFfprobe = (Test-Path (Join-Path $root 'tools\ffmpeg\ffprobe.exe')) -or
                      (Test-Path (Join-Path $root 'tools\ffmpeg\bin\ffprobe.exe')) -or
                      (Test-Path (Join-Path $root 'tools\ffprobe.exe'))
    $hasFfprobe = $inToolsFfprobe -or (Get-Command 'ffprobe' -ErrorAction SilentlyContinue)

    function Set-ToolCard($txtElem, $badgeElem, $btnElem, [bool]$installed, [bool]$inTools = $false) {
        if (-not $txtElem -or -not $badgeElem) { return }
        if ($inTools) {
            $txtElem.Text = "Đã có (Portable) ✔"
            $txtElem.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#10B981')
            $badgeElem.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#059669')
            $badgeElem.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#12251D')
            if ($btnElem) { $btnElem.Content = "🔄 Tải lại" }
        } elseif ($installed) {
            $txtElem.Text = "Đã có trên máy ✔"
            $txtElem.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#38BDF8')
            $badgeElem.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#0284C7')
            $badgeElem.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#0C1B2E')
            if ($btnElem) { $btnElem.Content = "📥 Gom vào tools" }
        } else {
            $txtElem.Text = "Chưa có ✖"
            $txtElem.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#F87171')
            $badgeElem.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#7F1D1D')
            $badgeElem.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#251417')
            if ($btnElem) { $btnElem.Content = "📥 Cài đặt" }
        }
    }

    Set-ToolCard $ui.TxtStatusScrcpy $ui.BadgeStatusScrcpy $ui.BtnInstallScrcpy $hasScrcpy $inToolsScrcpy
    Set-ToolCard $ui.TxtStatusAdb    $ui.BadgeStatusAdb    $ui.BtnInstallAdb    $hasAdb    $inToolsAdb
    Set-ToolCard $ui.TxtStatusYtdlp  $ui.BadgeStatusYtdlp  $ui.BtnInstallYtdlp  $hasYtdlp  $inToolsYtdlp
    Set-ToolCard $ui.TxtStatusFfmpeg $ui.BadgeStatusFfmpeg $ui.BtnInstallFfmpeg $hasFfmpeg $inToolsFfmpeg
    $hasWhisper = $false
    if ($script:whisperLanguageHelperAvailable) {
        try {
            $whisperPaths = Get-WhisperPaths $root
            $hasWhisper = [bool]$whisperPaths.Ready
        } catch { $hasWhisper = $false }
    }
    Set-ToolCard $ui.TxtStatusWhisper $ui.BadgeStatusWhisper $ui.BtnInstallWhisper $hasWhisper $hasWhisper
    if ($hasWhisper -and $ui.BtnInstallWhisper) { $ui.BtnInstallWhisper.Content = '✔ Kiểm tra' }
    if ($hasFfmpeg -and -not $hasFfprobe) {
        $ui.TxtStatusFfmpeg.Text = 'Thiếu ffprobe ✖'
        $ui.TxtStatusFfmpeg.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#F87171')
        $ui.BadgeStatusFfmpeg.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#7F1D1D')
        $ui.BadgeStatusFfmpeg.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#251417')
    }
}

function Install-ToolGUI {
    param([string]$ToolName)
    if ($script:ps -or ($script:queue -and $script:queue.Count -gt 0)) {
        Show-Toast 'Hãy hoàn tất tác vụ và hàng đợi trước khi cài công cụ.'
        return
    }
    $tDir = Join-Path $root 'tools'
    foreach ($sub in @('', '_download', 'scrcpy', 'ffmpeg')) {
        $p = if ($sub) { Join-Path $tDir $sub } else { $tDir }
        if (-not (Test-Path -LiteralPath $p)) {
            try { New-Item -ItemType Directory -Path $p -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
        }
    }
    $ui.BtnTabLogs.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Add-Log ""
    Add-Log "===== ĐANG TẢI & CÀI ĐẶT CÔNG CỤ: $ToolName =====" '#38BDF8'
    Start-Engine -Links @() -Named @{ SetupTool = $ToolName } -Mode 'setup' -XoaLog $false
}

function Start-Engine {
    param([string[]]$Links, [hashtable]$Named, [string]$Mode, [bool]$XoaLog = $true)
    if ($script:ps) { return }
    if ($Mode -ne 'run' -and $script:queue -and $script:queue.Count -gt 0) {
        Show-Toast 'Hãy hoàn tất hàng đợi đang nghiệm thu trước khi kiểm tra hoặc cài công cụ.'
        return
    }
    # The engine registers only subprocesses it owns; a fresh registry is safe after Finish-Engine disposed the prior pipeline.
    $script:childProcesses = [hashtable]::Synchronized(@{})
    $script:stopHandle = $null
    $script:seenErrors = 0
    $script:loggedErrors = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $script:cancelRequested = $false
    if ($XoaLog) { if ($ui.TxtLog) { $ui.TxtLog.Clear() }; $script:runLog = '' }
    $script:seen = 0; $script:mode = $Mode; $script:runLog = ''; $script:stopping = $false
    $ui.PanelRev.Visibility = 'Collapsed'
    Set-Busy $true
    try { [System.Environment]::CurrentDirectory = $root } catch { }
    $script:ps = [PowerShell]::Create()
    [void]$script:ps.AddCommand('Set-Location').AddParameter('LiteralPath', $root)
    [void]$script:ps.AddStatement()
    [void]$script:ps.AddCommand($engine)
    if ($Links) { foreach ($l in $Links) { [void]$script:ps.AddArgument($l) } }
    if ($Named) { foreach ($k in $Named.Keys) { [void]$script:ps.AddParameter($k, $Named[$k]) } }
    [void]$script:ps.AddParameter('ProcessRegistry', $script:childProcesses)
    $script:handle = $script:ps.BeginInvoke()
    $timer.Start()
}

function Stop-Engine {
    if (-not $script:ps) { return }
    $script:stopping = $true
    $script:cancelRequested = $true
    $owned = @()
    $registry = $script:childProcesses
    if ($registry) {
        [System.Threading.Monitor]::Enter($registry.SyncRoot)
        try { $owned = @($registry.Values) }
        finally { [System.Threading.Monitor]::Exit($registry.SyncRoot) }
    }
    foreach ($proc in $owned) {
        try { if ($proc -and -not $proc.HasExited) { $proc.Kill() } } catch { }
    }
    if (-not $script:stopHandle) {
        try { $script:stopHandle = $script:ps.BeginStop($null, $null) }
        catch { $script:stopHandle = $null }
    }
    # Keep the dispatcher timer and busy state active until both async operations finish.
}

function Pump-Output {
    if (-not $script:ps) { return }
    $inf = $script:ps.Streams.Information
    while ($script:seen -lt $inf.Count) {
        $rec = $inf[$script:seen]; $script:seen++
        $md = $rec.MessageData; $msg = ''
        if ($null -ne $md) {
            if ($md.PSObject.Properties.Name -contains 'Message') { $msg = [string]$md.Message }
            else { $msg = [string]$md }
        }
        foreach ($ln in ($msg -split "`r?`n")) { Add-Line $ln }
    }
    $errs = $script:ps.Streams.Error
    while ($script:seenErrors -lt $errs.Count) {
        $rec = $errs[$script:seenErrors]
        $script:seenErrors++
        if (-not ($script:cancelRequested -and (Test-PipelineStoppedException $rec.Exception))) {
            $errText = [string]$rec.Exception.Message
            if (-not $script:loggedErrors.Contains($errText)) {
                [void]$script:loggedErrors.Add($errText)
                Add-Line "LỖI: $errText"
            }
        }
    }
}

function Test-PipelineStoppedException {
    param([System.Exception]$Exception)
    $current = $Exception
    while ($current) {
        if ($current -is [System.Management.Automation.PipelineStoppedException]) { return $true }
        $current = $current.InnerException
    }
    return $false
}

function Finish-Engine {
    param([bool]$Cancelled = $false)
    $psInstance = $script:ps
    $invokeHandle = $script:handle
    if (-not $psInstance) { return }
    try {
        if ($invokeHandle) {
            try { [void]$psInstance.EndInvoke($invokeHandle) }
            catch {
                if (-not ($Cancelled -and (Test-PipelineStoppedException $_.Exception))) {
                    $errText = [string]$_.Exception.Message
                    if (-not $script:loggedErrors.Contains($errText)) {
                        [void]$script:loggedErrors.Add($errText)
                        Add-Line "LỖI: $errText"
                    }
                }
            }
        }
        Pump-Output
    } finally {
        try { $psInstance.Dispose() } catch { }
        if ([object]::ReferenceEquals($script:ps, $psInstance)) {
            $script:ps = $null
            $script:handle = $null
            $script:stopHandle = $null
            $script:stopping = $false
            $script:cancelRequested = $false
            $timer.Stop()
            Set-Busy $false
        }
    }
}

function Start-Link {
    if (-not $script:queue -or $script:queue.Count -eq 0 -or $script:idx -lt 0 -or $script:idx -ge $script:queue.Count) {
        Show-Toast 'Chỉ ghi âm lại video đang nghiệm thu trong hàng đợi.'
        return
    }
    Clear-Player
    Reset-Stages
    $n = $script:idx + 1
    Add-Log '' ; Add-Log "===== Video $n/$($script:queue.Count) =====" '#60A5FA'
    Add-Log $script:queue[$script:idx] '#94A3B8'
    $ui.TxtStat.Text = "Đang xử lý Video ($n/$($script:queue.Count))..."
    $ui.TxtStat.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#38BDF8')
    Start-Engine -Links @($script:queue[$script:idx]) -Named @{ OutDir = $ui.TxtOut.Text; SkipLanguageCheck = ([bool](-not $ui.ChkLanguage.IsChecked)); Watermark = [bool]$ui.ChkWatermark.IsChecked; LogoFile = $ui.TxtLogoPath.Text; LogoSize = [int]$ui.SldLogoSize.Value; LogoFade = [int]$ui.SldLogoFade.Value; LogoMotion = $(if ($ui.CmbLogoMode.SelectedIndex -eq 0) { 'Free' } else { 'Fixed' }); LogoPosition = @('TopLeft','TopRight','BottomLeft','BottomRight','Center')[[int]$ui.CmbLogoPosition.SelectedIndex] } -Mode 'run' -XoaLog $false
}

function Next-Link {
    $script:idx++
    if ($script:idx -lt $script:queue.Count) { Start-Link }
    else {
        Add-Log ''
        Add-Log "Tổng kết hàng loạt: Giữ $($script:giu)  |  Bỏ qua $($script:bo)" '#34D399'
        $script:queue = @()
        $ui.TxtStat.Text = 'Hoàn tất toàn bộ hàng đợi'
        $ui.TxtStat.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#10B981')
        Set-Busy $false
        Update-Gallery
    }
}

# ------------------------------------------------------------------ nhip ----
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$timer.Add_Tick({
    try {
        Pump-Output
        if ($script:stopping) {
            $stopDone = (-not $script:stopHandle -or $script:stopHandle.IsCompleted)
            $invokeDone = (-not $script:handle -or $script:handle.IsCompleted)
            if ($stopDone -and $invokeDone) {
                if ($script:stopHandle) { try { $script:ps.EndStop($script:stopHandle) } catch { } }
                Finish-Engine -Cancelled $true
                $script:queue = @()
                $ui.PanelRev.Visibility = 'Collapsed'
                if ($ui.TxtStat) { $ui.TxtStat.Text = 'Đã dừng theo yêu cầu'; $ui.TxtStat.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#FBBF24') }
                if ($script:closeAfterStop) { $script:closeAfterStop = $false; $win.Close() }
            }
            return
        }
        if ($script:handle -and $script:handle.IsCompleted) {
            $laCheck = ($script:mode -eq 'check')
            $laSetup = ($script:mode -eq 'setup')
            Finish-Engine -Cancelled $false
            $txt = $script:runLog
            if ($laSetup) {
                Update-ToolsStatus
                $hasScrcpy = (Test-Path (Join-Path $root 'tools\scrcpy\scrcpy.exe')) -or 
                             (Test-Path (Join-Path $root 'tools\scrcpy\scrcpy-win64-v5.0\scrcpy.exe')) -or 
                             (Test-Path (Join-Path $root 'tools\scrcpy\scrcpy-win64-v4.1\scrcpy.exe')) -or 
                             (Test-Path (Join-Path $root 'tools\scrcpy\scrcpy-win64-v3.1\scrcpy.exe')) -or 
                             (Test-Path (Join-Path $root 'tools\scrcpy\scrcpy-win64-v2.7\scrcpy.exe')) -or 
                             (Test-Path (Join-Path $root 'tools\scrcpy.exe')) -or 
                             (Get-Command 'scrcpy' -ErrorAction SilentlyContinue)
                $hasAdb    = (Test-Path (Join-Path $root 'tools\scrcpy\adb.exe')) -or 
                             (Test-Path (Join-Path $root 'tools\scrcpy\scrcpy-win64-v5.0\adb.exe')) -or 
                             (Test-Path (Join-Path $root 'tools\scrcpy\scrcpy-win64-v4.1\adb.exe')) -or 
                             (Test-Path (Join-Path $root 'tools\scrcpy\scrcpy-win64-v3.1\adb.exe')) -or 
                             (Test-Path (Join-Path $root 'tools\scrcpy\scrcpy-win64-v2.7\adb.exe')) -or 
                             (Test-Path (Join-Path $root 'tools\adb.exe')) -or 
                             (Get-Command 'adb' -ErrorAction SilentlyContinue) -or
                             (Test-Path 'D:\LDPlayer\LDPlayer14\adb.exe' -ErrorAction SilentlyContinue) -or
                             (Test-Path 'D:\LDPlayer\LDPlayer9\adb.exe' -ErrorAction SilentlyContinue) -or
                             (Test-Path 'C:\LDPlayer\LDPlayer14\adb.exe' -ErrorAction SilentlyContinue)
                $hasYtdlp  = (Test-Path (Join-Path $root 'tools\yt-dlp.exe')) -or 
                             (Test-Path (Join-Path $root 'tools\yt-dlp\yt-dlp.exe')) -or 
                             (Get-Command 'yt-dlp' -ErrorAction SilentlyContinue)
                $hasFfmpeg = (Test-Path (Join-Path $root 'tools\ffmpeg\ffmpeg.exe')) -or 
                             (Test-Path (Join-Path $root 'tools\ffmpeg\bin\ffmpeg.exe')) -or 
                             (Test-Path (Join-Path $root 'tools\ffmpeg.exe')) -or 
                             (Get-Command 'ffmpeg' -ErrorAction SilentlyContinue)
                $hasFfprobe = (Test-Path (Join-Path $root 'tools\ffmpeg\ffprobe.exe')) -or
                              (Test-Path (Join-Path $root 'tools\ffmpeg\bin\ffprobe.exe')) -or
                              (Test-Path (Join-Path $root 'tools\ffprobe.exe')) -or
                              (Get-Command 'ffprobe' -ErrorAction SilentlyContinue)
                $allReady = $hasScrcpy -and $hasAdb -and $hasYtdlp -and $hasFfmpeg -and $hasFfprobe
                if ($allReady) {
                    Show-Toast "Công cụ xử lý video đã sẵn sàng"
                    Add-Log "Các công cụ xử lý video đã sẵn sàng; xem trạng thái tiny tại thẻ Whisper." '#10B981'
                } else {
                    Show-Toast "ĐÃ CẬP NHẬT TRẠNG THÁI CÔNG CỤ"
                    Add-Log "Kiểm tra hoàn tất: Xem trạng thái các công cụ tại tab CÔNG CỤ & HỆ THỐNG." '#38BDF8'
                }
                return
            }
            if ($laCheck) {
                Update-ToolsStatus
                if ($txt -match 'SAN SANG') {
                    if ($ui.TxtStat) {
                        $ui.TxtStat.Text = 'Hệ thống đã sẵn sàng'
                        $ui.TxtStat.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#10B981')
                    }
                    Set-Stage 1 "Sẵn sàng ✔" "#10B981" "LDPlayer Android 14 · ADB Online · scrcpy HAL"
                } else {
                    if ($ui.TxtStat) {
                        $ui.TxtStat.Text = 'Chưa sẵn sàng - Xem chi tiết lỗi'
                        $ui.TxtStat.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#F87171')
                    }
                    Set-Stage 1 "Chưa sẵn sàng ✖" "#F87171" "Kiểm tra LDPlayer hoặc công cụ"
                }
                return
            }
            if ($script:queue.Count -eq 0) { return }
            $m = [regex]::Match($txt, 'Video\s*:\s*(.+\.mp4)')
            $script:lastOut = ''
            if ($m.Success) { $script:lastOut = $m.Groups[1].Value.Trim() }
            $ok = ($script:lastOut -ne '' -and (Test-Path $script:lastOut))
            if ($ok) {
                $mRes = [regex]::Match($txt, '(\d+x\d+.*?MB)')
                if ($mRes.Success -and $ui.TxtRes -and $ui.BadgeRes) {
                    $ui.TxtRes.Text = $mRes.Groups[1].Value.Trim()
                    $ui.BadgeRes.Visibility = 'Visible'
                }
                if ($ui.TxtRev) {
                    $ui.TxtRev.Text = if ($txt -match '\bAUDIO_LANG_VI\b') {
                        'Whisper tiny ước tính tiếng Việt. Nghe kiểm tra trước khi dùng.'
                    } elseif ($txt -match '\bAUDIO_LANG_OTHER\b') {
                        'Whisper tiny ước tính ngôn ngữ khác. Kiểm tra audio trước khi dùng.'
                    } elseif ($txt -match '\bAUDIO_LANG_UNKNOWN\b') {
                        'Chưa xác định được ngôn ngữ audio. Nghe kiểm tra trước khi dùng.'
                    } elseif ($txt -match '\bDUB_(?:UNVERIFIED|SELECTED)\b') {
                        'Chưa xác nhận ngôn ngữ từ audio; nghe kiểm tra trước khi dùng.'
                    } else { 'Nghe hết video bên phải. Nếu chuẩn thì bấm "Dùng bản này" hoặc Copy để đăng ngay.' }
                }
                if ($ui.BtnKeep) { $ui.BtnKeep.Visibility = 'Visible' }
                if ($ui.BtnRedo) { $ui.BtnRedo.Content = '🔄 Ghi âm lại' }
                if ($ui.TxtStat) {
                    $ui.TxtStat.Text = 'Chờ bạn nghiệm thu'
                    $ui.TxtStat.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#34D399')
                }
                Load-Player $script:lastOut
                Update-Gallery
            } else {
                if ($ui.TxtRev) { $ui.TxtRev.Text = 'Video này chưa hoàn tất. Bạn muốn thử lại hay bỏ qua?' }
                if ($ui.BtnKeep) { $ui.BtnKeep.Visibility = 'Collapsed' }
                if ($ui.BtnRedo) { $ui.BtnRedo.Content = '🔄 Thử lại' }
                if ($ui.TxtStat) {
                    $ui.TxtStat.Text = 'Chưa hoàn tất'
                    $ui.TxtStat.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#FBBF24')
                }
            }
            if ($ui.PanelRev) { $ui.PanelRev.Visibility = 'Visible' }
        }
    } catch { }
})

# Nhip thanh tua video - TOI UU HOAN TOAN KHONG LAG & KHONG GIUT
$tPlay = New-Object Windows.Threading.DispatcherTimer
$tPlay.Interval = [TimeSpan]::FromMilliseconds(200)
$tPlay.Add_Tick({
    try {
        if ($ui.Player.Source -and $ui.Player.NaturalDuration.HasTimeSpan) {
            $tot = $ui.Player.NaturalDuration.TimeSpan.TotalSeconds
            $cur = $ui.Player.Position.TotalSeconds
            if ($tot -gt 0) {
                $ui.Seek.Maximum = $tot
                if (-not $script:keoSeek -and -not $ui.Seek.IsMouseCaptureWithin) {
                    $ui.Seek.Value = $cur
                    $strCur = ('{0}:{1:00}.{2}' -f [int][Math]::Floor($cur/60), [int]($cur%60), [int](($cur*10)%10))
                    $strTot = ('{0}:{1:00}.{2}' -f [int][Math]::Floor($tot/60), [int]($tot%60), [int](($tot*10)%10))
                    $ui.TxtTime.Text = "$strCur / $strTot"
                }
            }
        }
    } catch { }
})
$tPlay.Start()

# ------------------------------------------------------------------- nut & tabs ----
# Custom Window Chrome Buttons
$ui.BtnWinMin.Add_Click({ $win.WindowState = [System.Windows.WindowState]::Minimized })
$ui.BtnWinMax.Add_Click({
    if ($win.WindowState -eq [System.Windows.WindowState]::Maximized) {
        $win.WindowState = [System.Windows.WindowState]::Normal
        $ui.BtnWinMax.Content = '☐'
    } else {
        $win.WindowState = [System.Windows.WindowState]::Maximized
        $ui.BtnWinMax.Content = '❐'
    }
})
$ui.BtnWinClose.Add_Click({ $win.Close() })

# TAB SWITCHING LOGIC: Tien trinh -> Kho Video -> Bo Thu Vien -> Terminal Logs (CUOI CUNG)
function Reset-TabButtons {
    foreach ($b in @($ui.BtnTabPipeline, $ui.BtnTabGallery, $ui.BtnTabTools, $ui.BtnTabLogs)) {
        $b.Background  = [System.Windows.Media.Brushes]::Transparent
        $b.Foreground  = (New-Object Windows.Media.BrushConverter).ConvertFromString('#94A3B8')
        $b.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#253248')
    }
    $ui.ViewPipeline.Visibility = 'Collapsed'
    $ui.ViewGallery.Visibility  = 'Collapsed'
    $ui.ViewTools.Visibility    = 'Collapsed'
    $ui.ViewLogs.Visibility     = 'Collapsed'
}

$ui.BtnTabPipeline.Add_Click({
    Reset-TabButtons
    $ui.ViewPipeline.Visibility   = 'Visible'
    $ui.BtnTabPipeline.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#1E293E')
    $ui.BtnTabPipeline.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#38BDF8')
    $ui.BtnTabPipeline.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#3B82F6')

    # Neu video truoc do da bi xoa khoi o dia -> xoa trang player & review panel ngay
    if ($script:lastOut -and (-not (Test-Path $script:lastOut))) {
        Clear-Player
    }
})

$ui.BtnTabGallery.Add_Click({
    Reset-TabButtons
    $ui.ViewGallery.Visibility   = 'Visible'
    $ui.BtnTabGallery.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#1E293E')
    $ui.BtnTabGallery.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#38BDF8')
    $ui.BtnTabGallery.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#3B82F6')
    Update-Gallery
})

$ui.BtnTabTools.Add_Click({
    Reset-TabButtons
    $ui.ViewTools.Visibility   = 'Visible'
    $ui.BtnTabTools.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#1E293E')
    $ui.BtnTabTools.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#38BDF8')
    $ui.BtnTabTools.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#3B82F6')
    Update-ToolsStatus
})

$ui.BtnTabLogs.Add_Click({
    Reset-TabButtons
    $ui.ViewLogs.Visibility   = 'Visible'
    $ui.BtnTabLogs.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#1E293E')
    $ui.BtnTabLogs.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#38BDF8')
    $ui.BtnTabLogs.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#3B82F6')
})

$ui.BtnOpenTools.Add_Click({
    $ui.BtnTabTools.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
})

# ------------------------------------------------------------- bo loc ngay kho video ----
function Reset-DateFilterButtons {
    foreach ($b in @($ui.BtnFilterAllDate, $ui.BtnFilterToday, $ui.BtnFilterYesterday, $ui.BtnFilter7Days)) {
        $b.Background  = (New-Object Windows.Media.BrushConverter).ConvertFromString('#121824')
        $b.Foreground  = (New-Object Windows.Media.BrushConverter).ConvertFromString('#94A3B8')
        $b.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#253248')
    }
}

$ui.BtnFilterAllDate.Add_Click({
    Reset-DateFilterButtons
    $script:filterDate = 'all'
    $ui.BtnFilterAllDate.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#1E293B')
    $ui.BtnFilterAllDate.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#38BDF8')
    $ui.BtnFilterAllDate.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#3B82F6')
    $script:updatingCombo = $true; $ui.CmbFilterSpecificDate.SelectedIndex = 0; $script:updatingCombo = $false
    Update-Gallery
})

$ui.BtnFilterToday.Add_Click({
    Reset-DateFilterButtons
    $script:filterDate = 'today'
    $ui.BtnFilterToday.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#1E293B')
    $ui.BtnFilterToday.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#38BDF8')
    $ui.BtnFilterToday.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#3B82F6')
    $script:updatingCombo = $true; $ui.CmbFilterSpecificDate.SelectedIndex = 0; $script:updatingCombo = $false
    Update-Gallery
})

$ui.BtnFilterYesterday.Add_Click({
    Reset-DateFilterButtons
    $script:filterDate = 'yesterday'
    $ui.BtnFilterYesterday.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#1E293B')
    $ui.BtnFilterYesterday.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#38BDF8')
    $ui.BtnFilterYesterday.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#3B82F6')
    $script:updatingCombo = $true; $ui.CmbFilterSpecificDate.SelectedIndex = 0; $script:updatingCombo = $false
    Update-Gallery
})

$ui.BtnFilter7Days.Add_Click({
    Reset-DateFilterButtons
    $script:filterDate = '7days'
    $ui.BtnFilter7Days.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#1E293B')
    $ui.BtnFilter7Days.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#38BDF8')
    $ui.BtnFilter7Days.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#3B82F6')
    $script:updatingCombo = $true; $ui.CmbFilterSpecificDate.SelectedIndex = 0; $script:updatingCombo = $false
    Update-Gallery
})

$ui.CmbFilterSpecificDate.Add_SelectionChanged({
    if ($script:updatingCombo) { return }
    $sel = [string]$ui.CmbFilterSpecificDate.SelectedItem
    if ($sel -and $sel -notlike "*Lọc theo ngày*") {
        Reset-DateFilterButtons
        if ($sel -match '(\d{2})/(\d{2})/(\d{4})') {
            $script:filterDate = "$($Matches[3])-$($Matches[2])-$($Matches[1])"
        } elseif ($sel -match '(\d{4}-\d{2}-\d{2})') {
            $script:filterDate = $Matches[1]
        } else {
            $script:filterDate = $sel
        }
        Update-Gallery
    }
})

# ------------------------------------------------------------- bo loc tiktok ----
function Reset-TikTokFilterButtons {
    foreach ($b in @($ui.BtnFilterTikTokAll, $ui.BtnFilterTikTokUnposted, $ui.BtnFilterTikTokPosted)) {
        $b.Background  = (New-Object Windows.Media.BrushConverter).ConvertFromString('#121824')
        $b.Foreground  = (New-Object Windows.Media.BrushConverter).ConvertFromString('#94A3B8')
        $b.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#253248')
    }
}

$ui.BtnFilterTikTokAll.Add_Click({
    Reset-TikTokFilterButtons
    $script:filterTikTok = 'all'
    $ui.BtnFilterTikTokAll.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#1E293B')
    $ui.BtnFilterTikTokAll.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#38BDF8')
    $ui.BtnFilterTikTokAll.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#3B82F6')
    Update-Gallery
})

$ui.BtnFilterTikTokUnposted.Add_Click({
    Reset-TikTokFilterButtons
    $script:filterTikTok = 'unposted'
    $ui.BtnFilterTikTokUnposted.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#1E293B')
    $ui.BtnFilterTikTokUnposted.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#FBBF24')
    $ui.BtnFilterTikTokUnposted.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#F59E0B')
    Update-Gallery
})

$ui.BtnFilterTikTokPosted.Add_Click({
    Reset-TikTokFilterButtons
    $script:filterTikTok = 'posted'
    $ui.BtnFilterTikTokPosted.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#1E293B')
    $ui.BtnFilterTikTokPosted.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#34D399')
    $ui.BtnFilterTikTokPosted.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#10B981')
    Update-Gallery
})

$ui.BtnRefreshGallery.Add_Click({ Update-Gallery })

# ------------------------------------------------------------- cac nut cai dat thu vien ----
$ui.BtnInstallAllTools.Add_Click({ Install-ToolGUI 'all' })
$ui.BtnInstallScrcpy.Add_Click({   Install-ToolGUI 'scrcpy' })
$ui.BtnInstallAdb.Add_Click({      Install-ToolGUI 'adb' })
$ui.BtnInstallYtdlp.Add_Click({    Install-ToolGUI 'ytdlp' })
$ui.BtnInstallFfmpeg.Add_Click({   Install-ToolGUI 'ffmpeg' })
$ui.BtnInstallWhisper.Add_Click({  Install-ToolGUI 'whisper' })
$ui.BtnCheckTools.Add_Click({      Update-ToolsStatus })
$ui.BtnOpenUninstall.Add_Click({
    if ($script:ps) { Show-Toast 'Đang chạy tác vụ — không thể gỡ thư viện lúc này.'; return }
    $ans = [System.Windows.MessageBox]::Show(
        "Bạn có muốn gỡ bỏ toàn bộ bộ thư viện trong thư mục 'tools' để giải phóng dung lượng không?",
        "Kid FB.Y - Gỡ cài đặt bộ thư viện",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($ans -eq [System.Windows.MessageBoxResult]::Yes) {
        try {
            $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
            $tDir = [System.IO.Path]::GetFullPath((Join-Path $rootFull 'tools'))
            if (-not [string]::Equals([System.IO.Path]::GetDirectoryName($tDir).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar), $rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals([System.IO.Path]::GetFileName($tDir), 'tools', [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'Đường dẫn thư mục tools không nằm trực tiếp trong thư mục dự án.'
            }
            if (Test-Path -LiteralPath $tDir) { Remove-Item -LiteralPath $tDir -Recurse -Force -ErrorAction Stop }
            if (Test-Path -LiteralPath $tDir) { throw 'Một số tệp vẫn còn hoặc đang bị khóa.' }
            Update-ToolsStatus
            Show-Toast 'ĐÃ GỠ BỎ BỘ THƯ VIỆN'
            Add-Log 'Đã gỡ bỏ thư viện trong thư mục tools.' '#34D399'
        } catch {
            Show-Toast "Gỡ thư viện thất bại: $($_.Exception.Message)"
            Add-Log "Gỡ thư viện thất bại: $($_.Exception.Message)" '#F87171'
        }
    }
})

if ($ui.BtnCopyLog) {
    $ui.BtnCopyLog.Add_Click({
        try {
            $txt = if ($ui.TxtLog -and $ui.TxtLog.Text) { $ui.TxtLog.Text } else { $script:runLog }
            if (-not $txt -or -not $txt.Trim()) {
                Show-Toast "Chưa có log nào để sao chép!"
                return
            }
            [System.Windows.Clipboard]::SetText($txt)
            $origContent = $ui.BtnCopyLog.Content
            $ui.BtnCopyLog.Content = "✔ Đã sao chép!"
            Show-Toast "ĐÃ SAO CHÉP TOÀN BỘ LOG VÀO CLIPBOARD!"
            $tCopy = New-Object Windows.Threading.DispatcherTimer
            $tCopy.Interval = [TimeSpan]::FromSeconds(2.5)
            $tCopy.Add_Tick({
                $ui.BtnCopyLog.Content = $origContent
                $this.Stop()
            })
            $tCopy.Start()
        } catch {
            Show-Toast "Lỗi sao chép: $($_.Exception.Message)"
        }
    })
}

if ($ui.BtnClearLog) {
    $ui.BtnClearLog.Add_Click({
        if ($ui.TxtLog) { $ui.TxtLog.Clear() }
        $script:runLog = ''
        Show-Toast "ĐÃ XÓA NHẬT KÝ HỆ THỐNG!"
    })
}

# Dynamic Link Count Tracker
$ui.TxtLinks.Add_TextChanged({
    $lines = if (Get-Command Get-FacebookInputLinks -CommandType Function -ErrorAction SilentlyContinue) {
        @(Get-FacebookInputLinks -Text $ui.TxtLinks.Text)
    } else { @($ui.TxtLinks.Text -split "`r?`n" | Where-Object { $_ -match '\S' }) }
    if ($lines.Count -eq 0) {
        $ui.TxtQueueCount.Text = "Chưa có liên kết nào"
        $ui.TxtQueueCount.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#64748B')
    } else {
        $ui.TxtQueueCount.Text = "Đã nhận $($lines.Count) liên kết trong hàng đợi"
        $ui.TxtQueueCount.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#38BDF8')
    }
})

$ui.BtnPick.Add_Click({
    try {
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Chọn thư mục xuất video'
        if ($ui.TxtOut -and (Test-Path $ui.TxtOut.Text)) { $d.SelectedPath = $ui.TxtOut.Text }
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            if ($ui.TxtOut) { $ui.TxtOut.Text = $d.SelectedPath }
            Update-Gallery
        }
    } catch { }
})
$ui.SldLogoSize.Add_ValueChanged({
    $ui.TxtLogoSize.Text = ('{0}%' -f [int][Math]::Round($ui.SldLogoSize.Value))
})
$ui.CmbLogoMode.Add_SelectionChanged({
    $fixed = ($ui.CmbLogoMode.SelectedIndex -eq 1)
    $ui.PanelLogoPosition.Visibility = $(if ($fixed) { 'Visible' } else { 'Collapsed' })
    $ui.CmbLogoPosition.IsEnabled = ($ui.CmbLogoMode.IsEnabled -and $fixed)
})
$ui.SldLogoFade.Add_ValueChanged({
    $ui.TxtLogoFade.Text = ('{0}%' -f [int][Math]::Round($ui.SldLogoFade.Value))
})
function Set-LogoSelection {
    param([string]$Path)
    $stream = $null; $zip = $null
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $scriptDir 'kid-logo.zip'))
            $entry = $zip.GetEntry('kid-logo.png')
            if (-not $entry) { throw 'Không tìm thấy logo Kid.' }
            $stream = New-Object IO.MemoryStream
            $entryStream = $entry.Open()
            try { $entryStream.CopyTo($stream) } finally { $entryStream.Dispose() }
            $stream.Position = 0
        } else {
            $stream = [IO.File]::OpenRead($Path)
        }
        $bitmap = New-Object Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.DecodePixelWidth = 96
        $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.StreamSource = $stream
        $bitmap.EndInit()
        $bitmap.Freeze()
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($zip) { $zip.Dispose() }
    }
    $custom = -not [string]::IsNullOrWhiteSpace($Path)
    $ui.ImgLogoPreview.Source = $bitmap
    $ui.TxtLogoPath.Text = $(if ($custom) { $Path } else { '' })
    $ui.TxtLogoPath.ToolTip = $(if ($custom) { $Path } else { 'Đang dùng logo Kid có sẵn trong ứng dụng.' })
    $ui.TxtLogoPath.CaretIndex = 0
    $ui.TxtLogoPath.ScrollToHome()
    $ui.TxtLogoName.Text = $(if ($custom) { 'Đang dùng: ' + [IO.Path]::GetFileName($Path) } else { 'Đang dùng: Logo Kid' })
    $ui.TxtLogoName.ToolTip = $ui.TxtLogoPath.ToolTip
    $ui.TxtLogoDefaultHint.Visibility = $(if ($custom) { 'Collapsed' } else { 'Visible' })
    $ui.BtnDefaultLogo.Content = $(if ($custom) { 'Dùng Logo Kid' } else { '✓ Logo Kid' })
    $ui.BtnDefaultLogo.Background = $(if ($custom) { '#172033' } else { '#133A32' })
    $ui.BtnDefaultLogo.BorderBrush = $(if ($custom) { '#334155' } else { '#34D399' })
}
$ui.BtnDefaultLogo.Add_Click({
    try { Set-LogoSelection -Path '' } catch { Show-Toast 'Không đọc được logo Kid. Hãy cập nhật lại app.' }
})
$ui.BtnPickLogo.Add_Click({
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'PNG (*.png)|*.png'
    $dialog.CheckFileExists = $true
    if ($dialog.ShowDialog($win) -ne $true) { return }
    $image = $null
    $validPath = $null
    try {
        $image = [System.Drawing.Image]::FromFile($dialog.FileName)
        if ($image.RawFormat.Guid -ne [System.Drawing.Imaging.ImageFormat]::Png.Guid) {
            throw 'Không phải PNG.'
        }
        $validPath = $dialog.FileName
    } catch {
        Show-Toast 'PNG không hợp lệ hoặc không đọc được.'
        return
    } finally {
        if ($image) { $image.Dispose() }
    }
    try { Set-LogoSelection -Path $validPath } catch { Show-Toast 'Không đọc được ảnh PNG đã chọn.' }
})
try { Set-LogoSelection -Path '' } catch { Add-Log 'Không đọc được ảnh xem trước logo Kid.' '#F59E0B' }
function Open-FolderSafe([string]$targetPath) {
    try {
        if (-not $targetPath -or $targetPath.Trim() -eq '') {
            $targetPath = if ($ui.TxtOut -and $ui.TxtOut.Text) { $ui.TxtOut.Text } else { Join-Path $root 'output' }
        }
        $p = [System.IO.Path]::GetFullPath($targetPath)
        if (-not (Test-Path $p)) {
            New-Item -ItemType Directory -Path $p -Force -ErrorAction SilentlyContinue | Out-Null
        }
        [System.Diagnostics.Process]::Start("explorer.exe", "`"$p`"") | Out-Null
    } catch {
        try {
            Start-Process explorer.exe -ArgumentList "`"$targetPath`""
        } catch { }
    }
}

$ui.BtnOpenOut.Add_Click({ Open-FolderSafe $ui.TxtOut.Text })
$ui.BtnFolder.Add_Click({  Open-FolderSafe $ui.TxtOut.Text })
$ui.BtnCheck.Add_Click({
    try {
        if ($ui.BtnTabLogs) {
            $ui.BtnTabLogs.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        }
        Start-Engine -Links @() -Named @{ Check = $true } -Mode 'check'
    } catch { }
})
$ui.BtnStop.Add_Click({
    if (-not $script:ps) { return }
    Stop-Engine
    Add-Log ''; Add-Log 'Đã dừng theo yêu cầu của người dùng.' '#FBBF24'
})
$ui.BtnPlay.Add_Click({
    if ($ui.BtnPlay.Content -match 'Phát') {
        $ui.Player.Play()
        $ui.BtnPlay.Content = '⏸ Tạm dừng'
    } else {
        $ui.Player.Pause()
        $ui.BtnPlay.Content = '▶ Phát'
    }
})

# XU LY TUA VIDEO SIEU MUOT - KHONG BI LAG / DUOI CODEC
$ui.Seek.Add_PreviewMouseLeftButtonDown({
    $script:keoSeek = $true
    $script:wasPlaying = ($ui.BtnPlay.Content -match 'Tạm dừng')
    if ($script:wasPlaying) {
        $ui.Player.Pause()
    }
})

$ui.Seek.Add_PreviewMouseLeftButtonUp({
    if ($ui.Player.Source) {
        $targetSec = $ui.Seek.Value
        $ui.Player.Position = [TimeSpan]::FromSeconds($targetSec)
        $tot = if ($ui.Player.NaturalDuration.HasTimeSpan) { $ui.Player.NaturalDuration.TimeSpan.TotalSeconds } else { 0 }
        $strCur = ('{0}:{1:00}.{2}' -f [int][Math]::Floor($targetSec/60), [int]($targetSec%60), [int](($targetSec*10)%10))
        $strTot = ('{0}:{1:00}.{2}' -f [int][Math]::Floor($tot/60), [int]($tot%60), [int](($tot*10)%10))
        $ui.TxtTime.Text = "$strCur / $strTot"
    }
    if ($script:wasPlaying) {
        $ui.Player.Play()
    }
    Start-Sleep -Milliseconds 60
    $script:keoSeek = $false
})

$ui.Seek.Add_ValueChanged({
    if ($script:keoSeek -and $ui.Player.Source) {
        $targetSec = $ui.Seek.Value
        $tot = if ($ui.Player.NaturalDuration.HasTimeSpan) { $ui.Player.NaturalDuration.TimeSpan.TotalSeconds } else { 0 }
        $strCur = ('{0}:{1:00}.{2}' -f [int][Math]::Floor($targetSec/60), [int]($targetSec%60), [int](($targetSec*10)%10))
        $strTot = ('{0}:{1:00}.{2}' -f [int][Math]::Floor($tot/60), [int]($tot%60), [int](($tot*10)%10))
        $ui.TxtTime.Text = "$strCur / $strTot"
    }
})

$ui.Player.Add_MediaEnded({
    $ui.Player.Pause()
    $ui.BtnPlay.Content = '▶ Phát'
})

$ui.BtnTrackA.Add_Click({ Switch-AudioTrack 'A' })
$ui.BtnTrackB.Add_Click({ Switch-AudioTrack 'B' })

$ui.BtnCopyReup.Add_Click({
    if ($script:lastOut) { Copy-ToClipboard $script:lastOut }
})

$ui.BtnOpenExt.Add_Click({
    if ($script:lastOut -and (Test-Path $script:lastOut)) {
        Start-Process $script:lastOut
    }
})

$ui.BtnKeep.Add_Click({
    if ($script:ps) { Show-Toast 'Hãy đợi tác vụ đang chạy hoàn tất.'; return }
    if (-not $script:queue -or $script:queue.Count -eq 0 -or $script:idx -lt 0 -or $script:idx -ge $script:queue.Count) { Show-Toast 'Không có video đang nghiệm thu trong hàng đợi.'; return }
    $ui.PanelRev.Visibility = 'Collapsed'
    $script:giu++
    Add-Log "Đã giữ: $($script:lastOut)" '#34D399'
    Next-Link
})

$ui.BtnRedo.Add_Click({
    if ($script:ps) { Show-Toast 'Hãy đợi tác vụ đang chạy hoàn tất.'; return }
    if (-not $script:queue -or $script:queue.Count -eq 0 -or $script:idx -lt 0 -or $script:idx -ge $script:queue.Count) {
        Show-Toast 'Chỉ ghi âm lại video đang nghiệm thu trong hàng đợi.'
        return
    }
    $redoFile = $script:lastOut
    $ui.PanelRev.Visibility = 'Collapsed'
    Clear-Player
    Add-Log 'Chuẩn bị ghi âm lại video đang nghiệm thu...' '#FBBF24'
    Start-Link
})

$ui.BtnDeleteCurrent.Add_Click({
    if (-not $script:lastOut) { return }
    $delPath = $script:lastOut
    $ans = [System.Windows.MessageBox]::Show(
        "Bạn có chắc chắn muốn xóa bản video này không?`n`nFile: $(Split-Path $delPath -Leaf)",
        "Xác nhận xóa video",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($ans -eq [System.Windows.MessageBoxResult]::Yes) {
        Clear-Player
        Remove-ReelFiles $delPath
        Show-Toast "ĐÃ XÓA VIDEO HOÀN TẤT"
        Add-Log "Đã xóa video: $delPath" '#F87171'
        Update-Gallery
    }
})

$ui.BtnSkip.Add_Click({
    if ($script:ps) { Show-Toast 'Hãy đợi tác vụ đang chạy hoàn tất.'; return }
    if (-not $script:queue -or $script:queue.Count -eq 0 -or $script:idx -lt 0 -or $script:idx -ge $script:queue.Count) { Show-Toast 'Không có video đang nghiệm thu trong hàng đợi.'; return }
    $ui.PanelRev.Visibility = 'Collapsed'
    Clear-Player
    $script:bo++
    Add-Log 'Bỏ qua video này.' '#94A3B8'
    Next-Link
})

$ui.BtnStart.Add_Click({
    if ($script:ps) { Show-Toast 'Đang chạy tác vụ — hãy đợi hoàn tất.'; return }
    if ($script:queue -and $script:queue.Count -gt 0) { Show-Toast 'Hãy hoàn tất hoặc bỏ qua hàng đợi đang nghiệm thu trước khi bắt đầu.'; return }
    $links = @()
    if (Get-Command Get-FacebookInputLinks -CommandType Function -ErrorAction SilentlyContinue) {
        $links = @(Get-FacebookInputLinks -Text $ui.TxtLinks.Text)
    } else {
        foreach ($l in ($ui.TxtLinks.Text -split "`r?`n")) {
            $t = $l.Trim().Trim('"').Trim("'").Trim()
            if ($t -match '\S') { $links += $t }
        }
    }
    if ($links.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Chưa tìm thấy URL Facebook hợp lệ. Dán link video, Reel hoặc share/r vào ô phía trên.',
            'Thiếu link','OK','Information') | Out-Null
        return
    }
    $xau = @($links | Where-Object { $_ -notmatch 'facebook\.com|fb\.watch' })
    if ($xau.Count -gt 0) {
        $r = [System.Windows.MessageBox]::Show("Có $($xau.Count) dòng không có định dạng link Facebook. Vẫn tiếp tục?",
            'Kiểm tra lại link','YesNo','Warning')
        if ($r -ne 'Yes') { return }
    }
    if (-not (Test-Path $ui.TxtOut.Text)) { New-Item -ItemType Directory -Path $ui.TxtOut.Text -Force | Out-Null }
    if ($ui.TxtLog) { $ui.TxtLog.Clear() }; $script:runLog = ''
    $script:queue = $links; $script:idx = 0; $script:giu = 0; $script:bo = 0
    Start-Link
})

# ------------------------------------------------------------- cap nhat qua GitHub ----
$script:updProc = $null; $script:updMode = ''; $script:updSilent = $false
if ($ui.BtnUpdate) { $ui.BtnUpdate.ToolTip = "Phiên bản hiện tại: v$($script:verLocal) — bấm để kiểm tra bản mới" }
$tUpd = New-Object Windows.Threading.DispatcherTimer
$tUpd.Interval = [TimeSpan]::FromMilliseconds(400)

function Start-UpdateJob([string]$Mode, [bool]$Silent = $false) {
    if ($script:updProc) { return }
    $upd = Join-Path $scriptDir 'updater.ps1'
    if (-not (Test-Path $upd)) { if (-not $Silent) { Show-Toast 'Thiếu file updater.ps1' }; return }
    $script:updMode = $Mode; $script:updSilent = $Silent
    if ($ui.BtnUpdate) { $ui.BtnUpdate.IsEnabled = $false; $ui.BtnUpdate.Content = if ($Mode -eq 'check') { '⏳ Đang kiểm tra...' } else { '⏳ Đang tải...' } }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$upd`" -Mode $Mode"
    $psi.CreateNoWindow = $true; $psi.UseShellExecute = $false
    $script:updProc = [System.Diagnostics.Process]::Start($psi)
    $tUpd.Start()
}

$tUpd.Add_Tick({
    if (-not $script:updProc -or -not $script:updProc.HasExited) { return }
    $tUpd.Stop(); $script:updProc = $null
    if ($ui.BtnUpdate) { $ui.BtnUpdate.IsEnabled = $true; $ui.BtnUpdate.Content = '🔄 Cập nhật' }
    $st = $null
    try { $st = Get-Content (Join-Path $scriptDir '_update\status.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    if (-not $st -or -not $st.ok) {
        $err = if ($st) { $st.error } else { 'Không đọc được kết quả' }
        if (-not $script:updSilent) {
            [System.Windows.MessageBox]::Show("Không kiểm tra/tải được bản cập nhật:`n`n$err", 'Kid FB.Y - Cập nhật', 'OK', 'Warning') | Out-Null
        }
        return
    }
    if ($script:updMode -eq 'check') {
        if (-not $st.hasUpdate) {
            if (-not $script:updSilent) { Show-Toast "ĐANG DÙNG BẢN MỚI NHẤT (v$($script:verLocal))" }
            return
        }
        if ($ui.BtnUpdate) { $ui.BtnUpdate.Content = "🔔 Có bản v$($st.remote)" }
        if ($script:updSilent -and -not $st.mandatory) { Add-Log "Có bản cập nhật mới v$($st.remote) — bấm nút Cập nhật để cài." '#34D399'; return }
        if ($script:ps) { Show-Toast 'Đang chạy tác vụ — cập nhật sau khi xong'; return }
        $log = (@($st.changelog) | ForEach-Object { "  • $_" }) -join "`n"
        $kb = [math]::Round(([double]$st.size) / 1KB, 0)
        $r = [System.Windows.MessageBox]::Show("Có bản mới v$($st.remote) (hiện tại v$($st.local)).`n`nThay đổi:`n$log`n`nDung lượng: ~$kb KB. Cập nhật ngay?",
            'Kid FB.Y - Cập nhật', 'YesNo', 'Question')
        if ($r -eq 'Yes') { Start-UpdateJob 'download' $false }
        return
    }
    if ($script:updMode -eq 'download' -and $st.ready) {
        [System.Windows.MessageBox]::Show("Đã tải xong bản v$($st.remote).`nTool sẽ khởi động lại để áp dụng.", 'Kid FB.Y - Cập nhật', 'OK', 'Information') | Out-Null
        $exe = Join-Path $root 'Kid-FB.Y.exe'
        if (Test-Path $exe) {
            Start-Process -FilePath $exe -WorkingDirectory $root
            $win.Close()
        } else {
            [System.Windows.MessageBox]::Show('Không tìm thấy Kid-FB.Y.exe. Hãy mở lại tool bằng Kid-FB.Y.exe để áp dụng bản mới.', 'Kid FB.Y', 'OK', 'Warning') | Out-Null
        }
    }
})

if ($ui.BtnUpdate) {
    $ui.BtnUpdate.Add_Click({
        if ($script:ps) { Show-Toast 'Đang chạy tác vụ — hãy Dừng hoặc đợi xong rồi cập nhật'; return }
        Start-UpdateJob 'check' $false
    })
}

$win.Add_Closing({ param($sender,$eventArgs)
    if ($script:ps) {
        $eventArgs.Cancel = $true
        $script:closeAfterStop = $true
        Stop-Engine
        return
    }
    try { if ($tUpd) { $tUpd.Stop() } } catch { }
    try { Stop-Engine } catch { }
    try { if ($tPlay) { $tPlay.Stop() } } catch { }
    try { if ($timer) { $timer.Stop() } } catch { }
    try { if ($script:tToast) { $script:tToast.Stop() } } catch { }
})

try {
    # ------------------------------------------------------------------ chay ----
    if (-not (Test-Path $engine)) {
        if ($SelfTest) { throw "Khong tim thay engine: $engine" }
        [System.Windows.MessageBox]::Show("Không tìm thấy kid-fby.ps1 cạnh file này.`n`n$engine",
            'Thiếu file','OK','Error') | Out-Null
        return
    }
    # Auto scan gallery va tools on launch
    Update-Gallery
    Update-ToolsStatus

    if ($SelfTest) {
        foreach ($k in $ui.Keys) {
            if ($null -eq $ui[$k]) { throw "Thieu thanh phan giao dien: $k" }
        }
        if ($ui.TxtOut.Text -ne (Join-Path $root 'output')) { throw 'Thu muc xuat khoi tao khong dung.' }
        if ($ui.TxtAppVersion.Text -ne "v$($script:verLocal)") { throw 'Nhan phien ban khoi tao khong dung.' }
        $ud = Join-Path $scriptDir '_update'
        if (-not (Test-Path -LiteralPath $ud)) { New-Item -ItemType Directory -Path $ud -Force | Out-Null }
        [System.IO.File]::WriteAllText((Join-Path $ud 'BOOT_OK'), (Get-Date).ToString('o'))
        Write-Host "SelfTest: Kid FB.Y khoi tao thanh cong, $($ui.Keys.Count) thanh phan giao dien"
        return
    }

    # Auto preview latest finished video if available
    $latestVid = Get-ChildItem -Path $ui.TxtOut.Text -Filter '*-3-hoan-chinh.mp4' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestVid -and (Test-Path $latestVid.FullName)) {
        Load-Player $latestVid.FullName
        $ui.TxtRev.Text = "Đang xem lại tác phẩm hoàn tất gần nhất: $($latestVid.Name)"
        $ui.BtnKeep.Visibility = 'Collapsed'
        $ui.BtnRedo.Content = '🔄 Ghi âm lại'
        $ui.PanelRev.Visibility = 'Visible'
    } else {
        Clear-Player
    }

    $icoFile = Join-Path $root 'Kid-FB.Y.ico'
    if (-not (Test-Path $icoFile)) { $icoFile = Join-Path $scriptDir 'Kid-FB.Y.ico' }
    if (Test-Path $icoFile) {
        try {
            $win.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri([System.IO.Path]::GetFullPath($icoFile))))
        } catch { }
    }

    $win.Add_ContentRendered({
        # Bao cho launcher biet ban hien tai khoi dong OK (de khong rollback)
        try {
            $ud = Join-Path $scriptDir '_update'
            if (-not (Test-Path $ud)) { New-Item -ItemType Directory -Path $ud -Force | Out-Null }
            [System.IO.File]::WriteAllText((Join-Path $ud 'BOOT_OK'), (Get-Date).ToString('o'))
        } catch { }
        try {
            if ($ui.BtnCheck) {
                $ui.BtnCheck.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            }
        } catch { }
        try { Start-UpdateJob 'check' $true } catch { }
    })
    [void]$win.ShowDialog()
} catch {
    if ($SelfTest) { Write-Error $_ -ErrorAction Continue; exit 1 }
    [System.Windows.MessageBox]::Show("Đã xảy ra sự cố giao diện:`n`n$($_.Exception.Message)", "Kid FB.Y", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
}
