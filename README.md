# NicheShare (Phase 1: pairing + remote input loop)

Jailbreak receiver app for screen sharing + remote control, powered by a
FlashDrop-style code server. The iPhone shows a code, the PC enters it and
gets the screen plus remote access.

## Honest roadmap

| Phase | What | Status |
|---|---|---|
| 1 | Signaling server (rooms by code), PC viewer, phone simulator | **done, tested** |
| 3a | Jailbreak tweak scaffold: daemon + pairing + capture ticks + input path (Theos, builds `.deb` in CI) | **here now** |
| 2/3b | Real screen frames (VideoToolbox H.264 + WebRTC) + verified touch injection on-device | next |

Why this order: viewing needs a capture pipeline, control needs a jailbreak
tweak. Nothing of that can be tested from here, so Phase 1 proves the loop
(code -> connect -> input events arrive) with a simulated phone today.

## Run it

```bash
npm install
node server.js
```

- Phone sim: http://localhost:3001/phone.html -> Start sharing -> note the code
- PC viewer: http://localhost:3001/viewer.html -> enter code -> Connect
- Click the pad / type: the phone sim logs every input event. That exact
  JSON is what the real tweak will later turn into touches.

## Protocol (for the iOS app + tweak)

- `POST /api/room` -> `{ code }` (6 digits, 10 min TTL)
- `GET /api/room/:code` -> `{ exists, hasPhone, viewers, status }`
- `POST /api/room/:code/heartbeat` `{ status }` (phone keep-alive)
- `WS /ws?code=..&role=phone|pc`
  - pc -> phone: `{ t:'input', kind:'tap'|'key', x, y, key }` (x/y 0..1)
  - phone -> pc: `{ t:'status', sharing, note }`, later `{ t:'frame', data }` (base64 jpeg)
  - either: `{ t:'ping' }` -> `{ t:'pong' }`

## Deploy (Render)

Build: `npm install`, Start: `node server.js`. No disk needed (rooms are
in-memory, like FlashDrop codes).

## Jailbreak notes (Phase 3)

- Capture: snapshot `IOSurface` of the main display (or `IOMobileFramebuffer`),
  encode H.264 with VideoToolbox, send via WebRTC datachannel or WS frames.
- Control: inject `BKSHIDEvent` touch/key events through backboardd
  (requires jailbreak entitlements, same class of API Esign-era tweaks used).
- The tweak ships the receiver; the homescreen app only shows the code and
  start/stop, like planned.
