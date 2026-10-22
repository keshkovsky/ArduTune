# ArduTune

A native macOS configurator and ground control station for ArduPilot, written in Swift/SwiftUI for Apple Silicon. Feature reference: Mission Planner. Mac only; stability is preferred over universality.

> **Status: early development (v0.6).** Many features are not verified on real hardware or in flight. Do not rely on it for flight-critical operations, and test without propellers.

## Download

Get the latest build from [Releases](https://github.com/keshkovsky/ArduTune/releases): unzip `ArduTune-*-macOS-arm64.zip` and move `ArduTune.app` to Applications.
Requires macOS 15+ on Apple Silicon. The app is ad-hoc signed and not notarized, so on first launch right-click it, choose **Open**, then **Open** again (or allow it in System Settings → Privacy & Security).
Optional: install GStreamer.framework for RTSP/GStreamer video.

## Features

- **Flight Data**: HUD (several themes), live map with track, POIs and rulers, MAVLink inspector, video (camera or GStreamer), joystick control, tlog recording and playback.
- **Mission planning**: waypoints, geofence, rally points, survey grids, KML/.waypoints import and export, terrain-aware altitude profile, flight simulation, 3D terrain view.
- **Setup**: parameters (search, compare, offline view of .param files), accelerometer/compass/radio calibration, flight modes, failsafe, frame and motors, servo output, ESC, serial ports, battery monitor, GPS, DroneCAN, special configurations and Quick tune.
- **PID and filters**: tuning page with presets, history and rollback, plus an interactive PID trainer.
- **Logs**: download Dataflash logs over MAVFTP, graphs, map, messages, an assistant with PID/filter advice, PID Review (step response) and Filter Review (spectra), and built-in lessons.
- **Firmware**: install from the official ArduPilot catalog via bootloader (APJ) or DFU (HEX), with a parameter backup before flashing.
- **Hardware pages**: OSD layout editor, VTX, rangefinder, gimbal, ADS-B, Lua scripts on the SD card, MAVFtp browser.
- **Interface**: English and Ukrainian (follows the macOS language), light/dark themes, metric/imperial units, optional voice alerts.

## Architecture

- `MacApp/`: SwiftUI app (macOS 15+).
- `Engine/`: a local C# (.NET 8) process that talks MAVLink to the flight controller and exposes a token-protected HTTP/WebSocket API on `127.0.0.1`. It is kept separate so it can later be reused for Windows and Linux ports.
- `ExtLibs/Mavlink`: MAVLink library by Michael Oborne (from the Mission Planner project).

## Build from source

Requires the .NET 8 SDK and the Swift toolchain (Command Line Tools).

```sh
./make_app.sh
open build/ArduTune.app
```

## Your data stays on your Mac

Logs, firmware, parameter backups, map cache and missions are stored in `~/Library/Application Support/ArduTune/`, outside the app bundle. The app does not collect or send usage data.

## License and credits

GNU GPL v3, see [LICENSE](LICENSE). Developed by keshkovsky.
Thanks to Michael Oborne (MAVLink library, Mission Planner) and the ArduPilot Dev Team (protocol, parameter metadata, motor layouts, sensor tables). Video uses GStreamer (LGPL, installed separately). See [NOTICE.md](NOTICE.md).
