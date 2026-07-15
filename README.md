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
| **Use CapsLock to Toggle** | CapsLockキーでスリープ抑止をON/OFFするモード（デフォルト無効） |
| **Launch at Login** | ログイン時の自動起動。チェックマークで状態表示 |
| **Quit** | 終了。スリープ抑止中なら自動で解除してから終了する |

初回のEnableで管理者パスワードを求められる。`/etc/sudoers.d/moonveil` にNOPASSWDルールがインストールされるため、2回目以降はダイアログなしで即座にON/OFFできる。

### CapsLock Toggle

CapsLockキーでスリープ抑止のON/OFFを切り替えるモード。有効にすると：

- CapsLock本来の動作（大文字入力の切り替え）は完全に無効化される
- CapsLockのLEDがスリープ抑止の状態を示す（ON=点灯、OFF=消灯）

初回有効化時にアクセシビリティ権限を求められる。権限が付与されていない場合はメニューに「⚠ Grant Accessibility Permission…」が表示される。

`make install` 時にアクセシビリティ権限はリセットされるため、再インストール後は再度権限の付与が必要。

この機能は [Capsomnia](https://github.com/fuji-mak/Capsomnia) にインスパイアされている。CapsLock本来の動作が残るCapsomniaとは異なり、HIDレベルのリマップにより完全に無効化している。

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
| CapsLockリマップ | `hidutil` で CapsLock → F18 にリマップし、イベントタップで F18 を捕捉 |
| CapsLock LED | `IOHIDDeviceSetValue` で直接制御 |
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
