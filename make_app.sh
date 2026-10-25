#!/bin/sh
# Збирає "ArduTune.app" з двигуном всередині.
export PATH="$HOME/.dotnet:$PATH" DOTNET_CLI_TELEMETRY_OPTOUT=1
cd "$(dirname "$0")"
VERSION=$(tr -d ' \n' < VERSION)                          # єдине джерело номера версії (файл VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)   # номер збірки = кількість комітів
dotnet publish Engine -c Release -r osx-arm64 --self-contained true -o build/engine -v q || exit 1
(cd MacApp && swift build -c release) || exit 1
APP="build/ArduTune.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Engine"
cp MacApp/.build/release/ArduTune "$APP/Contents/MacOS/"
cp -R build/engine/ "$APP/Contents/Resources/Engine/"
cp LICENSE "$APP/Contents/Resources/COPYING.txt"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R MacApp/Resources/en.lproj MacApp/Resources/uk.lproj MacApp/Resources/osdfonts "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>uk</string>
<key>CFBundleLocalizations</key><array><string>uk</string><string>en</string></array>
<key>CFBundleName</key><string>ArduTune</string>
<key>CFBundleIdentifier</key><string>com.keshkovsky.ardutune</string>
<key>CFBundleExecutable</key><string>ArduTune</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>NSHumanReadableCopyright</key><string>© 2026 keshkovsky. GNU GPL v3.</string>
<key>NSLocationWhenInUseUsageDescription</key><string>ArduTune використовує положення Mac як позицію станції для наведення антени.</string>
<key>NSCameraUsageDescription</key><string>ArduTune показує відео з камери для польотів.</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force --deep --sign - "$APP" 2>&1 | tail -1
echo "Готово: $APP (версія $VERSION, збірка $BUILD)"
