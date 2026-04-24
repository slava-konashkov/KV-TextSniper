# KV-TextSniper

Menu-bar OCR for macOS. Press a hotkey, drag a region, get the text in your clipboard.

> **Status:** v1.0.0 signed + notarised release coming soon. When it's out, a one-click DMG download will appear here.

## What it does

- Lives in the menu bar — no Dock icon.
- Global hotkey brings up a crosshair; drag any region of the screen.
- OCR runs locally on-device via Vision framework; no network calls, no accounts.
- Auto-detects language (macOS 13+), with CJK fallback on older systems.
- Result lands on the clipboard and the app gets out of the way.

## Install (once the DMG lands)

Download [KV-TextSniper.dmg](https://slava-konashkov.github.io/KV-TextSniper/KV-TextSniper.dmg), drag into `/Applications`, launch. Grant **Screen Recording** permission in *System Settings → Privacy & Security* (required for OCR to see the actual screen, not just the wallpaper). Set your preferred hotkey in **Settings…** from the menu-bar menu.

## Requirements

- macOS 13 Ventura or later
- Apple Silicon or Intel (universal binary)

---

*Sources live in a separate private repo. This public repo only carries the README + DMG so there's a stable download URL. See all KV-* apps at [github.com/slava-konashkov](https://github.com/slava-konashkov).*
