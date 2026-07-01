# PodsMute (Airpods-mute fork)

A macOS menu bar app for **system‑wide microphone mute** — one press mutes/unmutes you in **Google Meet, Zoom, Slack huddles** and every other app at once, by muting the input device(s) directly.

Trigger it with a **global keyboard shortcut (⇧⌥⌘M)** or by **left‑clicking the menu‑bar icon**.

This is a fork of [cyanicr/podsmute](https://github.com/cyanicr/podsmute). See [What this fork adds](#what-this-fork-adds).

> ### なぜ AirPods のステム押しではなくショートカットなのか
> 元の podsmute は AirPods の「消音ジェスチャ」を捕まえる方式ですが、検証の結果 **macOS (Sonoma〜Tahoe) では Slack / Meet / Zoom に対してこのジェスチャが機能しません**。これらのアプリは OS に「通話(電話/FaceTime)」として認識されず、AirPods が常に *メディア再生モード* のままになるため、消音ジェスチャ自体が発動せず、捕まえるべきイベントが生まれないからです(audioaccessoryd のログにミュートイベントが一切出ないことを確認済み)。そこで本フォークでは、**確実に効くグローバルショートカット**を主操作にしています。ミュート機構(全入力デバイス一括ミュート)は同じで、どのアプリでも相手に声が届きません。

---

## なぜ効くのか / How it works

普通のアプリ (Meet / Zoom / Slack) は AirPods の「ミュート」ジェスチャに対応していません。このアプリは、AirPods を押したときに macOS の `audioaccessoryd` が出す通知 (`com.apple.audioaccessoryd.MuteState`) を捕まえ、**Core Audio で入力デバイスをミュート**します。入力デバイスをミュートするので、**どのアプリを使っていても相手にはあなたの声が届きません。**

> **全入力デバイスをまとめてミュートします。** 既定の1台だけをミュートすると、会議アプリが別のデバイス(例: 既定は内蔵マイクなのに会議は AirPods を使用)を掴んでいたときに無音になりません。そこで実在する入力デバイス(内蔵マイク・AirPods・USBマイク等)を**全部同時に**ミュート/解除します(Teams等の仮想デバイスは除外)。デバイスが増減・切替しても、その都度いまのミュート状態を再適用します。

```
AirPods stem press ──▶ audioaccessoryd posts a Darwin notification
                          │
                          ▼
                    PodsMute catches it
                          │
                          ▼
        Core Audio: default input device mute = ON/OFF   ← works in ALL apps
```

> **重要:** これは OS レベルのミュートです。Meet / Zoom / Slack の *アプリ内* ミュートボタンの表示とは連動しません。アプリ側が「ミュート解除」に見えても、メニューバーのバッジが赤 (Muted) なら相手には聞こえていません。**メニューバーのバッジが正解の状態です。**

---

## 使い方 (クイックスタート)

### 0. DMG からインストール（ビルド不要）

`dist/PodsMute.dmg` をダブルクリック → **PodsMute を Applications フォルダにドラッグ** → `/Applications/PodsMute.app` を起動。

> ⚠️ **初回起動**: このアプリはあなたのMac用にローカル署名(ad-hoc)しているため、初回は「開発元を確認できない」と出ます。**アプリを右クリック → 「開く」**、または **システム設定 → プライバシーとセキュリティ → 「このまま開く」** で一度許可すればOKです。

自分でビルドし直す/DMGを作り直す場合は下記。

### 1. ビルド（フル Xcode は不要）

このフォークは **Command Line Tools だけ** でビルドできます（`swift` があれば OK）。

```bash
cd Airpods-mute
./build.sh
```

`dist/PodsMute.app` が生成されます（DMG も作るなら `./make-dmg.sh` → `dist/PodsMute.dmg`）。

メニューバーにヘッドフォンのアイコンが出れば起動しています。ミュートの切り替えは:

- **グローバルショートカット `⇧⌥⌘M`**(Shift+Option+Command+M)— どのアプリが前面でも効く。会議中はこれを押すだけ。
- **メニューバーのアイコンを左クリック** — ワンタップでON/OFF。
- 右クリック（またはControl+クリック）でメニュー。

🟢 緑=ミュート解除 / 🔴 赤=ミュート。**メニューバーのバッジが正解の状態**です(会議アプリ自身のミュートボタン表示とは連動しません)。

### 2. macOS 側で AirPods のミュートジェスチャを有効化

1. AirPods Pro のファームウェアを最新に（**mute/unmute は 6A300 以降**が必要）。
2. **システム設定 → (サイドバーの) お使いの AirPods** を開く。
3. 通話コントロールで、ステムの **1回押し** または **2回押し** に **「ミュート / ミュート解除 (Mute & unmute)」** を割り当てる。

### 3. 通話中に使う

Meet / Zoom / Slack ハドルなどで **マイクが使われている状態**(=通話中)にステムを押すと、PodsMute がミュート/解除します。メニューバーのバッジで確認:

- 🟢 緑のマイク = ミュート解除（相手に聞こえる）
- 🔴 赤のマイク（スラッシュ）= ミュート（相手に聞こえない）

左クリックでも手動トグル、右クリックでメニューが出ます。

---

## What this fork adds

| Area | Upstream | This fork |
| --- | --- | --- |
| Build | Requires full **Xcode** + `xcodegen` | Also builds with **Command Line Tools only** via `Package.swift` + `build.sh` (`swift build`) |
| Entry point | SwiftUI `@main` (`App/PodsMuteApp.swift`) | Adds AppKit `App/main.swift` for the SPM build (SwiftUI file kept for the Xcode build) |
| Mute detection | Registers several speculative notifications + distributed‑center listeners **always on** | Listens to `com.apple.audioaccessoryd.MuteState` by default; **debounces duplicates** and **suppresses the echo** from our own mute change so one press = one toggle; extra names gated behind `PODSMUTE_DEBUG` |
| Diagnostics | `print` to stdout (invisible when launched as a bundle) | `os.Logger` (subsystem `com.podsmute.app`) visible in **Console.app**, plus a `PODSMUTE_DEBUG=1` mode |

Both build paths still share the same services (`AudioMuteController`, `AudioAccessoryMonitor`, `BluetoothManager`, `StatusBarController`).

### Two ways to build

- **No Xcode (recommended here):** `./build.sh`
- **With Xcode:** `brew install xcodegen && xcodegen generate && open PodsMute.xcodeproj` (upstream flow)

---

## Verifying it works (without a live call)

You can simulate an AirPods press by posting the same Darwin notification, then check the input device's mute state flips:

```bash
open dist/PodsMute.app
# in another shell:
notifyutil -p com.apple.audioaccessoryd.MuteState   # = one "press"
```

Watch the menu bar badge toggle red/green. This is exactly how this fork was verified.

## Diagnostics / Troubleshooting

**Nothing happens when I press my AirPods during a call.**
The most likely cause is that macOS didn't post `com.apple.audioaccessoryd.MuteState`. Confirm what your macOS version emits:

```bash
# Run the app in diagnostic mode (logs every notification, watches extra names):
PODSMUTE_DEBUG=1 dist/PodsMute.app/Contents/MacOS/PodsMute
```

Then, in **Console.app**, filter by subsystem `com.podsmute.app` (or run):

```bash
log stream --level debug --predicate 'subsystem == "com.podsmute.app"'
```

Press your AirPods during a call and look for `Notification received: …`.
- If you see it → detection works; check that your input device supports mute (below).
- If you see nothing → the OS isn't posting the notification. Make sure the AirPods firmware is ≥ 6A300, the "Mute & unmute" gesture is assigned, and you're actually in a call (an app is using the mic).

**The badge toggles but I'm still heard (or still muted).**
Your default input device must support the Core Audio mute property. Check the current one:
- System Settings → Sound → Input. The built‑in mic and AirPods both support mute on recent macOS.

**The app's own mute button (Zoom/Meet) disagrees with the badge.**
Expected — this app mutes at the OS level, independent of the app's button. Trust the menu bar badge.

## Run at login

Copy the app to `/Applications`, then add it in **System Settings → General → Login Items → Open at Login**.

## Requirements

- macOS 13+ (the AirPods mute gesture needs Sonoma/Sequoia+ and recent AirPods firmware)
- Swift toolchain (Command Line Tools: `xcode-select --install`) — no full Xcode needed for `build.sh`
- AirPods Pro / AirPods Max / AirPods (with the mute gesture), paired via Bluetooth

## Credits

- Upstream: [cyanicr/podsmute](https://github.com/cyanicr/podsmute)
- Protocol research: [librepods](https://github.com/kavishdevar/librepods)

## License

MIT (inherited from upstream).
