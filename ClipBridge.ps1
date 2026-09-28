<#
ClipBridge - share the clipboard between a Windows PC and an iPhone over your home Wi-Fi.

The iPhone side is a few Apple Shortcuts that call this small HTTP server:

  GET  /clip?t=TOKEN        The PC clipboard: text, a picture (as PNG), a copied file,
                            or several copied files/folders as one .zip
  GET  /clip?t=TOKEN&new=1  The same, but an empty reply if nothing new was copied on the PC
  POST /clip?t=TOKEN        Body is text (it becomes the PC clipboard) or a file (as below)
  POST /file?t=TOKEN        Body is a file; optional header X-Filename: <name>. It is saved to
                            Downloads\From iPhone and put on the PC clipboard, so Ctrl+V pastes
                            it in Explorer, chat apps, email and so on

The token can also be sent in an X-Token header instead of ?t=.

ClipBridge shows a tray icon instead of a console window and writes its messages to
%LOCALAPPDATA%\ClipBridge\clipbridge.log. Starting it again replaces the copy that is running,
and it restarts itself when this file changes. Needs only Windows PowerShell 5.1, no admin rights.

  ClipBridge.ps1 [-Port 8765]    Run it (Start_ClipBridge.bat starts it hidden)
  ClipBridge.ps1 -Install        Start it automatically at sign-in (Install_ClipBridge.bat)
  ClipBridge.ps1 -Uninstall      Remove it from startup and stop it (Uninstall_ClipBridge.bat)
#>
param(
    [int]$Port = 8765,
    [switch]$Install,
    [switch]$Uninstall
)

#region Paths and state ------------------------------------------------------------------------

$DefaultPort   = 8765
$SelfPath      = $PSCommandPath
$Here          = Split-Path -Parent $SelfPath
$TokenFile     = Join-Path $Here 'clipbridge-token.txt'     # private, kept out of git
$UrlFile       = Join-Path $Here 'clipbridge-url.txt'       # private, kept out of git
$DataDir       = Join-Path $env:LOCALAPPDATA 'ClipBridge'
$LogFile       = Join-Path $DataDir 'clipbridge.log'
$OldLogFile    = Join-Path $DataDir 'clipbridge.old.log'
$SettingsFile  = Join-Path $DataDir 'settings.json'
$TempDir       = Join-Path ([IO.Path]::GetTempPath()) 'ClipBridge'
$StartupDir    = [Environment]::GetFolderPath('Startup')
$StartupLink   = Join-Path $StartupDir 'ClipBridge.lnk'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$QuitEventName = 'Local\ClipBridge.Quit'   # a newer copy or the uninstaller sets it to ask us to quit
$LogMaxBytes   = 512KB                     # plus one old log, so about 1 MB at most
$Utf8NoBom     = New-Object Text.UTF8Encoding($false)

# Content types for files sent to the phone. Also used the other way round to pick an extension
# for unnamed uploads, so the first extension listed for a type wins.
$MimeTypes = [ordered]@{
    '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.png' = 'image/png'; '.gif' = 'image/gif'
    '.heic' = 'image/heic'; '.webp' = 'image/webp'; '.pdf' = 'application/pdf'; '.txt' = 'text/plain'
    '.zip' = 'application/zip'; '.mp4' = 'video/mp4'; '.mov' = 'video/quicktime'; '.mp3' = 'audio/mpeg'
    '.m4a' = 'audio/mp4'
    '.docx' = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
    '.xlsx' = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
    '.pptx' = 'application/vnd.openxmlformats-officedocument.presentationml.presentation'
}

$script:Token             = $null
$script:Inbox             = $null        # Downloads\From iPhone
$script:Settings          = @{ Notifications = $false }
$script:Tray              = $null        # the NotifyIcon
$script:Menu              = $null
$script:AppIcon           = $null
$script:NotifyItem        = $null        # the "Notifications" menu item
$script:Listener          = $null        # $null while the port can't be used
$script:ListenError       = $null
$script:NextListenAttempt = [datetime]::MinValue
$script:QuitEvent         = $null
$script:ExitAction        = $null        # 'Quit' or 'Restart', set from the tray menu
$script:Addresses         = @()          # this PC's IPv4 addresses, best first
$script:AddressKey        = $null
$script:LastTransfer      = $null
$script:IsFirstRun        = $false
$script:Buffer            = New-Object byte[] 262144

# For "new=1": the clipboard sequence number (it goes up on every copy) the phone is up to date with
$script:PhoneSeq = 0
# Fingerprints of recent content in either direction, so repeats from the phone are ignored
$script:Seen = New-Object 'System.Collections.Generic.List[string]'
# Files that arrive within a few seconds of each other go on the clipboard together
$script:Batch = New-Object System.Collections.Specialized.StringCollection
$script:LastFileAt = [datetime]::MinValue

#endregion

#region Log and settings -----------------------------------------------------------------------

function Write-Log([string]$Message, [string]$Level = 'INFO') {
    # There is no console window, so transfers and errors are written here instead.
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1,-5}  {2}' -f (Get-Date), $Level, $Message
    try {
        [void][IO.Directory]::CreateDirectory($DataDir)
        $file = New-Object IO.FileInfo $LogFile
        if ($file.Exists -and $file.Length -gt $LogMaxBytes) {
            [IO.File]::Delete($OldLogFile)
            [IO.File]::Move($LogFile, $OldLogFile)
        }
        [IO.File]::AppendAllText($LogFile, $line + "`r`n", $Utf8NoBom)
    } catch { }   # a logging problem must never stop ClipBridge
}

function Get-ErrorText($ErrorRecord) {
    # PowerShell wraps .NET errors; the innermost exception has the useful message
    $e = $ErrorRecord.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    $e.Message
}

function Read-Settings {
    $settings = @{ Notifications = $false }
    try {
        if (Test-Path -LiteralPath $SettingsFile) {
            $saved = [IO.File]::ReadAllText($SettingsFile) | ConvertFrom-Json
            if ($null -ne $saved.Notifications) { $settings.Notifications = [bool]$saved.Notifications }
        }
    } catch { Write-Log ('Could not read settings, using defaults: {0}' -f (Get-ErrorText $_)) 'WARN' }
    $settings
}

function Save-Settings {
    try { [IO.File]::WriteAllText($SettingsFile, ([pscustomobject]$script:Settings | ConvertTo-Json), $Utf8NoBom) }
    catch { Write-Log ('Could not save settings: {0}' -f (Get-ErrorText $_)) 'WARN' }
}

#endregion

#region Starting, stopping, install and uninstall ----------------------------------------------

function Get-LaunchArguments {
    # One command line for every way ClipBridge gets started (Startup shortcut, Restart, self-update),
    # so a custom -Port survives restarts
    $list = @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $SelfPath))
    if ($Port -ne $DefaultPort) { $list += @('-Port', [string]$Port) }
    $list
}

function Start-ClipBridgeProcess {
    # Start-Process -WindowStyle Hidden creates the console hidden from the start, so nothing flashes
    Start-Process -FilePath $PowerShellExe -ArgumentList (Get-LaunchArguments) -WindowStyle Hidden -WorkingDirectory $Here
}

function Get-OtherInstances {
    # Other PowerShell processes running this script: an older copy, or one started from another
    # folder. The short-lived -Install/-Uninstall helpers are left alone.
    $scriptName = Split-Path -Leaf $SelfPath
    try {
        @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like "*$scriptName*" -and $_.CommandLine -notmatch '\s-(Install|Uninstall)\b' })
    } catch {
        Write-Log ('Could not list running programs: {0}' -f (Get-ErrorText $_)) 'WARN'
    }
}

function Stop-OtherInstances {
    # Returns how many were stopped.
    $others = @(Get-OtherInstances)
    if ($others.Count -eq 0) { return 0 }
    # Ask them to quit on their own first, so they remove their tray icons: a killed process leaves
    # a "ghost" icon behind. Copies that don't react (older versions, or one busy with a long
    # transfer) are killed after a few seconds.
    $quit = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, $QuitEventName)
    try {
        [void]$quit.Set()
        $deadline = [datetime]::UtcNow.AddSeconds(4)
        foreach ($other in $others) {
            $process = Get-Process -Id $other.ProcessId -ErrorAction SilentlyContinue
            if (-not $process) { continue }
            $wait = [int][Math]::Max(0, ($deadline - [datetime]::UtcNow).TotalMilliseconds)
            if (-not $process.WaitForExit($wait)) {
                Stop-Process -Id $other.ProcessId -Force -ErrorAction SilentlyContinue
                [void]$process.WaitForExit(2000)
            }
        }
    } finally {
        [void]$quit.Reset()
        $quit.Dispose()
    }
    $others.Count
}

function Install-ClipBridge {
    if ($Here -match '\\AppData\\Local\\Temp\\' -or $Here.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Write-Host 'ClipBridge seems to be running from inside the ZIP file or a temporary folder.' -ForegroundColor Yellow
        Write-Host 'Extract the ZIP to a folder you will keep (for example Documents\ClipBridge),'
        Write-Host 'then run Install_ClipBridge.bat from there.'
        return $false
    }
    # Older versions put ClipBridge.bat in the Startup folder, which opens a window at sign-in
    $legacy = Join-Path $StartupDir 'ClipBridge.bat'
    if (Test-Path -LiteralPath $legacy) { Remove-Item -LiteralPath $legacy -Force }

    # A shortcut can't start a program hidden, but "minimized" plus -WindowStyle Hidden keeps it off
    # the screen. (A .bat in Startup would open a console or Windows Terminal window first.)
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($StartupLink)
    $shortcut.TargetPath = $PowerShellExe
    $shortcut.Arguments = (Get-LaunchArguments) -join ' '
    $shortcut.WorkingDirectory = $Here
    $shortcut.WindowStyle = 7
    $shortcut.Description = 'ClipBridge: share the clipboard with your iPhone'
    $shortcut.Save()
    Write-Log ('Installed: added {0} to the Startup folder' -f (Split-Path -Leaf $StartupLink))

    Start-ClipBridgeProcess
    Write-Host ''
    Write-Host 'ClipBridge is installed and running.' -ForegroundColor Green
    Write-Host ' - It starts automatically when you sign in to Windows.'
    Write-Host ' - Its clipboard icon is in the system tray, next to the clock. If you don''t see it,'
    Write-Host '   click the ^ arrow there. You can drag the icon onto the taskbar to keep it visible.'
    Write-Host ' - Click the icon and choose "Copy iPhone URL" to set up your iPhone.'
    Write-Host ''
    Write-Host 'If Windows asks whether Windows PowerShell may use your network, tick'
    Write-Host '"Private networks" and click Allow. Otherwise your iPhone can''t connect.'
    $true
}

function Uninstall-ClipBridge {
    foreach ($entry in @($StartupLink, (Join-Path $StartupDir 'ClipBridge.bat'))) {
        if (Test-Path -LiteralPath $entry) { Remove-Item -LiteralPath $entry -Force }
    }
    $stopped = Stop-OtherInstances
    Write-Log 'Uninstalled: removed from the Startup folder'
    Write-Host ''
    Write-Host 'ClipBridge was removed from Windows startup.' -ForegroundColor Green
    if ($stopped) { Write-Host 'The running copy was stopped.' } else { Write-Host 'It was not running.' }
    Write-Host ''
    Write-Host 'Files you received are still in Downloads\From iPhone.'
    Write-Host 'To remove ClipBridge completely, also delete this folder and'
    Write-Host ('{0} (log and settings).' -f $DataDir)
}

#endregion

#region Token, folders and network addresses ---------------------------------------------------

function Get-Token {
    # The token is the password in the iPhone Shortcuts' URLs, so an existing one is always kept.
    if (Test-Path -LiteralPath $TokenFile) {
        $saved = [IO.File]::ReadAllText($TokenFile).Trim()   # '' (not $null) for an empty file
        if ($saved) { return $saved }
        # An empty token would switch the check off, so make a new one instead
        Write-Log 'The token file was empty, so a new token was created. Update the URLs in your iPhone Shortcuts.' 'WARN'
    }
    $alphabet = 'abcdefghijkmnpqrstuvwxyz23456789'   # 32 characters without look-alikes (l/1, o/0)
    $bytes = New-Object byte[] 16
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($bytes) } finally { $random.Dispose() }
    $token = -join ($bytes | ForEach-Object { $alphabet[$_ % 32] })   # 256 is a multiple of 32: no bias
    [IO.File]::WriteAllText($TokenFile, $token)
    $script:IsFirstRun = $true
    $token
}

function Get-DownloadsFolder {
    # Ask Windows where Downloads is, because it can be moved (for example to another drive)
    try {
        $path = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
        if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    } catch { }
    Join-Path $env:USERPROFILE 'Downloads'
}

function Clear-TempFolder {
    # Leftovers from transfers that were interrupted while ClipBridge was not running
    Get-ChildItem -LiteralPath $TempDir -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-LanAddresses {
    # IPv4 addresses the iPhone might use to reach this PC, best guess first: adapters with a router
    # (default gateway) first, Wi-Fi before Ethernet, and VPN or virtual adapters last.
    $virtual = 'virtual|vpn|hyper-v|vethernet|vmware|virtualbox|vbox|wsl|docker|tailscale|zerotier|hamachi|wireguard|wintun|nordlynx|openvpn|cloudflare|\btap\b|\btun\b|loopback|bluetooth'
    $found = foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up' -or $nic.NetworkInterfaceType -eq 'Loopback') { continue }
        $properties = $nic.GetIPProperties()
        $hasRouter = [bool]($properties.GatewayAddresses | Where-Object {
            $_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address.ToString() -ne '0.0.0.0' })
        foreach ($unicast in $properties.UnicastAddresses) {
            if ($unicast.Address.AddressFamily -ne 'InterNetwork') { continue }
            $text = $unicast.Address.ToString()
            if ($text.StartsWith('127.') -or $text.StartsWith('169.254.')) { continue }
            $score = 0
            if ($hasRouter) { $score += 4 }
            if ($nic.NetworkInterfaceType -eq 'Wireless80211') { $score += 2 }
            elseif ($nic.NetworkInterfaceType -eq 'Ethernet') { $score += 1 }
            if (('{0} {1}' -f $nic.Name, $nic.Description) -match $virtual) { $score -= 8 }
            [pscustomobject]@{ Address = $text; Adapter = $nic.Name; Score = $score }
        }
    }
    @($found | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, 'Address')
}

function Get-PhoneUrl([string]$Address) {
    'http://{0}:{1}/clip?t={2}' -f $Address, $Port, $script:Token
}

function Update-Addresses {
    # Called at startup and every 30 seconds, since the PC may switch networks
    try { $found = @(Get-LanAddresses) }
    catch { Write-Log ('Could not read the network addresses: {0}' -f (Get-ErrorText $_)) 'WARN'; return }
    $key = ($found | ForEach-Object { $_.Address }) -join ', '
    if ($key -eq $script:AddressKey) { return }
    $script:AddressKey = $key
    $script:Addresses = $found
    if ($found.Count) {
        Write-Log ('Network addresses: {0}' -f (($found | ForEach-Object { '{0} ({1})' -f $_.Address, $_.Adapter }) -join ', '))
    } else {
        Write-Log 'No network connection found, so the iPhone cannot reach this PC right now' 'WARN'
    }
    Write-UrlFile
    Update-TrayStatus
}

function Write-UrlFile {
    # A handy reference next to the script. It contains the token, so it is kept out of git.
    $best = @($script:Addresses)[0]
    $base = 'http://{0}:{1}' -f $(if ($best) { $best.Address } else { 'YOUR-PC-IP' }), $Port
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add(('ClipBridge is running on port {0}.' -f $Port))
    $lines.Add('')
    $lines.Add('URLs for your iPhone Shortcuts:')
    $lines.Add(('  PC Paste:    GET  {0}/clip?t={1}&new=1' -f $base, $script:Token))
    $lines.Add(('  Send to PC:  POST {0}/clip?t={1}' -f $base, $script:Token))
    $lines.Add(('  File to PC:  POST {0}/file?t={1}   (header X-Filename = file name)' -f $base, $script:Token))
    $lines.Add('')
    $lines.Add('Network addresses of this PC (the first one is most likely the right one):')
    foreach ($entry in $script:Addresses) { $lines.Add(('  {0}  ({1})' -f $entry.Address, $entry.Adapter)) }
    if (-not $best) { $lines.Add('  none found - is this PC connected to Wi-Fi or a network cable?') }
    $lines.Add('')
    $lines.Add(('Files from the iPhone are saved in: {0}' -f $script:Inbox))
    $lines.Add(('Log file: {0}' -f $LogFile))
    try { [IO.File]::WriteAllLines($UrlFile, $lines) }
    catch { Write-Log ('Could not write {0}: {1}' -f $UrlFile, (Get-ErrorText $_)) 'WARN' }
}

#endregion

#region Tray icon ------------------------------------------------------------------------------

function New-RoundedRectangle([single]$X, [single]$Y, [single]$Width, [single]$Height, [single]$Radius) {
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $d = $Radius * 2
    $path.AddArc($X, $Y, $d, $d, 180, 90)
    $path.AddArc($X + $Width - $d, $Y, $d, $d, 270, 90)
    $path.AddArc($X + $Width - $d, $Y + $Height - $d, $d, $d, 0, 90)
    $path.AddArc($X, $Y + $Height - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $path
}

function New-ClipBridgeIcon {
    # Drawn in code so there are no image files to ship: a blue clipboard holding a sheet of paper
    $bitmap = New-Object Drawing.Bitmap 32, 32
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $blue = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(37, 99, 235))
    $dark = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(30, 41, 59))
    $pen = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(37, 99, 235)), 2
    $board = New-RoundedRectangle 4 4 24 26 4
    $clip = New-RoundedRectangle 10 1 12 7 2
    try {
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.FillPath($blue, $board)
        $graphics.FillRectangle([Drawing.Brushes]::White, 8, 10, 16, 16)
        $graphics.DrawLine($pen, 11, 14, 21, 14)
        $graphics.DrawLine($pen, 11, 18, 21, 18)
        $graphics.DrawLine($pen, 11, 22, 17, 22)
        $graphics.FillPath($dark, $clip)
        $handle = $bitmap.GetHicon()
        # The clone owns a copy of the icon, so the handle from GetHicon can be freed right away
        try { ([Drawing.Icon]::FromHandle($handle)).Clone() }
        finally { [void][ClipBridge.Native]::DestroyIcon($handle) }
    } finally {
        foreach ($item in @($graphics, $bitmap, $blue, $dark, $pen, $board, $clip)) { $item.Dispose() }
    }
}

function New-Tray {
    $script:AppIcon = New-ClipBridgeIcon
    $menu = New-Object Windows.Forms.ContextMenuStrip

    $copyUrl = New-Object Windows.Forms.ToolStripMenuItem 'Copy iPhone URL'
    $copyUrl.Font = New-Object Drawing.Font($copyUrl.Font, [Drawing.FontStyle]::Bold)
    $copyUrl.add_Click({ Invoke-MenuAction 'CopyUrl' })
    $openInbox = New-Object Windows.Forms.ToolStripMenuItem 'Open received files'
    $openInbox.add_Click({ Invoke-MenuAction 'OpenInbox' })
    $showLog = New-Object Windows.Forms.ToolStripMenuItem 'Show log'
    $showLog.add_Click({ Invoke-MenuAction 'ShowLog' })
    $script:NotifyItem = New-Object Windows.Forms.ToolStripMenuItem 'Notifications'
    $script:NotifyItem.CheckOnClick = $true
    $script:NotifyItem.Checked = [bool]$script:Settings.Notifications   # before the handler is added
    $script:NotifyItem.add_CheckedChanged({ Invoke-MenuAction 'Notifications' })
    $restart = New-Object Windows.Forms.ToolStripMenuItem 'Restart'
    $restart.add_Click({ Invoke-MenuAction 'Restart' })
    $quit = New-Object Windows.Forms.ToolStripMenuItem 'Quit'
    $quit.add_Click({ Invoke-MenuAction 'Quit' })

    $menu.Items.AddRange([Windows.Forms.ToolStripItem[]]@(
        $copyUrl, $openInbox, $showLog,
        (New-Object Windows.Forms.ToolStripSeparator), $script:NotifyItem,
        (New-Object Windows.Forms.ToolStripSeparator), $restart, $quit))
    $script:Menu = $menu

    $script:Tray = New-Object Windows.Forms.NotifyIcon
    $script:Tray.Icon = $script:AppIcon
    $script:Tray.Text = 'ClipBridge: starting...'
    $script:Tray.ContextMenuStrip = $menu
    # A left-click opens the same menu as a right-click, since many people left-click tray icons
    $script:Tray.add_MouseClick({
        param($sender, $e)
        if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) { Invoke-MenuAction 'ShowMenu' }
    })
    $script:Tray.Visible = $true
}

function Update-TrayStatus {
    # Tooltip, e.g. "ClipBridge: running on 192.168.1.23:8765" plus the time of the last transfer
    if (-not $script:Tray) { return }
    if ($script:Listener) {
        $best = @($script:Addresses)[0]
        $status = if ($best) { 'ClipBridge: running on {0}:{1}' -f $best.Address, $Port } else { 'ClipBridge: running, but no network' }
        $icon = $script:AppIcon
    } elseif ($script:ListenError) {
        $status = 'ClipBridge: {0}' -f $script:ListenError
        $icon = [Drawing.SystemIcons]::Warning
    } else {
        $status = 'ClipBridge: starting...'
        $icon = $script:AppIcon
    }
    if ($script:LastTransfer) {
        $format = if ($script:LastTransfer.Date -eq (Get-Date).Date) { 'HH:mm:ss' } else { 'MMM d, HH:mm' }
        $status += "`nLast transfer: " + $script:LastTransfer.ToString($format)
    }
    if ($status.Length -gt 63) { $status = $status.Substring(0, 63) }   # Windows' limit for tray tooltips
    if ($script:Tray.Text -ne $status) { $script:Tray.Text = $status }
    if ($script:Tray.Icon -ne $icon) { $script:Tray.Icon = $icon }
}

function Show-Balloon([string]$Text, [Windows.Forms.ToolTipIcon]$Icon = 'Info', [switch]$Always) {
    # Transfer messages follow the Notifications setting; -Always is for answers to a click and for problems
    if (-not $script:Tray -or -not $Text) { return }
    if (-not $Always -and -not $script:Settings.Notifications) { return }
    $script:Tray.ShowBalloonTip(5000, 'ClipBridge', $Text, $Icon)
}

function Complete-Transfer([string]$Message) {
    Write-Log $Message
    $script:LastTransfer = Get-Date
    Update-TrayStatus
    Show-Balloon $Message
}

function Invoke-MenuAction([string]$Action) {
    # Runs inside DoEvents. Quit and Restart only set a flag: the main loop acts on it between
    # requests, so they never cut into a transfer.
    try {
        switch ($Action) {
            'ShowMenu' {
                # NotifyIcon only opens its menu by itself on a right-click. This private method is what
                # it calls then; it also makes the menu close again when you click somewhere else.
                $show = [Windows.Forms.NotifyIcon].GetMethod('ShowContextMenu', [Reflection.BindingFlags]'Instance, NonPublic')
                [void]$show.Invoke($script:Tray, $null)
            }
            'CopyUrl' {
                $best = @($script:Addresses)[0]
                if (-not $best) {
                    Show-Balloon 'No network connection found. Connect this PC to your Wi-Fi and try again.' Warning -Always
                    return
                }
                $data = New-Object Windows.Forms.DataObject
                $data.SetText((Get-PhoneUrl $best.Address))
                # The URL contains the token, so keep it out of Windows' clipboard history (Win+V) and
                # cloud clipboard sync. Both formats hold a DWORD; 0 means "no".
                foreach ($format in 'CanIncludeInClipboardHistory', 'CanUploadToCloudClipboard') {
                    $data.SetData($format, (New-Object IO.MemoryStream (, [byte[]](0, 0, 0, 0))))
                }
                [Windows.Forms.Clipboard]::SetDataObject($data, $true)
                Write-Log ('Copied the iPhone URL for {0} ({1})' -f $best.Address, $best.Adapter)
                Show-Balloon ('Copied the iPhone URL for {0} to the clipboard. Paste it into your Shortcuts.' -f $best.Address) Info -Always
            }
            'OpenInbox' {
                [void][IO.Directory]::CreateDirectory($script:Inbox)
                Invoke-Item -LiteralPath $script:Inbox
            }
            'ShowLog' {
                if (-not (Test-Path -LiteralPath $LogFile)) { Write-Log 'Log opened' }
                Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $LogFile)
            }
            'Notifications' {
                $script:Settings.Notifications = $script:NotifyItem.Checked
                Save-Settings
                if ($script:Settings.Notifications) {
                    Write-Log 'Notifications turned on'
                    Show-Balloon 'Notifications are on: you will see a message for every transfer.'
                } else {
                    Write-Log 'Notifications turned off'
                }
            }
            'Restart' { $script:ExitAction = 'Restart' }
            'Quit'    { $script:ExitAction = 'Quit' }
        }
    } catch {
        Write-Log ('Menu command {0} failed: {1}' -f $Action, (Get-ErrorText $_)) 'ERROR'
    }
}

function Exit-ClipBridge([switch]$Restart) {
    # Remove the tray icon before exiting: an icon that isn't disposed stays in the tray as a
    # "ghost" until the mouse moves over it
    if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose(); $script:Tray = $null }
    if ($script:Menu) { $script:Menu.Dispose(); $script:Menu = $null }
    if ($script:Listener) { try { $script:Listener.Stop() } catch { }; $script:Listener = $null }
    if ($Restart) {
        Write-Log 'Restarting'
        Start-ClipBridgeProcess
    } else {
        Write-Log 'Stopped'
    }
    exit 0
}

#endregion

#region HTTP -----------------------------------------------------------------------------------

function Send-Bytes($Stream, [byte[]]$Bytes) {
    $Stream.Write($Bytes, 0, $Bytes.Length)
}

function Send-Head($Stream, [string]$Status, [string]$Type, [long]$Length, [string]$FileName) {
    $head = "HTTP/1.1 $Status`r`nContent-Type: $Type`r`nContent-Length: $Length`r`nConnection: close`r`n"
    if ($FileName) {
        # A plain ASCII name for simple clients, plus the exact name (RFC 5987) for everyone else
        $ascii = ($FileName -replace '[^\x20-\x7E]', '_') -replace '"', ''
        $utf8 = [Uri]::EscapeDataString($FileName)
        $head += "Content-Disposition: attachment; filename=`"$ascii`"; filename*=UTF-8''$utf8`r`n"
    }
    Send-Bytes $Stream ([Text.Encoding]::ASCII.GetBytes($head + "`r`n"))
}

function Send-Text($Stream, [string]$Status, [string]$Text) {
    $body = [Text.Encoding]::UTF8.GetBytes($Text)
    Send-Head $Stream $Status 'text/plain; charset=utf-8' $body.Length $null
    if ($body.Length -gt 0) { Send-Bytes $Stream $body }
    $Stream.Flush()
}

function Send-File($Stream, [string]$Path, [string]$Name) {
    $type = $MimeTypes[[IO.Path]::GetExtension($Name).ToLower()]
    if (-not $type) { $type = 'application/octet-stream' }
    $file = [IO.File]::OpenRead($Path)
    try {
        Send-Head $Stream '200 OK' $type $file.Length $Name
        while (($n = $file.Read($script:Buffer, 0, $script:Buffer.Length)) -gt 0) {
            $Stream.Write($script:Buffer, 0, $n)
            [Windows.Forms.Application]::DoEvents()   # keep the tray menu responsive during big files
        }
        $Stream.Flush()
    } finally { $file.Close() }
}

function Read-Request($Stream) {
    # Reads up to the blank line that ends the HTTP headers; whatever arrived after it is the start of
    # the body. Returns $null if the client sent nothing usable.
    $received = New-Object IO.MemoryStream
    $headerEnd = -1
    while ($headerEnd -lt 0) {
        # A connection that sends nothing in time (e.g. a browser opening a spare one) is just dropped
        try { $n = $Stream.Read($script:Buffer, 0, $script:Buffer.Length) } catch [IO.IOException] { return $null }
        if ($n -le 0) { return $null }
        $received.Write($script:Buffer, 0, $n)
        $headerEnd = [Text.Encoding]::ASCII.GetString($received.ToArray()).IndexOf("`r`n`r`n")
        if ($headerEnd -lt 0 -and $received.Length -gt 1MB) { return $null }
    }
    $raw = $received.ToArray()
    $headers = [Text.Encoding]::UTF8.GetString($raw, 0, $headerEnd)
    $requestLine = ($headers -split "`r`n")[0] -split ' '
    $target = if ($requestLine.Count -gt 1) { $requestLine[1] } else { '' }

    $token = $null
    if ($target -match '[?&]t=([^&]+)') { $token = [Uri]::UnescapeDataString($Matches[1]) }
    if ($headers -match '(?im)^X-Token:\s*(\S+)') { $token = $Matches[1] }
    $length = [long]-1   # -1 means there was no Content-Length header
    if ($headers -match '(?im)^Content-Length:\s*(\d+)') { $length = [long]$Matches[1] }
    $expectContinue = $headers -match '(?im)^Expect:\s*100-continue'

    [pscustomobject]@{
        Method         = $requestLine[0].ToUpper()
        Path           = $target
        Headers        = $headers
        Token          = $token
        Raw            = $raw
        BodyStart      = $headerEnd + 4
        ContentLength  = $length
        ExpectContinue = $expectContinue
    }
}

function Save-RequestBody($Stream, $Request, [string]$Path) {
    # Saves the request body to $Path. Returns its size, or -1 if the upload was cut off.
    $length = $Request.ContentLength
    $already = [long]($Request.Raw.Length - $Request.BodyStart)
    if ($length -ge 0 -and $already -gt $length) { $already = $length }
    $written = [long]0
    $file = [IO.File]::Create($Path)
    try {
        if ($already -gt 0) { $file.Write($Request.Raw, $Request.BodyStart, [int]$already); $written = $already }
        if ($written -lt $length -and $Request.ExpectContinue) {
            # curl and some other clients wait for this before they send a larger body
            Send-Bytes $Stream ([Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n"))
        }
        while ($written -lt $length) {
            $n = $Stream.Read($script:Buffer, 0, [int][Math]::Min([long]$script:Buffer.Length, $length - $written))
            if ($n -le 0) { break }
            $file.Write($script:Buffer, 0, $n)
            $written += $n
            [Windows.Forms.Application]::DoEvents()   # keep the tray menu responsive during big uploads
        }
    } finally { $file.Close() }
    if ($length -ge 0 -and $written -lt $length) { return -1 }
    $written
}

#endregion

#region Content helpers ------------------------------------------------------------------------

function Get-SafeFileName([string]$Name) {
    # File names from the phone can contain anything. Keep only the last part of a path and replace
    # what Windows doesn't allow. (Don't use [IO.Path]::GetFileName here: on Windows PowerShell it
    # throws on names such as 'Invoice "final".pdf'.)
    $safe = ([string]$Name -split '[\\/]')[-1]
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { $safe = $safe.Replace([string]$c, '_') }
    $safe = $safe.Trim().TrimEnd([char[]]@('.', ' '))   # Windows drops trailing dots and spaces
    if (-not $safe) { $safe = 'file' }
    $base = [IO.Path]::GetFileNameWithoutExtension($safe)
    $extension = [IO.Path]::GetExtension($safe)
    if ($base.Length -gt 150) { $base = $base.Substring(0, 150); $safe = $base + $extension }
    if ($base -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$') { $safe = '_' + $safe }   # reserved device names
    $safe
}

function Get-UniquePath([string]$Dir, [string]$Name) {
    $Name = Get-SafeFileName $Name
    $base = [IO.Path]::GetFileNameWithoutExtension($Name)
    $extension = [IO.Path]::GetExtension($Name)
    $path = Join-Path $Dir $Name
    $i = 2
    while (Test-Path -LiteralPath $path) { $path = Join-Path $Dir ('{0} ({1}){2}' -f $base, $i, $extension); $i++ }
    $path
}

function Get-ExtensionFromContent([string]$Path) {
    # Recognise common file types from their first bytes. Returns $null if unknown.
    $head = New-Object byte[] 12
    $file = [IO.File]::OpenRead($Path)
    try { $got = $file.Read($head, 0, 12) } finally { $file.Close() }
    $ascii = [Text.Encoding]::ASCII
    if ($got -ge 3 -and $head[0] -eq 0xFF -and $head[1] -eq 0xD8 -and $head[2] -eq 0xFF) { return '.jpg' }
    if ($got -ge 4 -and $head[0] -eq 0x89 -and $head[1] -eq 0x50 -and $head[2] -eq 0x4E -and $head[3] -eq 0x47) { return '.png' }
    if ($got -ge 4 -and $ascii.GetString($head, 0, 4) -eq 'GIF8') { return '.gif' }
    if ($got -ge 4 -and $ascii.GetString($head, 0, 4) -eq '%PDF') { return '.pdf' }
    if ($got -ge 4 -and $head[0] -eq 0x50 -and $head[1] -eq 0x4B -and $head[2] -eq 3 -and $head[3] -eq 4) { return '.zip' }
    if ($got -ge 12 -and $ascii.GetString($head, 4, 4) -eq 'ftyp') {
        $brand = $ascii.GetString($head, 8, 4)
        if ($brand -match '^(heic|heix|mif1|msf1|hevc)') { return '.heic' }
        if ($brand -eq 'qt  ') { return '.mov' }
        return '.mp4'
    }
    $null
}

function Get-ReceivedFileName([string]$Name, [string]$DetectedExtension, [string]$ContentType) {
    # The name to save an upload under: the phone's name if it sent one, otherwise a timestamp.
    $extension = if ($DetectedExtension) { $DetectedExtension } else { Get-ExtensionFromMimeType $ContentType }
    if (-not $extension) { $extension = '.bin' }
    if (-not $Name) { return 'iPhone {0:yyyy-MM-dd HHmmss}{1}' -f (Get-Date), $extension }
    if (-not [IO.Path]::GetExtension($Name)) { return $Name + $extension }
    # Pictures and PDFs must end in an extension that matches their content: the iPhone names
    # clipboard pictures like "Clipboard Sep 27, 2026 at 9.41", which Windows reads as a ".41" file.
    # (Zip-based and video formats have too many valid extensions, so their names are kept.)
    $matching = @{ '.jpg' = '.jpg', '.jpeg', '.jpe', '.jfif'; '.png' = '.png'; '.gif' = '.gif'; '.heic' = '.heic', '.heif', '.hif'; '.pdf' = '.pdf' }
    if ($DetectedExtension -and $matching.ContainsKey($DetectedExtension) -and
        $matching[$DetectedExtension] -notcontains [IO.Path]::GetExtension($Name).ToLower()) { return $Name + $DetectedExtension }
    $Name
}

function Get-ExtensionFromMimeType([string]$ContentType) {
    foreach ($entry in $MimeTypes.GetEnumerator()) {
        if ($entry.Value -eq $ContentType) { return $entry.Key }
    }
    $null
}

function Read-Utf8Text([string]$Path) {
    # The text if the file is valid UTF-8 without NUL characters, otherwise $null
    $bytes = [IO.File]::ReadAllBytes($Path)
    try { $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes) } catch { return $null }
    if ($text.IndexOf([char]0) -ge 0) { return $null }
    $text.TrimStart([char]0xFEFF)   # a byte order mark is not part of the text
}

function Get-FileHashString([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-TextHashString([string]$Text) {
    # Line endings are ignored, so text that comes back from the iPhone with LF instead of the PC's
    # CRLF still counts as a repeat
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text.Replace("`r`n", "`n")))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Add-Seen([string]$Hash) {
    if (-not $Hash) { return }
    [void]$script:Seen.Remove($Hash)
    $script:Seen.Add($Hash)
    while ($script:Seen.Count -gt 30) { $script:Seen.RemoveAt(0) }
}

function New-ZipFromPaths([string[]]$Paths) {
    # Several copied items (or a folder) go to the phone as one .zip. Returns its path and name.
    $stage = Join-Path $TempDir ('zip_' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stage)
    try {
        foreach ($item in $Paths) {
            # Unique names, so two files called e.g. "image.png" from different folders are both kept
            $target = Get-UniquePath $stage ([IO.Path]::GetFileName($item))
            try { Copy-Item -LiteralPath $item -Destination $target -Recurse -Force }
            catch { Write-Log ('Left {0} out of the zip: {1}' -f [IO.Path]::GetFileName($item), (Get-ErrorText $_)) 'WARN' }
        }
        $name = if ($Paths.Count -eq 1) { [IO.Path]::GetFileName($Paths[0]) + '.zip' } else { 'PC files ({0}).zip' -f $Paths.Count }
        $zipPath = Join-Path $TempDir $name
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        # Built entry by entry because ZipFile.CreateFromDirectory writes "Folder\file.txt" on Windows
        # PowerShell. The ZIP format wants "/", and the iPhone shows a "\" name as one flat file.
        $archive = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
        try {
            foreach ($entry in Get-ChildItem -LiteralPath $stage -Recurse -Force) {
                $relative = $entry.FullName.Substring($stage.Length + 1).Replace('\', '/')
                if ($entry.PSIsContainer) { [void]$archive.CreateEntry($relative + '/') }
                else { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $entry.FullName, $relative) }
            }
        } finally {
            $archive.Dispose()
        }
        [pscustomobject]@{ Path = $zipPath; Name = $name }
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Read-ImageForClipboard([string]$Path) {
    # A copy of the picture for the clipboard, or $null if Windows can't read it (e.g. HEIC).
    # Loaded from memory because Image.FromFile keeps the file locked until the image is garbage
    # collected, and turned upright because iPhone photos store their rotation as an EXIF tag,
    # which GDI+ ignores.
    try {
        $memory = New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($Path))
        $original = [Drawing.Image]::FromStream($memory)
        try {
            $copy = New-Object Drawing.Bitmap $original
            $orientation = 1
            if ($original.PropertyIdList -contains 0x0112) {
                $value = $original.GetPropertyItem(0x0112).Value
                $orientation = [Math]::Max([int]$value[0], [int]$value[1])   # 1..8, works in either byte order
            }
            $flip = switch ($orientation) {
                2 { 'RotateNoneFlipX' }   3 { 'Rotate180FlipNone' } 4 { 'Rotate180FlipX' }
                5 { 'Rotate90FlipX' }     6 { 'Rotate90FlipNone' }  7 { 'Rotate270FlipX' }
                8 { 'Rotate270FlipNone' }
            }
            if ($flip) { $copy.RotateFlip([Drawing.RotateFlipType]$flip) }
            $copy
        } finally {
            $original.Dispose()
            $memory.Dispose()
        }
    } catch {
        $null
    }
}

function Set-ClipboardFiles([string]$Path) {
    # Puts the received file on the clipboard as a file (paste in Explorer, chat apps, email...).
    # Files that arrive within 8 seconds of each other go together, so 3 shared photos paste as 3.
    if (((Get-Date) - $script:LastFileAt).TotalSeconds -gt 8) { $script:Batch.Clear() }
    [void]$script:Batch.Add($Path)
    $script:LastFileAt = Get-Date
    $existing = New-Object System.Collections.Specialized.StringCollection
    foreach ($item in $script:Batch) { if (Test-Path -LiteralPath $item) { [void]$existing.Add($item) } }
    $script:Batch = $existing

    $data = New-Object Windows.Forms.DataObject
    $data.SetFileDropList($script:Batch)
    $image = $null
    if ($script:Batch.Count -eq 1 -and [IO.Path]::GetExtension($Path).ToLower() -in '.png', '.jpg', '.jpeg', '.gif', '.bmp') {
        # Also as a picture, for apps that paste pictures but not files
        $image = Read-ImageForClipboard $Path
        if ($image) { $data.SetImage($image) }
    }
    try {
        [Windows.Forms.Clipboard]::SetDataObject($data, $true)   # $true: copied now, so $image can go
    } finally {
        if ($image) { $image.Dispose() }
    }
}

#endregion

#region Requests -------------------------------------------------------------------------------

function Send-ClipboardToPhone($Stream, [bool]$OnlyIfNew) {
    # GET /clip: files first, then a picture, then text
    $sequence = [ClipBridge.Native]::GetClipboardSequenceNumber()
    if ($OnlyIfNew -and $sequence -eq $script:PhoneSeq) { Send-Text $Stream '200 OK' ''; return }

    $done = $false
    if ([Windows.Forms.Clipboard]::ContainsFileDropList()) {
        $files = @([Windows.Forms.Clipboard]::GetFileDropList() | Where-Object { Test-Path -LiteralPath $_ })
        if ($files.Count -eq 1 -and (Test-Path -LiteralPath $files[0] -PathType Leaf)) {
            $name = [IO.Path]::GetFileName($files[0])
            Send-File $Stream $files[0] $name
            Add-Seen (Get-FileHashString $files[0])
            Complete-Transfer ('Sent file to iPhone: {0}' -f $name)
            $done = $true
        } elseif ($files.Count -gt 0) {
            $zip = New-ZipFromPaths $files
            try {
                Send-File $Stream $zip.Path $zip.Name
                Add-Seen (Get-FileHashString $zip.Path)
            } finally {
                Remove-Item -LiteralPath $zip.Path -Force -ErrorAction SilentlyContinue
            }
            Complete-Transfer ('Sent {0} item(s) to iPhone as {1}' -f $files.Count, $zip.Name)
            $done = $true
        }
    }
    if (-not $done -and [Windows.Forms.Clipboard]::ContainsImage()) {
        $image = [Windows.Forms.Clipboard]::GetImage()   # can be $null even though an image is reported
        if ($image) {
            $png = Join-Path $TempDir 'clipboard.png'
            try { $image.Save($png, [Drawing.Imaging.ImageFormat]::Png) } finally { $image.Dispose() }
            Send-File $Stream $png ('PC image {0:yyyy-MM-dd HHmmss}.png' -f (Get-Date))
            Add-Seen (Get-FileHashString $png)
            Complete-Transfer 'Sent image to iPhone'
            $done = $true
        }
    }
    if (-not $done) {
        $text = [Windows.Forms.Clipboard]::GetText()
        if ($null -eq $text) { $text = '' }
        Send-Text $Stream '200 OK' $text
        if ($text) {
            Add-Seen (Get-TextHashString $text)
            Complete-Transfer ('Sent text to iPhone ({0} characters)' -f $text.Length)
        }
    }
    # Only after a successful send: if anything above failed, the next "new=1" request tries again
    $script:PhoneSeq = $sequence
}

function Receive-FromPhone($Stream, $Request) {
    # POST /clip and POST /file: text becomes the clipboard, anything else is saved as a file
    $tmp = Join-Path $TempDir ('in_' + [Guid]::NewGuid().ToString('N'))
    try {
        $size = Save-RequestBody $Stream $Request $tmp
        if ($size -lt 0) {
            Write-Log 'An upload from the iPhone was cut off before it finished, so it was ignored' 'WARN'
            try { Send-Text $Stream '400 Bad Request' 'incomplete upload' } catch { }   # the phone is usually gone
            return
        }

        $name = $null
        if ($Request.Headers -match '(?im)^X-Filename:\s*(.+?)\s*$') { $name = [Uri]::UnescapeDataString($Matches[1]) }
        elseif ($Request.Path -match '[?&]name=([^&]+)') { $name = [Uri]::UnescapeDataString($Matches[1]) }
        if ($name) { $name = Get-SafeFileName $name }
        $contentType = ''
        if ($Request.Headers -match '(?im)^Content-Type:\s*([^;\r\n]+)') { $contentType = $Matches[1].Trim().ToLower() }
        $detectedExtension = Get-ExtensionFromContent $tmp

        # Text only if nothing says it's a file: no file name, no known file signature, a text-like
        # content type, and valid UTF-8
        $text = $null
        $textType = $contentType -eq '' -or $contentType.StartsWith('text/') -or $contentType -eq 'application/x-www-form-urlencoded'
        if (-not $name -and -not $detectedExtension -and $textType -and $size -gt 0 -and $size -lt 5MB) {
            $text = Read-Utf8Text $tmp
        }

        # Ignore anything seen recently: the phone re-sending its clipboard, or sending back what it
        # just got from the PC. Otherwise it would overwrite whatever you copied on the PC since.
        $hash = if ($null -ne $text) { Get-TextHashString $text } else { Get-FileHashString $tmp }
        if ($size -eq 0 -or $script:Seen.Contains($hash)) { Send-Text $Stream '200 OK' 'same'; return }
        Add-Seen $hash

        if ($null -ne $text) {
            if ($text.Length -gt 0) { [Windows.Forms.Clipboard]::SetText($text) }
            $script:PhoneSeq = [ClipBridge.Native]::GetClipboardSequenceNumber()   # don't send it straight back
            Send-Text $Stream '200 OK' 'ok'
            Complete-Transfer ('Got text from iPhone ({0} characters)' -f $text.Length)
            return
        }

        $destination = Get-UniquePath $script:Inbox (Get-ReceivedFileName $name $detectedExtension $contentType)
        Move-Item -LiteralPath $tmp -Destination $destination
        Set-ClipboardFiles $destination
        $script:PhoneSeq = [ClipBridge.Native]::GetClipboardSequenceNumber()
        Send-Text $Stream '200 OK' 'ok'
        Complete-Transfer ('Got file from iPhone: {0}' -f [IO.Path]::GetFileName($destination))
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-NextRequest {
    $client = $script:Listener.AcceptTcpClient()
    try {
        $client.ReceiveTimeout = 5000    # for the headers: a connection that sends nothing is dropped quickly
        $client.SendTimeout = 15000
        $stream = $client.GetStream()
        $request = Read-Request $stream
        if (-not $request) { return }
        if ($request.Path -notmatch '^/(clip|file)') { Send-Text $stream '404 Not Found' 'not found'; return }
        if ($request.Token -ne $script:Token) {
            Write-Log ('Refused a request with a wrong or missing token from {0}' -f $client.Client.RemoteEndPoint.Address) 'WARN'
            Send-Text $stream '403 Forbidden' 'bad token'
            return
        }
        $client.ReceiveTimeout = 15000   # an upload may pause for a while on weak Wi-Fi
        switch ($request.Method) {
            'GET'   { Send-ClipboardToPhone $stream ($request.Path -match '[?&]new=1') }
            'POST'  { Receive-FromPhone $stream $request }
            'PUT'   { Receive-FromPhone $stream $request }
            default { Send-Text $stream '405 Method Not Allowed' 'use GET or POST' }
        }
    } catch {
        Write-Log ('Request failed: {0}' -f (Get-ErrorText $_)) 'ERROR'
    } finally {
        $client.Close()
    }
}

#endregion

#region Main loop ------------------------------------------------------------------------------

function Start-Listener {
    # Called at startup, and every 15 seconds while the port can't be used (e.g. another program has it)
    $script:NextListenAttempt = [datetime]::UtcNow.AddSeconds(15)
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $Port)
    try {
        $listener.Start()
    } catch {
        $failure = $_   # saved before the switch below, which sets $_ to its own value
        $socketError = $failure.Exception.InnerException
        $code = if ($socketError -is [Net.Sockets.SocketException]) { [string]$socketError.SocketErrorCode } else { '' }
        $reason = switch ($code) {
            'AddressAlreadyInUse' { 'port {0} is in use' -f $Port }
            'AccessDenied'        { 'port {0} is blocked' -f $Port }
            default               { 'cannot use port {0}' -f $Port }
        }
        if (-not $script:ListenError) {
            Write-Log ('Cannot listen on port {0} ({1}). Retrying every 15 seconds.' -f $Port, (Get-ErrorText $failure).TrimEnd('.')) 'ERROR'
            Show-Balloon ('ClipBridge can''t start: {0}. It keeps trying; see "Show log" for details.' -f $reason) Warning -Always
        }
        $script:ListenError = '{0} (retrying)' -f $reason
        Update-TrayStatus
        return
    }
    $script:Listener = $listener
    if ($script:ListenError) { Show-Balloon ('Port {0} is free again. ClipBridge is running.' -f $Port) Info -Always }
    $script:ListenError = $null
    Write-Log ('Listening on port {0}' -f $Port)
    Update-TrayStatus
}

function Test-ScriptSyntax([string]$Path) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    -not $errors
}

function Invoke-MainLoop {
    # One loop does everything: answers the iPhone, keeps the tray icon responsive (DoEvents instead
    # of a second thread), and every few seconds checks for edits of this file and network changes.
    $selfStamp = (Get-Item -LiteralPath $SelfPath).LastWriteTimeUtc
    $restartAt = $null
    $nextFileCheck = [datetime]::UtcNow.AddSeconds(3)
    $nextNetworkCheck = [datetime]::UtcNow.AddSeconds(30)
    while ($true) {
        try {
            [Windows.Forms.Application]::DoEvents()
            if ($script:ExitAction -eq 'Quit') { Exit-ClipBridge }
            if ($script:ExitAction -eq 'Restart') { Exit-ClipBridge -Restart }
            if ($script:QuitEvent.WaitOne(0)) {
                Write-Log 'Another ClipBridge (or the uninstaller) asked this one to quit'
                Exit-ClipBridge
            }

            if ($script:Listener -and $script:Listener.Pending()) { Invoke-NextRequest; continue }

            # Short naps while the tray menu is open so it reacts smoothly, longer ones otherwise
            if ($script:Menu -and $script:Menu.Visible) { Start-Sleep -Milliseconds 15 } else { Start-Sleep -Milliseconds 100 }

            $now = [datetime]::UtcNow
            if ($now -ge $nextFileCheck) {
                $nextFileCheck = $now.AddSeconds(3)
                $stamp = (Get-Item -LiteralPath $SelfPath -ErrorAction SilentlyContinue).LastWriteTimeUtc
                if ($stamp -and $stamp -ne $selfStamp) {
                    # Wait until the file has stopped changing (editors may save in several steps)
                    $selfStamp = $stamp
                    $restartAt = $now.AddSeconds(2)
                } elseif ($restartAt -and $now -ge $restartAt) {
                    $restartAt = $null
                    if (Test-ScriptSyntax $SelfPath) {
                        Write-Log ('{0} was changed, restarting' -f (Split-Path -Leaf $SelfPath))
                        Exit-ClipBridge -Restart
                    }
                    Write-Log ('{0} was changed but has errors, so the running version stays' -f (Split-Path -Leaf $SelfPath)) 'WARN'
                }
            }
            if ($now -ge $nextNetworkCheck) {
                $nextNetworkCheck = $now.AddSeconds(30)
                Update-Addresses
            }
            if (-not $script:Listener -and $now -ge $script:NextListenAttempt) { Start-Listener }
        } catch {
            Write-Log ('Unexpected error: {0}' -f (Get-ErrorText $_)) 'ERROR'
            Start-Sleep -Milliseconds 500
        }
    }
}

#endregion

#region Start ----------------------------------------------------------------------------------

if ($Install -or $Uninstall) {
    # Run from Install_ClipBridge.bat / Uninstall_ClipBridge.bat, in a visible console window
    $ErrorActionPreference = 'Stop'
    try {
        if ($Install -and $Uninstall) { Write-Host 'Use either -Install or -Uninstall, not both.'; exit 2 }
        if ($Install) { if (-not (Install-ClipBridge)) { exit 1 } } else { Uninstall-ClipBridge }
        exit 0
    } catch {
        Write-Host ('Something went wrong: {0}' -f (Get-ErrorText $_)) -ForegroundColor Red
        exit 1
    }
}

# The clipboard and the tray icon need a single-threaded apartment; Windows PowerShell 5.1 uses one
# by default, but restart with -STA if someone started us differently.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { Start-ClipBridgeProcess; exit 0 }

$ErrorActionPreference = 'Stop'
try {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.IO.Compression, System.IO.Compression.FileSystem
    Add-Type -Namespace ClipBridge -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
    [void][ClipBridge.Native]::SetProcessDPIAware()   # a sharp tray menu on high-DPI screens
    [Windows.Forms.Application]::EnableVisualStyles()
    [void][IO.Directory]::CreateDirectory($DataDir)
    [void][IO.Directory]::CreateDirectory($TempDir)
    Write-Log ('Starting ClipBridge on port {0}' -f $Port)

    $stopped = Stop-OtherInstances
    if ($stopped) { Write-Log ('Replaced {0} ClipBridge instance(s) that were already running' -f $stopped) }
    Clear-TempFolder
    $script:Token = Get-Token
    $script:Inbox = Join-Path (Get-DownloadsFolder) 'From iPhone'
    [void][IO.Directory]::CreateDirectory($script:Inbox)
    $script:Settings = Read-Settings
    $script:QuitEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, $QuitEventName)
    # Whatever is on the clipboard now counts as already sent, so "new=1" waits for the next copy
    $script:PhoneSeq = [ClipBridge.Native]::GetClipboardSequenceNumber()

    New-Tray
    Update-Addresses
    Start-Listener
    if ($script:IsFirstRun) {
        Show-Balloon 'ClipBridge is running. Click this icon and choose "Copy iPhone URL" to set up your iPhone.' Info -Always
    }
    Invoke-MainLoop
} catch {
    Write-Log ('ClipBridge stopped after an unexpected error: {0}' -f (Get-ErrorText $_)) 'ERROR'
    Exit-ClipBridge
}

#endregion
