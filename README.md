# ShotBar

macOS のメニューバーに常駐し、直近のスクリーンショットと画面収録をその場で **開く / コピー / パスをコピー / Finder で表示** できる小さなアプリ。Finder で保存先を探しに行かずに済む。

- 純正の ⌘⇧3 / ⌘⇧4 / ⌘⇧5 で撮ったものをそのまま扱う（撮影機能は持たない）
- 保存先は `defaults read com.apple.screencapture` の `location` / `location-screenshot` / `location-screenrecording` を読む。未設定なら `~/Desktop`
- 一番新しい 1 件は大きなサムネイルと 4 つの動詞、続く 9 件はサブメニュー
- 「コピー」はファイル（file URL）と画像データを同じ項目に載せるので、Finder / Slack にはファイルとして、画像を受けるアプリには画像として貼れる。画面収録はファイルだけ
- 「パスをコピー」は絶対パスの文字列。ターミナルや Claude Code に貼る用
- 「ログイン時に起動」はメニューのトグル（`SMAppService`）
- **クリップボードに撮ったもの**（⌃⌘⇧3 / ⌃⌘⇧4、⌘⇧5 の「クリップボードにコピー」）も拾う。ファイルも URL も文字も無い画像だけの項目をクリップボードに見つけたら `~/Library/Application Support/ShotBar/clipboard/` に PNG で残し、同じメニューに「クリップボード HH:mm」として並べる。残す日数はメニューで 1 / 3 / 7 / 14 日（既定 7 日）。Preview などで画像だけをコピーしたものも同じ扱いになる。初回に macOS の「ペーストボードへのアクセス」の確認が出たら許可する（システム設定 → プライバシーとセキュリティで「常に許可」にできる）
- メニューバーの位置: macOS 27 は幅が足りないと左端の項目から「«」の裏に畳む。MenuBarAgent は一度置いた項目の並びを bundle ID + autosave 名で覚えていて、`NSStatusItem Preferred Position` は初めて見る名前のときだけ効く（1 が右端）。そこで起動のたびに新しい名前で登録し直して右端（システム項目のすぐ左）に置く。ほかのアプリが増えても ShotBar は畳まれない。自分で ⌘ドラッグした位置を残したいときは `defaults write com.bytask.shotbar keepStatusItemPosition -bool true`

## 入れる

Mac 版と Windows 版は入れ方を分けてある。どちらも、もう片方の OS の分は手元に落とさない。

### Mac

```sh
git clone --filter=blob:none --sparse https://github.com/bytask/shotbar.git
cd shotbar
git sparse-checkout set Sources Resources scripts   # Mac 版の分だけ取り出す（windows/ は落とさない）
./scripts/install.sh   # swift build → ShotBar.app を組んで ~/Applications に入れて起動
```

Xcode（Swift 5.9 以上、macOS 14 以上）が要る。署名は ad hoc なので自分の Mac 専用。入れ替えも同じコマンド、外すのは `./scripts/uninstall.sh`。

### Windows

タスクトレイに常駐する Windows 版が [`windows/`](windows/README.md) にある。PowerShell スクリプト 1 本で、ビルドは要らない。clone はせず、PowerShell に次を貼ると本体の 1 本だけを落として `%LOCALAPPDATA%\ShotBar\` に入れる（Mac 版のコードは入らない）。

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072   # TLS 1.2
$f = Join-Path $env:TEMP 'ShotBar.ps1'
Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/bytask/shotbar/main/windows/ShotBar.ps1 -OutFile $f
powershell -ExecutionPolicy Bypass -File $f -Install; Remove-Item $f
```

## 作り

| ファイル | 役割 |
|---|---|
| `Sources/ShotBar/AppDelegate.swift` | NSStatusItem とメニュー。開く・コピー・パス・Finder・ログイン時起動 |
| `Sources/ShotBar/CaptureStore.swift` | 保存先の解決、新しい順の一覧、フォルダ監視（kqueue） |
| `Sources/ShotBar/ClipboardStore.swift` | クリップボードの監視（1 秒ごとに changeCount）、画像だけの項目の保存、日数での掃除 |
| `Sources/ShotBar/Thumbnails.swift` | QuickLookThumbnailing でサムネイル |
| `Resources/Info.plist` | `LSUIElement`（Dock に出さない）、Bundle ID `com.bytask.shotbar` |
| `scripts/build.sh` | `swift build -c release` → `dist/ShotBar.app` → `codesign --sign -` |
| `scripts/make-icon.swift` | `Resources/AppIcon.icns` を描く |

## 先行品

同じ用途で先にあるもの。これで足りる人はこちらを。

- Raycast 内蔵「Search Screenshots」「Paste Latest Screenshot」: 保存先の一覧とコピー・Finder 表示。ホットキー起動で、メニューバー常駐ではない
- [Vignette](https://github.com/petekp/vignette): 保存先を監視して直近の束を出し、パスのコピーもある。撮影の流れごと置き換える作り
- [ScreenshotMenu](https://screenshotmenu.nestimer.com/) / [BetterShot](https://github.com/KartikLabhshetwar/better-shot) / CleanShot X: 自前の撮影機能を持つアプリ

ShotBar は「純正の撮影はそのまま、メニューバーに直近の一覧だけ」に絞ったもの。

## License

MIT
