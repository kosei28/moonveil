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

`/usr/local/bin/moonveil` にリリースビルドがコピーされる。

## 使い方

```
make run
```

メニューバーに 🌙 アイコンが表示される。

1. アイコンをクリック → **Enable** → パスワード入力 → スリープ抑止ON（アイコンが塗りつぶしに変わる）
2. **Disable** で解除
3. **Quit** で終了（自動で `disablesleep 0` に戻る）

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
| `make install` | `/usr/local/bin` にインストール |
| `make uninstall` | アンインストール |
| `make clean` | ビルド成果物を削除 |
