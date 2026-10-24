# HDMI Capture

A small macOS app for USB HDMI capture sticks based on the MacroSilicon MS2109 chip.

- Live picture at 1920×1080 and 30 fps (uses the card's MJPEG mode instead of the 5 fps default mode)
- True stereo audio: the chip reports 96 kHz mono but actually delivers 48 kHz stereo, and the app interprets it correctly
- Recording to MP4 (hardware H.264, AAC stereo) in `~/Movies/HDMI Capture/`
- Screenshots of the current frame at full resolution, saved as PNG to `~/Pictures/HDMI Capture/` or copied to the clipboard
- Streaming to your local network (e.g. to VLC on an iPad) as MPEG-TS over HTTP, MPEG-DASH and RTSP
- Swap left/right channels, volume control, level meter, full screen, "Always on top"

## Streaming

Click **Stream** in the control bar (or press ⌘K). The addresses appear in the top-left corner of the window:

| Format | Address | Notes |
|---|---|---|
| MPEG-TS over HTTP | `http://<mac-ip>:8080/live.ts` | Shortest delay (about 1–2 s in VLC) |
| MPEG-DASH | `http://<mac-ip>:8080/dash/live.mpd` | 2 s segments; players add a larger buffer |
| RTSP | `rtsp://<mac-ip>:8554/live` | RTP over TCP (interleaved); UDP is refused, VLC and ffmpeg switch automatically |

In VLC (iPad, iPhone, Mac): **Network → Open Network Stream** and enter one of the addresses.
`http://<mac-ip>:8080/` shows a small page with all addresses and "Open in VLC" links.
The stream uses H.264 (about 6 Mbit/s for 1080p30) and AAC stereo. The status shows `LIVE` and the number of viewers.

macOS may ask whether HDMI Capture may accept incoming network connections or access the local network; allow it.

## Download

Get the latest version from [Releases](https://github.com/removogel/HDMI-Capture/releases/latest).
It runs on macOS 14 or newer, on Apple Silicon and Intel Macs. No other software (ffmpeg, SoX …) is needed.

The app is not notarized by Apple, so macOS blocks it the first time you open it. Go to
**System Settings → Privacy & Security** and click **Open Anyway**, or run:

```bash
xattr -dr com.apple.quarantine "/Applications/HDMI Capture.app"
```

## Building

Requires the Xcode Command Line Tools.

```bash
./build.sh
open "build/HDMI Capture.app"
```

`build.sh` produces a universal app (arm64 + x86_64). On first launch, macOS asks for camera and microphone
access. Because the app is only signed locally (ad hoc), the prompt may come back after each rebuild.

For troubleshooting, start the app directly from Terminal. It then prints the frame rate, audio format and
buffer level to the terminal every 10 seconds:

```bash
"build/HDMI Capture.app/Contents/MacOS/HDMICapture"
```

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘R | Start / stop recording |
| ⌘S | Save screenshot |
| ⌘C | Copy current frame to the clipboard |
| ⌘K | Start / stop streaming |
| ⌘L | Swap left/right channels |
| ⌘↑ / ⌘↓ | Volume up / down |
| ⌃⌘F, double-click | Full screen |
| Esc | Exit full screen |
| ⌘T | Always on top |

The app's user interface is in German.
