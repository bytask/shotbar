#Requires -Version 5.1
<#
  ShotBar for Windows
  タスクトレイに常駐し、直近のスクリーンショット・画面収録を
  開く / コピー / パスをコピー / エクスプローラーで表示 できる。
  撮影機能は持たない（Win+Shift+S・Win+PrtScn・Snipping Tool の録画・Xbox Game Bar で撮ったものを扱う）。

  使い方:
    powershell -ExecutionPolicy Bypass -File ShotBar.ps1 -Install     # スタートメニューに登録して起動（ログイン時起動はメニューで切り替え）
    powershell -ExecutionPolicy Bypass -File ShotBar.ps1 -Uninstall   # 停止して登録を外す
#>
param(
    [switch]$Install,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:ScriptPath  = $PSCommandPath
$script:AppDir      = Join-Path $env:LOCALAPPDATA 'ShotBar'
$script:ClipDir     = Join-Path $script:AppDir 'clipboard'
$script:SettingsPath = Join-Path $script:AppDir 'settings.json'
$script:LogPath     = Join-Path $script:AppDir 'error.log'
$script:StartupLnk  = Join-Path ([Environment]::GetFolderPath('Startup')) 'ShotBar.lnk'
$script:MenuLnk     = Join-Path ([Environment]::GetFolderPath('Programs')) 'ShotBar.lnk'
New-Item -ItemType Directory -Force -Path $script:ClipDir | Out-Null

# ---------- ショートカット（ログイン時起動・スタートメニュー） ----------

function New-ShotBarShortcut([string]$LnkPath) {
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($LnkPath)
    $s.TargetPath = Join-Path $PSHOME 'powershell.exe'
    $s.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $script:ScriptPath
    $s.WorkingDirectory = Split-Path $script:ScriptPath
    $s.WindowStyle = 7
    $s.Description = 'ShotBar for Windows'
    $s.Save()
}

function Stop-ShotBar {
    # 別の場所に clone した ShotBar が動いていても止める（残っていると多重起動防止で新しい方が起動しない）
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -match '-File\s+"?[^"]*ShotBar\.ps1' -and $_.CommandLine -notmatch '-(Install|Uninstall)\b' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

if ($Install) {
    Stop-ShotBar
    New-ShotBarShortcut $script:MenuLnk
    # ログイン時起動がオンなら、起動先をこのスクリプトに付け替える（clone し直した場所に追従させる）
    if (Test-Path -LiteralPath $script:StartupLnk) { New-ShotBarShortcut $script:StartupLnk }
    Start-Process -FilePath $script:MenuLnk
    Write-Host "インストールしました。タスクトレイ（右下の ^ の中にあることもあります）に ShotBar が出ます。"
    exit 0
}
if ($Uninstall) {
    Stop-ShotBar
    Remove-Item -LiteralPath $script:MenuLnk, $script:StartupLnk -Force -ErrorAction SilentlyContinue
    Write-Host "アンインストールしました。クリップボードから残した画像は $script:ClipDir にあります（不要なら手で消してください）。"
    exit 0
}

# ---------- 多重起動の防止 ----------

$created = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\ShotBarForWindows', [ref]$created)
if (-not $created) { exit 0 }

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ShotBarNative {
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("shell32.dll")] static extern int SHGetKnownFolderPath([MarshalAs(UnmanagedType.LPStruct)] Guid rfid, uint flags, IntPtr token, out IntPtr path);
    public static string KnownFolder(string guid) {
        IntPtr p;
        if (SHGetKnownFolderPath(new Guid(guid), 0, IntPtr.Zero, out p) != 0) return null;
        string s = Marshal.PtrToStringUni(p);
        Marshal.FreeCoTaskMem(p);
        return s;
    }
}
"@

# 撮影直後に右側へ出すプレビュー窓。表示しても入力中のウィンドウからフォーカスを奪わない
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System.Windows.Forms;
public class ShotBarPreviewForm : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000 | 0x00000008 | 0x00000080;   // NOACTIVATE | TOPMOST | TOOLWINDOW（Alt+Tab に出さない）
            return cp;
        }
    }
}
"@

function Write-Log([string]$Message) {
    try { Add-Content -LiteralPath $script:LogPath -Encoding UTF8 -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message) } catch {}
}

# ---------- 設定 ----------

$script:Settings = [ordered]@{
    retentionDays  = 7        # クリップボードから残した画像を何日残すか（1 / 3 / 7 / 14）
    watchClipboard = $true    # 画像だけのクリップボード項目を拾うか
    showPreview    = $true    # 撮ったら画面右側にプレビューを出すか
    previewSeconds = 0        # プレビューを自動で消すまでの秒数。0 は消さない（× か次の撮影まで残る）
    extraFolders   = @()      # 追加で見るフォルダ（例: "C:\\Users\\me\\Desktop"）
}
if (Test-Path -LiteralPath $script:SettingsPath) {
    try {
        $j = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:SettingsPath | ConvertFrom-Json
        foreach ($k in @($script:Settings.Keys)) { if ($null -ne $j.$k) { $script:Settings[$k] = $j.$k } }
    } catch { Write-Log "settings.json を読めませんでした: $_" }
}
function Save-Settings {
    try { $script:Settings | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath $script:SettingsPath } catch { Write-Log "設定の保存に失敗: $_" }
}

# ---------- 撮ったものを探す ----------

$script:ImageExt = @('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp')
$script:VideoExt = @('.mp4', '.mkv', '.mov', '.webm', '.avi', '.wmv')

function Get-WatchFolders {
    # スクリーンショット（Win+Shift+S の自動保存・Win+PrtScn）の保存先。OneDrive へ移していても正しく引ける
    $shots = [ShotBarNative]::KnownFolder('b7bede81-df94-4682-a7d8-57a52620b86f')
    if (-not $shots) { $shots = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Screenshots' }
    $videos = [ShotBarNative]::KnownFolder('18989B1D-99B5-455B-841C-AB7C74E4DDFC')
    if (-not $videos) { $videos = [Environment]::GetFolderPath('MyVideos') }

    $candidates = @(
        $shots,
        (Join-Path $videos 'Screen Recordings'),   # Snipping Tool の画面録画
        (Join-Path $videos 'Captures')             # Xbox Game Bar（Win+Alt+R）
    ) + @($script:Settings.extraFolders)

    $seen = @{}
    foreach ($p in $candidates) {
        if ($p -and -not $seen.ContainsKey($p) -and (Test-Path -LiteralPath $p)) { $seen[$p] = $true; $p }
    }
}

function Test-IsVideo([string]$Path) { $script:VideoExt -contains [IO.Path]::GetExtension($Path).ToLower() }

function Get-RecentItems([int]$Count = 10) {
    $exts = $script:ImageExt + $script:VideoExt
    $files = foreach ($d in Get-WatchFolders) {
        Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue |
            Where-Object { $exts -contains $_.Extension.ToLower() }
    }
    $clips = Get-ChildItem -LiteralPath $script:ClipDir -File -Filter '*.png' -ErrorAction SilentlyContinue
    @($files) + @($clips) | Where-Object { $_ } | Sort-Object LastWriteTime -Descending | Select-Object -First $Count
}

function Get-Label($File) {
    $t = $File.LastWriteTime
    $time = if ($t.Date -eq (Get-Date).Date) { $t.ToString('HH:mm') } else { $t.ToString('M/d HH:mm') }
    if ($File.DirectoryName -eq $script:ClipDir) { return "クリップボード $time" }
    $kind = if (Test-IsVideo $File.FullName) { '画面収録' } else { 'スクショ' }
    "$kind $time"
}

# ---------- サムネイル ----------

function Read-ImageNoLock([string]$Path) {
    # ファイルを掴んだままにしない（撮影ツールや削除の邪魔をしない）
    $bytes = [IO.File]::ReadAllBytes($Path)
    $ms = New-Object IO.MemoryStream(, $bytes)
    $img = [Drawing.Image]::FromStream($ms)
    $copy = New-Object Drawing.Bitmap($img)
    $img.Dispose(); $ms.Dispose()
    $copy
}

$script:ThumbCache = @{}

function Get-CachedThumbnail($File, [int]$Max) {
    # 開くたびに10枚読み直すと遅いので、パス・更新時刻・大きさが同じなら作り置きを使う
    $key = '{0}|{1}|{2}' -f $File.FullName, $File.LastWriteTimeUtc.Ticks, $Max
    if (-not $script:ThumbCache.ContainsKey($key)) { $script:ThumbCache[$key] = New-Thumbnail $File.FullName $Max }
    $script:ThumbCache[$key]
}

function Clear-StaleThumbnails($Files) {
    $live = @{}
    foreach ($f in $Files) { $live[$f.FullName] = $true }
    foreach ($k in @($script:ThumbCache.Keys)) {
        if (-not $live.ContainsKey($k.Split('|')[0])) { $script:ThumbCache[$k].Dispose(); $script:ThumbCache.Remove($k) }
    }
}

function New-Thumbnail([string]$Path, [int]$Max, [int]$MaxHeight = 0) {
    if ($MaxHeight -le 0) { $MaxHeight = $Max }
    try {
        if (Test-IsVideo $Path) { throw 'video' }
        $img = Read-ImageNoLock $Path
    } catch {
        return ([Drawing.Icon]::ExtractAssociatedIcon($Path)).ToBitmap()
    }
    try {
        $scale = [Math]::Min(1.0, [Math]::Min($Max / $img.Width, $MaxHeight / $img.Height))
        $w = [Math]::Max(1, [int]($img.Width * $scale))
        $h = [Math]::Max(1, [int]($img.Height * $scale))
        $bmp = New-Object Drawing.Bitmap($w, $h)
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($img, 0, 0, $w, $h)
        $g.Dispose()
        $bmp
    } finally { $img.Dispose() }
}

# ---------- 4つの動作 ----------

function Open-Capture([string]$Path) {
    try { Start-Process -FilePath $Path } catch { Write-Log "開けませんでした: $Path $_" }
}

function Show-InExplorer([string]$Path) {
    Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$Path`""
}

function Copy-CapturePath([string]$Path) {
    try { [Windows.Forms.Clipboard]::SetText($Path) } catch { Write-Log "パスのコピーに失敗: $_" }
}

function Copy-Capture([string]$Path) {
    # ファイルと画像データを同じ項目に載せる。Slack・エクスプローラーにはファイル、画像を受けるアプリには画像として貼れる
    try {
        $data = New-Object Windows.Forms.DataObject
        $list = New-Object Collections.Specialized.StringCollection
        [void]$list.Add($Path)
        $data.SetFileDropList($list)
        if (-not (Test-IsVideo $Path)) {
            try {
                $data.SetImage((Read-ImageNoLock $Path))
                if ([IO.Path]::GetExtension($Path) -ieq '.png') {
                    $data.SetData('PNG', (New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($Path))))
                }
            } catch { Write-Log "画像として読めないのでファイルだけコピー: $Path" }
        }
        [Windows.Forms.Clipboard]::SetDataObject($data, $true, 5, 100)
    } catch { Write-Log "コピーに失敗: $_" }
}

# ---------- クリップボードの画像を拾う ----------

$script:TextLikeFormats = @('FileDrop', 'FileName', 'FileNameW', 'Text', 'UnicodeText', 'OEMText',
                            'HTML Format', 'Rich Text Format', 'UniformResourceLocator', 'UniformResourceLocatorW')
$script:LastSeq    = [ShotBarNative]::GetClipboardSequenceNumber()
$script:PendingSeq = $null
$script:PendingAt  = [datetime]::MinValue

function Get-ClipboardImageOnly {
    $d = [Windows.Forms.Clipboard]::GetDataObject()
    if (-not $d) { return $null }
    $formats = $d.GetFormats()
    foreach ($f in $script:TextLikeFormats) { if ($formats -contains $f) { return $null } }   # ファイル・URL・文字を含むものは対象外
    if ($formats -contains 'PNG') {
        $s = $d.GetData('PNG')
        if ($s -is [IO.Stream]) { return (New-Object Drawing.Bitmap([Drawing.Image]::FromStream($s))) }
    }
    if ([Windows.Forms.Clipboard]::ContainsImage()) { return [Windows.Forms.Clipboard]::GetImage() }
    $null
}

function Test-AlreadySavedAsFile($Image) {
    # Win+Shift+S は自動保存とクリップボードの両方に入るので、直近に同じ大きさのファイルが出来ていれば二重に残さない
    $since = (Get-Date).AddSeconds(-20)
    foreach ($d in Get-WatchFolders) {
        $recent = Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $since -and $script:ImageExt -contains $_.Extension.ToLower() }
        foreach ($f in $recent) {
            try {
                $img = Read-ImageNoLock $f.FullName
                $same = ($img.Width -eq $Image.Width -and $img.Height -eq $Image.Height)
                $img.Dispose()
                if ($same) { return $true }
            } catch {}
        }
    }
    $false
}

function Save-ClipboardImage {
    $img = Get-ClipboardImageOnly
    if (-not $img) { return }
    try {
        if (Test-AlreadySavedAsFile $img) { return }
        $name = 'clip_{0:yyyyMMdd_HHmmss}.png' -f (Get-Date)
        $saved = Join-Path $script:ClipDir $name
        $img.Save($saved, [Drawing.Imaging.ImageFormat]::Png)
        Request-Preview $saved
    } finally { $img.Dispose() }
}

function Invoke-ClipboardTick {
    if (-not $script:Settings.watchClipboard) { return }
    $seq = [ShotBarNative]::GetClipboardSequenceNumber()
    if ($seq -ne $script:LastSeq) {
        # 変わった直後は撮影ツールのファイル保存が終わっていないことがあるので、2秒置いてから見る
        $script:LastSeq = $seq
        $script:PendingSeq = $seq
        $script:PendingAt = Get-Date
        return
    }
    if ($null -ne $script:PendingSeq -and ((Get-Date) - $script:PendingAt).TotalSeconds -ge 2) {
        $script:PendingSeq = $null
        try { Save-ClipboardImage } catch { Write-Log "クリップボードの保存に失敗: $_" }
    }
}

function Remove-OldClips {
    $limit = (Get-Date).AddDays(-[int]$script:Settings.retentionDays)
    Get-ChildItem -LiteralPath $script:ClipDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $limit } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# ---------- 撮影直後のプレビュー（画面右側に最大5枚） ----------

$script:MaxCards = 5
$script:Cards = New-Object System.Collections.ArrayList      # 先頭が一番新しい
$script:PendingPreviews = New-Object System.Collections.ArrayList

function Request-Preview([string]$Path) {
    # 書き込み途中のことがあるので、すぐには出さずプレビュー用タイマーで読めるまで待つ
    if (-not $script:Settings.showPreview) { return }
    if ($script:ImageExt -notcontains [IO.Path]::GetExtension($Path).ToLower()) { return }
    foreach ($p in $script:PendingPreviews) { if ($p.Path -eq $Path) { return } }
    foreach ($c in $script:Cards) { if ($c.Path -eq $Path) { return } }   # Created と Renamed の両方で来ても1枚だけ
    [void]$script:PendingPreviews.Add(@{ Path = $Path; Tries = 0 })
}

function New-PreviewButton([string]$Text, [string]$Tip, $Card, [scriptblock]$OnClick) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text
    $b.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(210, 210, 210)
    $b.BackColor = [Drawing.Color]::FromArgb(245, 245, 245)
    $b.Height = 26
    $b.TabStop = $false
    $b.Cursor = [Windows.Forms.Cursors]::Hand
    $b.Tag = $Card
    $script:Tips.SetToolTip($b, $Tip)
    $b.Add_Click($OnClick)
    $b
}

function Set-CardNotice($Card, [string]$Text) {
    # 一言出して、少ししたら見出しを元に戻す（プレビュー自体は残す）
    $Card.Title.Text = $Text
    $Card.TitleRestoreAt = (Get-Date).AddSeconds(1.5)
}

function Remove-PreviewCard($Card) {
    $script:Cards.Remove($Card)
    $img = $Card.Pic.Image
    $Card.Form.Close()
    $Card.Form.Dispose()
    if ($img) { $img.Dispose() }
    Update-CardLayout
}

function Update-CardLayout {
    # 画面右端に縦に積む。新しいものが上。全体を上下中央に寄せる（右下は Snipping Tool の通知と重なるので避ける）
    $area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $gap = 10
    $total = 0
    foreach ($c in $script:Cards) { $total += $c.Form.Height + $gap }
    $y = [Math]::Max($area.Top + 8, $area.Top + [int](($area.Height - $total) / 2))
    foreach ($c in $script:Cards) {
        $c.Form.Location = New-Object Drawing.Point(($area.Right - $c.Form.Width - 16), $y)
        $y += $c.Form.Height + $gap
    }
}

function New-PreviewCard([string]$Path) {
    $file = Get-Item -LiteralPath $Path
    $thumb = New-Thumbnail $Path 220 120
    $card = @{ Path = $Path; Label = (Get-Label $file); TitleRestoreAt = $null; HideAt = [datetime]::MaxValue; DragStart = $null }

    $f = New-Object ShotBarPreviewForm
    $f.FormBorderStyle = [Windows.Forms.FormBorderStyle]::None
    $f.StartPosition = [Windows.Forms.FormStartPosition]::Manual
    $f.ShowInTaskbar = $false
    $f.BackColor = [Drawing.Color]::FromArgb(180, 180, 180)   # 1px の枠線になる
    $f.Padding = New-Object Windows.Forms.Padding(1)

    $panel = New-Object Windows.Forms.Panel
    $panel.Dock = [Windows.Forms.DockStyle]::Fill
    $panel.BackColor = [Drawing.Color]::White
    $f.Controls.Add($panel)

    $inner = 220
    $title = New-Object Windows.Forms.Label
    $title.AutoSize = $false
    $title.Location = New-Object Drawing.Point(10, 6)
    $title.Size = New-Object Drawing.Size(($inner - 24), 18)
    $title.ForeColor = [Drawing.Color]::FromArgb(90, 90, 90)
    $title.Text = $card.Label
    $panel.Controls.Add($title)

    $close = New-Object Windows.Forms.Label
    $close.Text = '×'
    $close.AutoSize = $false
    $close.Size = New-Object Drawing.Size(22, 20)
    $close.Location = New-Object Drawing.Point(($inner - 12), 4)
    $close.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
    $close.Cursor = [Windows.Forms.Cursors]::Hand
    $close.Tag = $card
    $close.Add_Click({ Remove-PreviewCard $this.Tag })
    $panel.Controls.Add($close)

    $pic = New-Object Windows.Forms.PictureBox
    $pic.SizeMode = [Windows.Forms.PictureBoxSizeMode]::Zoom
    $pic.Location = New-Object Drawing.Point(10, 26)
    $pic.Size = New-Object Drawing.Size($inner, $thumb.Height)
    $pic.Image = $thumb
    $pic.Cursor = [Windows.Forms.Cursors]::Hand
    $pic.Tag = $card
    $script:Tips.SetToolTip($pic, 'クリックで開く／ドラッグで Slack やフォルダへ渡せる')
    # クリックは開く、少し動かしたらドラッグ（ファイルとして渡す）
    $pic.Add_MouseDown({ param($s, $e) if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) { $this.Tag.DragStart = $e.Location } })
    $pic.Add_MouseMove({
        param($s, $e)
        $c = $this.Tag
        if ($null -eq $c.DragStart -or $e.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
        if ([Math]::Abs($e.X - $c.DragStart.X) + [Math]::Abs($e.Y - $c.DragStart.Y) -lt 6) { return }
        $c.DragStart = $null
        $data = New-Object Windows.Forms.DataObject
        $list = New-Object Collections.Specialized.StringCollection
        [void]$list.Add($c.Path)
        $data.SetFileDropList($list)
        [void]$this.DoDragDrop($data, [Windows.Forms.DragDropEffects]::Copy)
    })
    $pic.Add_MouseUp({
        param($s, $e)
        $c = $this.Tag
        if ($null -ne $c.DragStart) { $c.DragStart = $null; Open-Capture $c.Path }
    })
    $panel.Controls.Add($pic)

    $y = 26 + $thumb.Height + 6
    $buttons = @(
        (New-PreviewButton '開く' '開く' $card { Open-Capture $this.Tag.Path }),
        (New-PreviewButton 'コピー' 'コピー（ファイル＋画像）' $card { Copy-Capture $this.Tag.Path; Set-CardNotice $this.Tag 'コピーしました' }),
        (New-PreviewButton 'パス' 'パスをコピー' $card { Copy-CapturePath $this.Tag.Path; Set-CardNotice $this.Tag 'パスをコピーしました' }),
        (New-PreviewButton '表示' 'エクスプローラーで表示' $card { Show-InExplorer $this.Tag.Path })
    )
    $bw = [int](($inner - 3 * 5) / 4)
    for ($i = 0; $i -lt 4; $i++) {
        $buttons[$i].Width = $bw
        $buttons[$i].Location = New-Object Drawing.Point((10 + $i * ($bw + 5)), $y)
        $panel.Controls.Add($buttons[$i])
    }

    $f.Size = New-Object Drawing.Size(($inner + 20 + 2), ($y + 26 + 8 + 2))
    $card.Form = $f
    $card.Title = $title
    $card.Pic = $pic
    $sec = [int]$script:Settings.previewSeconds
    if ($sec -gt 0) { $card.HideAt = (Get-Date).AddSeconds($sec) }
    $card
}

function Show-Preview([string]$Path) {
    $card = New-PreviewCard $Path
    $script:Cards.Insert(0, $card)
    while ($script:Cards.Count -gt $script:MaxCards) { Remove-PreviewCard $script:Cards[$script:Cards.Count - 1] }
    Update-CardLayout
    $card.Form.Show()
}

function Invoke-PreviewTick {
    foreach ($p in @($script:PendingPreviews)) {
        # 読める（書き込みが終わった）ようになってから出す。5秒たっても読めなければあきらめる
        try {
            $probe = Read-ImageNoLock $p.Path
            $probe.Dispose()
            $script:PendingPreviews.Remove($p)
            Show-Preview $p.Path
        } catch {
            $p.Tries++
            if ($p.Tries -ge 20) { $script:PendingPreviews.Remove($p); Write-Log "プレビューを出せませんでした: $($p.Path) $_" }
        }
    }
    foreach ($c in @($script:Cards)) {
        if (-not [IO.File]::Exists($c.Path)) { Remove-PreviewCard $c; continue }   # ファイルが消されたら閉じる
        if ($c.TitleRestoreAt -and [datetime]::Now -gt $c.TitleRestoreAt) {
            $c.Title.Text = $c.Label
            $c.TitleRestoreAt = $null
        }
        if ($c.HideAt -eq [datetime]::MaxValue) { continue }   # 自動で消さない設定（既定）
        if ($c.Form.Bounds.Contains([Windows.Forms.Cursor]::Position)) {
            $c.HideAt = [datetime]::Now.AddSeconds(2)            # マウスを乗せている間は消さない
        } elseif ([datetime]::Now -gt $c.HideAt) {
            Remove-PreviewCard $c
        }
    }
}

function Initialize-Preview {
    # ファイル監視のイベントを UI スレッドで受けるための見えない部品
    $script:UiSync = New-Object Windows.Forms.Control
    [void]$script:UiSync.Handle
}

function Start-CaptureWatchers {
    $script:Watchers = foreach ($d in Get-WatchFolders) {
        $w = New-Object IO.FileSystemWatcher($d)
        $w.IncludeSubdirectories = $false
        $w.NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite'
        $w.SynchronizingObject = $script:UiSync
        $w.Add_Created({ param($s, $e) Request-Preview $e.FullPath })
        $w.Add_Renamed({ param($s, $e) Request-Preview $e.FullPath })
        $w.EnableRaisingEvents = $true
        $w
    }
}

# ---------- メニュー ----------

function New-MenuItem([string]$Text, $Tag, [scriptblock]$OnClick) {
    $mi = New-Object Windows.Forms.ToolStripMenuItem($Text)
    $mi.Tag = $Tag
    if ($OnClick) { $mi.Add_Click($OnClick) }
    $mi
}

function New-Verbs([string]$Path) {
    New-MenuItem '開く' $Path { Open-Capture $this.Tag }
    New-MenuItem 'コピー' $Path { Copy-Capture $this.Tag }
    New-MenuItem 'パスをコピー' $Path { Copy-CapturePath $this.Tag }
    New-MenuItem 'エクスプローラーで表示' $Path { Show-InExplorer $this.Tag }
}

function Build-Menu {
    foreach ($it in @($script:Menu.Items)) { $it.Dispose() }
    $script:Menu.Items.Clear()

    $items = @(Get-RecentItems 10)
    if ($items.Count -eq 0) {
        $empty = New-MenuItem 'まだスクリーンショットがありません' $null $null
        $empty.Enabled = $false
        [void]$script:Menu.Items.Add($empty)
    } else {
        $first = $items[0]
        $title = New-MenuItem (Get-Label $first) $null $null
        $title.Enabled = $false
        [void]$script:Menu.Items.Add($title)

        Clear-StaleThumbnails $items

        # 一番新しい1件は大きなサムネイル（クリックで開く）
        $pb = New-Object Windows.Forms.PictureBox
        $pb.Image = Get-CachedThumbnail $first 280
        $pb.SizeMode = [Windows.Forms.PictureBoxSizeMode]::Zoom
        $pb.Size = $pb.Image.Size
        $pb.Cursor = [Windows.Forms.Cursors]::Hand
        $pb.Tag = $first.FullName
        $pb.Add_Click({ $script:Menu.Close(); Open-Capture $this.Tag })
        $thumbHost = New-Object Windows.Forms.ToolStripControlHost($pb)
        $thumbHost.AutoSize = $false
        $thumbHost.Size = $pb.Size
        $thumbHost.Margin = New-Object Windows.Forms.Padding(8, 4, 8, 4)
        [void]$script:Menu.Items.Add($thumbHost)

        foreach ($v in New-Verbs $first.FullName) { [void]$script:Menu.Items.Add($v) }

        if ($items.Count -gt 1) {
            # 続く9件も開いた時点でプレビューを並べる（3列）。クリックでその1件の操作を出す
            [void]$script:Menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
            $older = New-MenuItem ("それより前（{0}件）" -f ($items.Count - 1)) $null $null
            $older.Enabled = $false
            [void]$script:Menu.Items.Add($older)

            # FlowLayoutPanel だとメニューが高さを見誤ってスクロールが出るので、固定サイズの Panel に自分で並べる
            $cell = 90; $gap = 5
            $grid = New-Object Windows.Forms.Panel
            $grid.BackColor = [Drawing.Color]::Transparent
            $rows = [Math]::Ceiling(($items.Count - 1) / 3)
            $grid.Size = New-Object Drawing.Size((($cell + $gap) * 3 - $gap), (($cell + $gap) * $rows - $gap))
            $i = 0
            foreach ($f in $items[1..($items.Count - 1)]) {
                $tpb = New-Object Windows.Forms.PictureBox
                $tpb.Size = New-Object Drawing.Size($cell, $cell)
                $tpb.Location = New-Object Drawing.Point((($i % 3) * ($cell + $gap)), ([Math]::Floor($i / 3) * ($cell + $gap)))
                $i++
                $tpb.SizeMode = [Windows.Forms.PictureBoxSizeMode]::Zoom
                $tpb.BackColor = [Drawing.Color]::FromArgb(24, 0, 0, 0)
                $tpb.Image = Get-CachedThumbnail $f $cell
                $tpb.Cursor = [Windows.Forms.Cursors]::Hand
                $tpb.Tag = $f.FullName
                $script:Tips.SetToolTip($tpb, ("{0}`n{1}" -f (Get-Label $f), $f.Name))
                $tpb.Add_Click({
                    $path = $this.Tag
                    $script:Menu.Close()
                    $script:VerbMenu.Items.Clear()
                    foreach ($v in New-Verbs $path) { [void]$script:VerbMenu.Items.Add($v) }
                    $script:VerbMenu.Show([Windows.Forms.Cursor]::Position)
                })
                $grid.Controls.Add($tpb)
            }
            $gridHost = New-Object Windows.Forms.ToolStripControlHost($grid)
            $gridHost.AutoSize = $false
            $gridHost.Size = $grid.Size
            $gridHost.Margin = New-Object Windows.Forms.Padding(8, 0, 8, 6)
            [void]$script:Menu.Items.Add($gridHost)
        }
    }

    [void]$script:Menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))

    $clip = New-MenuItem 'クリップボードの画像も拾う' $null {
        $script:Settings.watchClipboard = -not $script:Settings.watchClipboard
        Save-Settings
    }
    $clip.Checked = [bool]$script:Settings.watchClipboard
    [void]$script:Menu.Items.Add($clip)

    $prev = New-MenuItem '撮ったら右側にプレビューを出す' $null {
        $script:Settings.showPreview = -not $script:Settings.showPreview
        Save-Settings
    }
    $prev.Checked = [bool]$script:Settings.showPreview
    [void]$script:Menu.Items.Add($prev)

    $keep = New-MenuItem 'クリップボードの画像を残す日数' $null $null
    foreach ($days in 1, 3, 7, 14) {
        $d = New-MenuItem "$days 日" $days {
            $script:Settings.retentionDays = [int]$this.Tag
            Save-Settings
            Remove-OldClips
        }
        $d.Checked = ([int]$script:Settings.retentionDays -eq $days)
        [void]$keep.DropDownItems.Add($d)
    }
    [void]$script:Menu.Items.Add($keep)

    $login = New-MenuItem 'ログイン時に起動' $null {
        if (Test-Path -LiteralPath $script:StartupLnk) { Remove-Item -LiteralPath $script:StartupLnk -Force }
        else { New-ShotBarShortcut $script:StartupLnk }
    }
    $login.Checked = Test-Path -LiteralPath $script:StartupLnk
    [void]$script:Menu.Items.Add($login)

    $folders = New-MenuItem '保存先フォルダを開く' $null $null
    foreach ($p in @(Get-WatchFolders) + $script:ClipDir) {
        [void]$folders.DropDownItems.Add((New-MenuItem $p $p { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$($this.Tag)`"" }))
    }
    [void]$script:Menu.Items.Add($folders)

    [void]$script:Menu.Items.Add((New-MenuItem '終了' $null {
        $script:Notify.Visible = $false
        $script:Notify.Dispose()
        [Windows.Forms.Application]::Exit()
    }))
}

function New-TrayIcon {
    # 範囲選択の四隅を模したアイコン（明るい・暗いタスクバーのどちらでも見える青）
    $bmp = New-Object Drawing.Bitmap(32, 32)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([Drawing.Color]::Transparent)
    $blue = [Drawing.Color]::FromArgb(255, 0, 120, 212)
    $pen = New-Object Drawing.Pen($blue, 3.5)
    $corners = @(
        @(@(3, 12), @(3, 3), @(12, 3)),
        @(@(20, 3), @(29, 3), @(29, 12)),
        @(@(29, 20), @(29, 29), @(20, 29)),
        @(@(12, 29), @(3, 29), @(3, 20))
    )
    foreach ($c in $corners) {
        $pts = [Drawing.Point[]]($c | ForEach-Object { New-Object Drawing.Point($_[0], $_[1]) })
        $g.DrawLines($pen, $pts)
    }
    $g.FillEllipse((New-Object Drawing.SolidBrush($blue)), 11, 11, 10, 10)
    $g.Dispose()
    [Drawing.Icon]::FromHandle($bmp.GetHicon())
}

# ---------- 起動 ----------

[Windows.Forms.Application]::EnableVisualStyles()

$script:Menu = New-Object Windows.Forms.ContextMenuStrip
$script:VerbMenu = New-Object Windows.Forms.ContextMenuStrip
$script:Tips = New-Object Windows.Forms.ToolTip
$script:Menu.Add_Opening({
    param($s, $e)
    try { Build-Menu } catch { Write-Log "メニューの作成に失敗: $_" }
    $e.Cancel = $false
})

$script:Notify = New-Object Windows.Forms.NotifyIcon
$script:Notify.Icon = New-TrayIcon
$script:Notify.Text = 'ShotBar'
$script:Notify.ContextMenuStrip = $script:Menu
$script:Notify.Add_MouseUp({
    param($s, $e)
    if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) {
        # 左クリックでも右クリックと同じメニューを出す
        $m = [Windows.Forms.NotifyIcon].GetMethod('ShowContextMenu', [Reflection.BindingFlags]'Instance,NonPublic')
        [void]$m.Invoke($script:Notify, $null)
    }
})
$script:Notify.Visible = $true

$clipTimer = New-Object Windows.Forms.Timer
$clipTimer.Interval = 1000
$clipTimer.Add_Tick({ Invoke-ClipboardTick })
$clipTimer.Start()

Initialize-Preview
Start-CaptureWatchers
$previewTimer = New-Object Windows.Forms.Timer
$previewTimer.Interval = 250
$previewTimer.Add_Tick({ try { Invoke-PreviewTick } catch { Write-Log "プレビューの処理に失敗: $_" } })
$previewTimer.Start()

Remove-OldClips
$cleanTimer = New-Object Windows.Forms.Timer
$cleanTimer.Interval = 60 * 60 * 1000
$cleanTimer.Add_Tick({ Remove-OldClips })
$cleanTimer.Start()

[Windows.Forms.Application]::Run()
$script:Mutex.ReleaseMutex()
