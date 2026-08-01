# screenlink

Lets a browser see and control this Mac. A native Swift app captures the screen with
ScreenCaptureKit, encodes it on the hardware H.264 engine, and streams it to a local web page over
a WebSocket. The page sends mouse and keyboard events back, which are injected as real system events.

Two consumers on one core:

- **Human** — low-latency H.264 video stream decoded in the browser with WebCodecs.
- **Agent** — `GET /screenshot` for a JPEG and `POST /command` for input, no video pipeline involved.

## Requirements

- Apple Silicon Mac, macOS 14+
- Swift 6 toolchain (Xcode Command Line Tools is enough; full Xcode is not needed)
- A WebCodecs browser: Chrome, Edge, or Safari 16.4+

## Quick start

```bash
scripts/setup-signing.sh   # once, so permissions survive rebuilds
scripts/build.sh           # compile, assemble screenlink.app, sign
scripts/run.sh             # launch and print the URL
```

Grant Screen Recording and Accessibility when prompted. With the signing identity in place you only
have to do that once, no matter how many times you rebuild.

The first run will be denied both permissions and will tell you so. Grant them, then rerun:

- **Screen & System Audio Recording** — required. Without it there is no capture.
- **Accessibility** — required for input injection. Capture works without it; control does not.

Both live in System Settings > Privacy & Security. macOS requires a relaunch after granting, which
`scripts/run.sh` handles by restarting the app each time.

Open the printed URL, then click **Enable control** to start forwarding input.

```bash
node scripts/smoke.mjs   # end-to-end protocol check
scripts/stop.sh
```

## Measured

On an M-series Mac capturing a 3440×1440 display downscaled to 1920×804:

- **8.4 ms** average capture-to-client, 9.7 ms p95, 5.5 ms best case
- **55–57 fps** sustained against a 60 fps target
- 0.2–1.8 Mb/s on typical desktop content, since unchanged frames are never encoded

Those figures cover capture, hardware encode, and loopback transport. Browser decode and
compositing add roughly 10–25 ms on top, so glass-to-glass lands in the 25–40 ms range.

## Troubleshooting

**`SCStreamErrorDomain Code=-3801 "The user declined TCCs"`** while the toggle already looks
enabled in System Settings. This is the ad-hoc signing trap, and `scripts/setup-signing.sh` exists
to prevent it.

An ad-hoc signature carries no certificate, so TCC has nothing stable to identify the app by and
falls back to pinning the binary's cdhash. Every rebuild changes that hash, so **macOS treats each
build as a different app**. The old row stays in the list, still switched on, but it no longer
matches the binary you are running.

`scripts/setup-signing.sh` generates a self-signed code signing certificate in a dedicated keychain
and `scripts/build.sh` uses it automatically. That changes the designated requirement from a cdhash
pin to:

```
identifier "com.screenlink.app" and certificate leaf = H"<cert hash>"
```

Nothing in that depends on the binary's contents, so the grant holds across rebuilds. The
certificate is deliberately left untrusted, which is why no admin password is needed: trust settings
govern signature *verification*, while `codesign` and TCC only need the requirement to match.

If you hit -3801 on an app that was previously ad-hoc signed, the stale cdhash-pinned grant has to
be cleared once before the certificate-based one can take its place:

```bash
scripts/stop.sh
tccutil reset ScreenCapture com.screenlink.app
tccutil reset Accessibility com.screenlink.app
scripts/run.sh
```

Then enable screenlink in both privacy panes. Capture is retried every 5 seconds, so it starts as
soon as you flip the switch — no relaunch needed. Expect to repeat this after any `scripts/build.sh`.

**`/health` shows `capturing: true` but capture seems off.** Trust `capturing`. It reflects whether
`SCShareableContent` actually succeeded. `CGPreflightScreenCaptureAccess` predates ScreenCaptureKit
and keeps reporting false long after capture is working, which is why nothing in this app gates on it.

## Why it is fast

The pixels never pass through application code. ScreenCaptureKit produces NV12 IOSurfaces, which is
exactly the format the hardware encoder consumes, so frames go from the display engine to the media
engine without a CPU copy or a pixel format conversion. The CPU only moves handles and shuffles a
few tens of kilobytes of compressed bitstream per frame.

The choices that actually matter for latency here, in rough order:

- **Capture and encode run at `.userInteractive` QoS.** On Apple Silicon, threads at `utility` or
  `background` QoS are confined to efficiency cores. There is no working thread-affinity API, so QoS
  is the only way to ask for performance cores.
- **B-frames are disabled** and low-latency rate control is on. Frame reordering would buy
  compression at the cost of a frame of delay.
- **Idle frames are dropped.** ScreenCaptureKit reports `.idle`/`.blank` when nothing changed;
  encoding those wastes bitrate redrawing an identical screen.
- **Frames are dropped rather than queued** when a client's socket is backed up. A queue converts a
  bandwidth problem into an unbounded latency problem.
- **The browser draws from the decoder callback**, not from `requestAnimationFrame`, which avoids
  adding a display refresh interval.

The language is close to irrelevant to throughput here, which is why this is Swift: every expensive
step is a dedicated hardware block, and Swift is the shortest path to the frameworks that drive them.

## HTTP API

All routes except `/` and `/health` require `?token=<token>`, which `scripts/run.sh` writes to
`build/token`.

| Route | Description |
| --- | --- |
| `GET /` | The viewer page, with the token injected |
| `GET /health` | Capture state and permission status |
| `GET /screenshot` | Single JPEG frame via `SCScreenshotManager` |
| `POST /command` | Inject one input command |

```bash
TOKEN=$(cat build/token)
curl -s "http://127.0.0.1:8766/screenshot?token=$TOKEN" -o shot.jpg
curl -s -X POST "http://127.0.0.1:8766/command?token=$TOKEN" \
  -d '{"type":"mouse","action":"move","x":0.5,"y":0.5}'
```

## Input protocol

Pointer coordinates are normalized to `[0,1]` over the captured display. The server maps them
through `CGDisplayBounds`, so Retina backing scale and multi-display arrangement never enter the
client's model.

```jsonc
{"type":"mouse",  "action":"move|down|up", "x":0.5, "y":0.5, "button":"left|right|middle"}
{"type":"scroll", "x":0.5, "y":0.5, "dx":0, "dy":-120}
{"type":"key",    "action":"down|up", "code":"KeyA", "meta":true}
{"type":"text",   "text":"hello"}
{"type":"keyframe"}
```

Printable characters go through `text`, which injects Unicode directly and therefore works for any
character and any keyboard layout without a reverse keycode lookup. Everything else goes through
`key` with a `KeyboardEvent.code` that maps to a macOS virtual keycode.

## Options

```
--http-port N     default 8766
--ws-port N       default 8765
--fps N           default 60
--max-width N     default 1920 (capture is downscaled to fit)
--bitrate N       default 12000000
--no-input        serve video but ignore all input commands
--token S         shared secret
--client PATH     serve the viewer from this file instead of the bundle copy
--log PATH        also write logs here
```

## Security

This app can see and control everything on the machine, so treat it accordingly.

- Both listeners bind to `127.0.0.1` only and are never exposed to the network.
- Every privileged route requires the shared token; the WebSocket drops clients that fail auth.
- `--no-input` gives a read-only stream.
- The browser client starts read-only and requires an explicit click to enable control.
- macOS shows its own screen-recording indicator in the menu bar whenever capture is live. That
  indicator is drawn by the system and this app cannot suppress or fake it.

Two limits worth knowing: input cannot be injected into secure input contexts, so password fields
and the login window will ignore it; and this design could never ship on the Mac App Store, since
Accessibility-based input injection for remote control is not permitted there.

### Before exposing this beyond localhost

The current token check is adequate for a loopback tool and nothing more. Going further needs, at
minimum, TLS, an origin allowlist, per-session consent that a web page cannot fabricate, and a
session timeout. At that point WebRTC is the better transport anyway: it brings congestion control,
retransmission, and NAT traversal, none of which a raw WebSocket gives you.

## Development

`scripts/run.sh` points the server at `Client/index.html` on disk, so the viewer can be edited and
reloaded without rebuilding or even restarting the app.

```
Sources/screenlink/
  main.swift            entry point and permission preflight
  App.swift             wiring, HTTP routes, agent endpoints
  ScreenCapturer.swift  SCStream -> NV12 IOSurface
  H264Encoder.swift     VideoToolbox, AVCC -> Annex B, codec string from SPS
  InputInjector.swift   CGEvent injection, coordinate mapping, drag and click state
  KeyMap.swift          KeyboardEvent.code -> macOS virtual keycodes
  WebSocketServer.swift video out, input in
  HTTPServer.swift      minimal HTTP/1.1 over Network.framework
Client/index.html       WebCodecs viewer
```
