# HDMI Capture

A small macOS app for USB HDMI capture sticks based on the MacroSilicon MS2109 chip.

- Live picture at 1920×1080 and 30 fps (uses the card's MJPEG mode instead of the 5 fps default mode)
- True stereo audio: the chip reports 96 kHz mono but actually delivers 48 kHz stereo, and the app interprets it correctly
- Recording to MP4 (hardware H.264, AAC stereo) in `~/Movies/HDMI Capture/`
- Screenshots of the current frame at full resolution, saved as PNG to `~/Pictures/HDMI Capture/` or copied to the clipboard
- Swap left/right channels, volume control, level meter, full screen, "Always on top"

## Building

```bash
./build.sh
open "build/HDMI Capture.app"
```

On first launch, macOS asks for camera and microphone access. Because the app is only signed locally (ad hoc),
the prompt may come back after each rebuild.

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
| ⌘L | Swap left/right channels |
| ⌘↑ / ⌘↓ | Volume up / down |
| ⌃⌘F, double-click | Full screen |
| Esc | Exit full screen |
| ⌘T | Always on top |

The app's user interface is in German.
