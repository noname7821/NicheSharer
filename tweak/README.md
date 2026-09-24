# NicheShare tweak (jailbreak receiver, no HTML on the phone)

Theos/Logos tweak for jailbroken iPhones. It runs the receiver daemon:
pairs with the signaling server, shows nothing itself (the native app shows
the code), grabs the screen and injects remote input.

## Layout

- `Tweak.xm` – boots the daemon when SpringBoard finishes launching.
- `NSDaemon.m` – pairing (`POST /api/room`), WS client (`role=phone`),
  and a plain TCP command channel on `127.0.0.1:17999` for the native app:
  `{"cmd":"pair"}` / `{"cmd":"stop"}` / `{"cmd":"status"}` (JSON per line).
- `NSScreenCapture.m` – `IOMobileFramebuffer` -> `IOSurface` grabbing
  (2 fps status ticks in Phase 3a, full rate + encode in 3b).
- `NSInputInjector.m` – tap/key injection through backboardd.
- `NSPrivate.h` – minimal private-interface declarations (only what we call).

## Server address

Default is a placeholder (`https://nicheshare.example.com`). Point it at the
real signaling server:

```objc
[[NSUserDefaults standardUserDefaults] setObject:@"https://YOUR-server.onrender.com"
                                          forKey:@"NicheShareServer"];
```

(The native app will set this automatically in the next step.)

## Build

Push to `main` – the `tweak.yml` workflow installs Theos on a macOS runner
and uploads the `.deb`. Install it with Sileo, respring, watch
the device log (`oslog -p SpringBoard | grep NicheShare` over SSH).

## Test on Dopamine / iOS 15.8.8 (rootless)

1. `.deb` in Sileo öffnen (oder per Filza installieren), danach Respring.
2. Per SSH verbinden, `oslog -p SpringBoard | grep NicheShare` laufen lassen.
3. NicheShare-App öffnen, Pair drücken: im Log muss `daemon on 127.0.0.1`
   plus der vergebene Code stehen, danach `input ... -> ok` bei Klicks vom PC.
4. Klappt das Pairing, aber Taps kommen nicht an, liegt es an der
   Digitizer-Signatur genau dieses iOS-Builds – dann Log schicken, wird
   nachgezogen.

## Rootless vs rootful

Default is rootless (`/var/jb`, Dopamine/Roothide/palera1n-rootless). For
old rootful jailbreaks build with `THEOS_PACKAGE_SCHEME=rootful`.
