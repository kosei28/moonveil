# moonveil

MacBookの蓋を閉じたとき、スリープせずにロック＋画面オフにするメニューバーアプリ。

蓋を閉じても作業を継続させたいけど、セキュリティのためにロックはしたい場面で使う。

## インストール

```
make install
```

`/Applications/Moonveil.app` にインストールされる。

## 使い方

メニューバーに `moon.zzz` アイコンが表示される。

| メニュー項目 | 内容 |
|---|---|
| **Enable / Disable** | スリープ抑止のON/OFF。ONでアイコンが `moon.zzz.fill` に変わる |
| **Lock Screen** | 蓋を閉じたときにロック＋画面オフにするモード（デフォルト） |
| **Clamshell** | 蓋を閉じてもそのまま外部モニターで作業を続けるモード |
| **Launch at Login** | ログイン時の自動起動。チェックマークで状態表示 |
| **Quit** | 終了。スリープ抑止中なら自動で解除してから終了する |

初回のEnableで管理者パスワードを求められる。`/etc/sudoers.d/moonveil` にNOPASSWDルールがインストールされるため、2回目以降はダイアログなしで即座にON/OFFできる。

### Enable中の挙動

| 操作 | Lock Screen モード | Clamshell モード（外部モニターあり） |
|---|---|---|
| 蓋を閉じる | スリープせず、ロック＋画面オフ | スリープせず、そのまま作業を継続 |
| 電源ボタンを押す | スリープせず、ロック（macOS標準動作） | 同左 |
| 放置 | スリープしない。ディスプレイスリープタイマーに従って画面オフ | 同左 |

Clamshellモードでも外部モニターが接続されていない場合は、Lock Screenモードと同じ動作（ロック＋画面オフ）になる。

## 要件

- macOS 13+
- Swift 5.9+

## アンインストール

```
make uninstall
```

アプリと `/etc/sudoers.d/moonveil` を削除する。

## 仕組み

| 機能 | 実装 |
|---|---|
| スリープ抑止 | `pmset disablesleep` |
| 画面ロック | `SACLockScreenImmediate`（login.framework private API） |
| ディスプレイオフ | IODisplayWrangler `IORequestIdle` / `pmset displaysleepnow` |
| 蓋の検知 | IOPMrootDomain `AppleClamshellState` を1秒ポーリング |
| スリープ要求の拒否 | `IORegisterForSystemPower` で `kIOMessageCanSystemSleep` を veto |
| 権限昇格 | `NSAppleScript` → sudoersルールで以降はパスワード不要 |
| ログイン項目 | `SMAppService.mainApp` |

## 開発

| コマンド | 内容 |
|---|---|
| `make build` | デバッグビルド |
| `make run` | ビルド＋実行 |
| `make release` | リリースビルド |
| `make app` | `.app` バンドルを生成 |
| `make install` | `/Applications` にインストール |
| `make uninstall` | アンインストール（sudoersルールも削除） |
| `make clean` | ビルド成果物を削除 |
