## Installation

1. Download the ZIP file below and unzip it.
2. Move **HDMI Capture** to your Applications folder.
3. Open it. The first time, macOS blocks the app because it is not notarized by Apple:
   go to **System Settings → Privacy & Security** and click **Open Anyway**.
   Alternatively, run this once in Terminal:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/HDMI Capture.app"
   ```
4. Allow camera and microphone access when asked.

**Requirements:** macOS 14 Sonoma or newer, Apple Silicon or Intel, a USB HDMI capture stick with the
MacroSilicon MS2109 chip. No other software (ffmpeg, SoX …) is needed.
