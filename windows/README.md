# ShotBar for Windows

ShotBar の Windows 版。タスクトレイに常駐し、直近のスクリーンショット・画面収録をその場で **開く / コピー / パスをコピー / エクスプローラーで表示** できる。撮影機能は持たない（Win+Shift+S・Win+PrtScn・Snipping Tool の録画・Xbox Game Bar で撮ったものを扱う）。

`ShotBar.ps1` 1 本で、Windows PowerShell 5.1 と Windows 標準の部品（WinForms）だけで動く。追加のインストール・ビルドは要らない。

## 入れる

```powershell
git clone https://github.com/bytask/shotbar.git
cd shotbar
powershell -ExecutionPolicy Bypass -File windows\ShotBar.ps1 -Install     # スタートメニューに登録して起動
```

外すのは `-Uninstall`。clone した場所のスクリプトを直接起動するので、`git pull` すれば次の起動から新しい版になる。ログイン時に起動するかはメニューの「ログイン時に起動」で切り替える（既定はオフ）。

管理者側の設定（グループポリシー）で PowerShell スクリプトの実行を禁止しているPCでは動かない。

## Mac 版との対応

| Mac 版 | Windows 版 |
|---|---|
| ⌘⇧3 / ⌘⇧4 / ⌘⇧5 で撮ったもの | Win+Shift+S（自動保存）・Win+PrtScn → `ピクチャ\Screenshots`、Snipping Tool の録画 → `ビデオ\Screen Recordings`、Game Bar（Win+Alt+R）→ `ビデオ\Captures` |
| `com.apple.screencapture` の保存先 | Windows の「スクリーンショット」既知フォルダ（OneDrive へ移していても追従）。ほかのフォルダは `settings.json` の `extraFolders` に足す |
| メニューバーのアイコン | タスクトレイのアイコン（左右どちらのクリックでも開く） |
| 一番新しい 1 件＋続く 9 件（サブメニュー） | 一番新しい 1 件は大きなサムネイルと 4 つの動詞。続く 9 件も開いた時点で 3×3 のサムネイルで並び、クリックでその 1 件の動詞が出る（マウスを乗せると日時） |
| コピー（file URL＋画像データ） | ファイル（FileDrop）＋画像（Bitmap と PNG）。画面収録はファイルだけ |
| Finder で表示 | エクスプローラーで表示 |
| クリップボードの画像だけの項目を拾う | 同じ。`%LOCALAPPDATA%\ShotBar\clipboard\` に PNG で残し「クリップボード HH:mm」として並べる。残す日数は 1 / 3 / 7 / 14 日（既定 7 日） |
| ログイン時に起動（SMAppService） | スタートアップフォルダへのショートカット |
| メニューバーで畳まれないための処理 | 無し。Windows はアプリから位置を固定できない。`^` の中に入ったら「設定 → 個人用設定 → タスクバー → その他のシステムトレイアイコン」で ShotBar をオンにする |

Win+Shift+S は自動保存とクリップボードの両方に入るので、直近 20 秒以内に同じ大きさのファイルが出来ていればクリップボード側は残さない（二重にならない）。

## 撮影直後のプレビュー（Windows 版だけ）

撮ると画面の右端に小さなプレビューが出る。最大 5 枚まで縦に積んで残し、新しいものが上。6 枚目が来たら一番古いものを閉じる。右下は Snipping Tool の通知と重なるので、全体を上下中央に寄せている。

- サムネイルをクリックで開く。ドラッグで Slack やフォルダへファイルとして渡せる
- ボタンは 開く / コピー / パス / 表示。押してもプレビューは残る
- 自動では消えない。閉じるのは × か、元のファイルを消したとき。自動で消したいときは `settings.json` の `previewSeconds` に秒数を入れる（マウスを乗せている間は消えない）
- 表示しても入力中のウィンドウのフォーカスは奪わない
- メニューの「撮ったら右側にプレビューを出す」でオン・オフ
- 対象は画像だけ（画面収録は録画を始めた時点でファイルが出来るため出さない）

## 作り

| 場所 | 役割 |
|---|---|
| `windows/ShotBar.ps1` | 全部。`-Install` / `-Uninstall`、タスクトレイとメニュー、保存先の解決（`SHGetKnownFolderPath`）、クリップボードの監視（1 秒ごとに `GetClipboardSequenceNumber`）、保存先の監視（`FileSystemWatcher`）、プレビュー窓 |
| `%LOCALAPPDATA%\ShotBar\settings.json` | 設定（`retentionDays` / `watchClipboard` / `showPreview` / `previewSeconds` / `extraFolders`） |
| `%LOCALAPPDATA%\ShotBar\error.log` | うまくいかなかった処理の記録 |

`ShotBar.ps1` は **BOM 付き UTF-8** で保存すること。Windows PowerShell 5.1 は BOM の無い UTF-8 を ANSI として読むので、日本語のメニューが化けて構文エラーになる。
