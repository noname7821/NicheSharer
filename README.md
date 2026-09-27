# NicheShare

Remote-view and remote-control your jailbroken iPhone from a Windows PC.
The phone streams its screen live, the PC sends back taps, swipes, scrolls,
keyboard input and the Home button. Two ways to connect: **USB (fast, no
server)** or **6-digit code (over the internet)**.

## Features

- Live screen (~30fps JPEG stream, only sends changed frames)
- Tap, drag = swipe, mouse wheel = scroll
- PC keyboard types on the phone (tap a text field first)
- Home button (real button press on Touch ID devices, gesture fallback)
- USB direct mode via bundled `iproxy` (autostarted by the viewer)
- Code mode via signaling server (rooms expire after 10 minutes)
- Auto-reconnect + stay-awake while sharing

## Requirements

- Jailbroken iPhone (tested on Dopamine, iOS 15.8.8, rootless)
- Windows 10/11 PC
- USB cable + Apple USB driver (iTunes or 3uTools) for USB mode

## Install (iPhone)

1. Install the `.deb` from the [latest release](../../releases/latest)
   (Sileo/Filza or `dpkg -i`, then respring).
2. Open the NicheShare app and tap **Start sharing**.
3. USB mode just works once the viewer connects.
   Code mode shows a 6-digit code in the app.

## Use (PC)

Unzip `NicheShareViewer-win-x64.zip` from the release and start
`NicheShareViewer.exe` (keep the `tools/` folder next to it).

- **USB:** plug the phone in via USB, click **Connect USB**.
  The viewer starts its bundled `iproxy` itself, nothing to install.
- **Code:** enter the 6-digit code from the app, click **Connect**.
  Server is fixed to `https://nichesharer.onrender.com`.

In the screen window: click = tap, drag = swipe, wheel = scroll,
type = keyboard, **Home** button = Home.

## Protocol

USB mode speaks JSON lines over TCP `127.0.0.1:18000` (forwarded by
usbmuxd, same schema as the websocket below).

- `POST /api/room` -> `{ code }` (6 digits, 10 min TTL)
- `GET /api/room/:code` -> `{ exists, hasPhone, viewers, status }`
- `WS /ws?code=..&role=phone|pc`
  - pc -> phone: `{ t:'input', kind:'tap'|'swipe'|'scroll'|'home'|'key', ... }`
    (coords normalized 0..1)
  - phone -> pc: `{ t:'frame', data }` (base64 JPEG), `{ t:'status', ... }`
  - either: `{ t:'ping' }` -> `{ t:'pong' }`

## Build

- Tweak: Theos, builds `.deb` in CI (`.github/workflows/tweak.yml`)
- Viewer: `dotnet build -c Release viewer/` (needs .NET 8 SDK)
- Server: `npm install && node server.js`

## Layout

| Path | What |
|---|---|
| `tweak/` | Jailbreak tweak (capture, HID input, USB + WS daemon) |
| `viewer/` | Windows PC viewer (WPF, bundled iproxy) |
| `app/` | Native receiver app (code display, start/stop) |
| `server.js` + `public/` | Signaling server + web viewer |

## Credits

Touch injection follows the technique pioneered by
[TrollVNC](https://github.com/OwnGoalStudio/TrollVNC)
(`IOHIDEventSystemClient` + digitizer events). Bundled `iproxy` comes
from [libimobiledevice](https://libimobiledevice.org/).

## Copyright

Copyright (c) 2026 noname7821. See [LICENSE](LICENSE).
Jailbreak-only: remote control is impossible on stock iOS (sandbox).
