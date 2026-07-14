# moonveil

MacBookの蓋を閉じたとき、スリープせずにロック＋画面オフにするメニューバーアプリ。

蓋を閉じても作業を継続させたいけど、セキュリティのためにロックはしたい場面で使う。

## 動作

- **スリープ抑止**: `pmset disablesleep` でシステムスリープを無効化（蓋閉じ・アイドル両方）
- **画面ロック**: `SACLockScreenImmediate`（login.framework private API）
- **ディスプレイオフ**: IODisplayWrangler の `IORequestIdle`、フォールバックで `pmset displaysleepnow`
- **蓋の検知**: IOPMrootDomain の `AppleClamshellState` を1秒ポーリング
- **スリープ要求の拒否**: `IORegisterForSystemPower` コールバックで `kIOMessageCanSystemSleep` を veto

## インストール

```
make install
```

`/Applications/Moonveil.app` にアプリバンドルがコピーされる。

## 使い方

```
make run
```

メニューバーに 🌙 アイコンが表示される。

1. アイコンをクリック → **Enable** → 初回のみTouch ID / パスワード → スリープ抑止ON（アイコンが塗りつぶしに変わる）
2. **Disable** で解除
3. **Quit** で終了（自動で `disablesleep 0` に戻る）

初回の認証で `/etc/sudoers.d/moonveil` にNOPASSWDルールがインストールされるため、2回目以降はダイアログなしで即座にON/OFFできる。`make uninstall` でルールも削除される。

### Enable中の挙動

| 操作 | 挙動 |
|---|---|
| 蓋を閉じる | スリープせず、ロック＋画面オフ |
| 電源ボタンを押す | スリープせず、ロック（macOS標準動作）。ディスプレイスリープのタイマーに従って画面オフ |
| 放置 | スリープしない。ディスプレイスリープのタイマーに従って画面オフ |

## 要件

- macOS 13+
- Swift 5.9+
- 管理者権限（Enable時にダイアログで要求）

## Makefile

| コマンド | 内容 |
|---|---|
| `make build` | デバッグビルド |
| `make run` | ビルド＋実行 |
| `make release` | リリースビルド |
| `make app` | `.app` バンドルを生成 |
| `make install` | `/Applications` にインストール |
| `make uninstall` | アンインストール |
| `make clean` | ビルド成果物を削除 |
