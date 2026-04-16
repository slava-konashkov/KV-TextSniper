# KV-TextSniper

A menu-bar macOS utility for capturing text from anywhere on the screen via OCR.

Press a global hotkey (default **⌘⇧9**), drag a rectangle over any region of the
screen, and the recognised text is copied to the clipboard. A big rounded
banner at the bottom of the screen confirms success (✅ *Copied to clipboard*)
or reports an error (❌ *Recognition failed*).

OCR is fully on-device via Apple's **Vision** framework and works for many
scripts — Latin, Cyrillic, Chinese (Simplified + Traditional), Japanese,
Korean, Arabic, and more — depending on the macOS version.

## Requirements

- macOS 12.0 (Monterey) or later
- Xcode 15 or later
- An Apple Developer account for code signing / App Store distribution

## Getting started

```bash
open KV-TextSniper.xcodeproj
```

1. In Xcode select the **KV-TextSniper** scheme.
2. Set your development team under *Signing & Capabilities* for the target.
3. Press **▶** (Run).
4. On first run macOS will ask for **Screen Recording** permission — grant it
   in *System Settings → Privacy & Security → Screen Recording* and relaunch.
5. The app lives in the menu bar (📷 viewfinder icon). Hit **⌘⇧9** — or the
   menu item — to start a capture.

## Project layout

```
KV-TextSniper/
├── KVTextSniperApp.swift      – @main entry, creates the Settings scene
├── AppDelegate.swift          – menu-bar item, wires the managers together
├── Info.plist                 – LSUIElement=true (agent-only app), metadata
├── KV-TextSniper.entitlements – App Sandbox (required for Mac App Store)
├── Core/
│   ├── HotkeyManager.swift            – Carbon global hotkey registration
│   ├── ScreenSelectionController.swift – transparent overlay + mouse-drag selection
│   ├── ScreenCaptureManager.swift      – CGWindowListCreateImage capture
│   └── OCRService.swift                – Vision multi-language text recognition
├── Views/
│   ├── BannerWindow.swift     – SwiftUI success/error banner
│   └── SettingsView.swift     – settings window + shortcut recorder
└── Assets.xcassets            – AppIcon + AccentColor
```

## Configurable shortcut

The default is **⌘⇧9**. Change it in the Settings window (menu bar → Settings…
or press **⌘,** while the app is focused). Click the shortcut field, then
press the combination you want — at least one modifier is required.

Shortcuts are stored in `UserDefaults` as `KVTS.shortcut`.

## Preparing for the App Store

1. **Bundle identifier**: edit `PRODUCT_BUNDLE_IDENTIFIER` in *Build Settings*
   (default: `com.viacheslav.KV-TextSniper`). Apple requires it to match the
   identifier registered on *App Store Connect*.
2. **App icon**: drop 16/32/128/256/512-pt @1×/@2× PNGs into
   `KV-TextSniper/Assets.xcassets/AppIcon.appiconset/` and update
   `Contents.json` with filenames. An un-iconned build will succeed with
   warnings, but the App Store requires the full icon set.
3. **Signing**: select your team under *Signing & Capabilities*; Xcode will
   issue a provisioning profile automatically. Keep *App Sandbox* enabled.
4. **Archive**: *Product → Archive* → *Distribute App* → *App Store Connect*.
5. **Screen Recording permission**: the App Store review team will see the
   standard system prompt on first capture. No extra Info.plist key is
   required for `CGWindowListCreateImage`. If you migrate to ScreenCaptureKit
   in the future, the flow is the same.
6. **Privacy**: the app makes no network requests and ships no analytics.
   Declare that honestly in the *App Privacy* questionnaire.

## Debugging

The app emits structured `os.Logger` output under subsystem
`com.viacheslav.KV-TextSniper` with five categories: `app`, `hotkey`,
`selection`, `capture`, `ocr`.

Stream all logs live from a Terminal while the app is running:

```bash
log stream --predicate 'subsystem == "com.viacheslav.KV-TextSniper"' --level debug
```

Or open **Console.app**, hit *Start Streaming*, and enter
`subsystem:com.viacheslav.KV-TextSniper` in the search field.

A healthy capture produces something like:

```
hotkey    pressed ⌘⇧9
app       startCapture: begin
selection begin: 1 overlay window(s)
selection mouseDown at (412,301)
selection mouseUp committing rect=(412.0, 301.0, 280.0, 64.0)
selection finish: cancelled=false rect=... windows=1
app       startCapture: selection finished rect=...
capture   captured 560x128 in 0.014s
ocr       recognize: enter (image 560x128, queue-wait 0.001s)
ocr       recognize: revision=3 languages=14
ocr       recognize: perform done in 0.312s
ocr       recognize: 4 observation(s), 37 char(s)
ocr       recognizeText: 37 chars in 0.314s
```

If `recognize: perform done` takes many seconds on the *first* capture
after a fresh install, that's Vision downloading its CJK/script models
from Apple's servers on demand. Subsequent captures are fast.

## Known limitations / future work

- **ScreenCaptureKit migration**: `CGWindowListCreateImage` is deprecated on
  macOS 15. Vision-based OCR doesn't need pixel-perfect captures, so the
  deprecation is not blocking, but a future version should switch to
  `SCScreenshotManager` (macOS 14+) for forward compatibility.
- **App icon**: the `AppIcon.appiconset` contains the manifest but no PNG
  files. Add them before shipping.
- **Localisation**: UI strings are currently English only. Move them into
  `Localizable.xcstrings` for multi-language support.

## License

MIT — do whatever you want. Attribution appreciated.
