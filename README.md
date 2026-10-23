# HDMI Capture

Kleine macOS-App für USB-HDMI-Capture-Sticks mit MacroSilicon-MS2109-Chip.

- Live-Bild in 1920×1080 mit 30 fps (wählt den MJPEG-Modus der Karte statt des 5-fps-Standardmodus)
- Echter Stereoton: Der Chip meldet 96 kHz mono, liefert aber 48 kHz stereo – die App deutet das richtig
- Aufnahme als MP4 (H.264 per Hardware, AAC-Stereo) nach `~/Movies/HDMI Capture/`
- L/R-Tausch, Lautstärke, Pegelanzeige, Vollbild, „Immer im Vordergrund“

## Bauen

```bash
./build.sh
open "build/HDMI Capture.app"
```

Beim ersten Start fragt macOS nach Kamera- und Mikrofonzugriff. Weil die App nur lokal signiert ist,
kann die Abfrage nach jedem Neubau wiederkommen.

Zum Fehlersuchen die App direkt aus dem Terminal starten – sie schreibt dann alle 10 Sekunden
Bildrate, Tonformat und Puffer ins Terminal:

```bash
"build/HDMI Capture.app/Contents/MacOS/HDMICapture"
```

## Tastenkürzel

| Kürzel | Funktion |
|---|---|
| ⌘R | Aufnahme starten / beenden |
| ⌘L | Links/Rechts tauschen |
| ⌘↑ / ⌘↓ | Lauter / leiser |
| ⌃⌘F, Doppelklick | Vollbild |
| Esc | Vollbild beenden |
| ⌘T | Immer im Vordergrund |
