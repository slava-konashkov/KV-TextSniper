# Privacy Policy — KV-TextSniper

_Last updated: 2026-04-24_

KV-TextSniper is a macOS menu-bar utility that captures a user-selected
region of the screen, runs optical character recognition on it, and
places the recognised text on the clipboard.

## What data the app collects

**None.** The app does not collect, store, transmit, sell, or share
any personal information or usage data. There are no accounts, no
analytics, no crash reporters, no advertising identifiers, and no
telemetry of any kind.

## What the app reads locally

To capture a region of the screen, the app uses Apple's
ScreenCaptureKit / `CGWindowListCreateImage` APIs. macOS gates these
behind the **Screen Recording** permission, which you grant explicitly
the first time you capture (or via *System Settings → Privacy &
Security → Screen Recording*).

On capture:

- The pixel data for the selected rectangle is read into memory.
- Apple's on-device **Vision** framework (`VNRecognizeTextRequest`)
  performs OCR locally. Language detection is automatic on
  macOS 13+ with a CJK fallback for older systems.
- The resulting text is written to the system clipboard so you can
  paste it wherever you were working.

This information:

- never leaves your Mac;
- is held in memory only for the duration of the capture; the pixel
  buffer is released as soon as OCR returns;
- is not written to disk (except the clipboard entry, which macOS
  manages like any other copy-paste), not uploaded anywhere, not
  shared with any third party.

## Network activity

The app makes no network connections of its own.

## Children

The app is rated 4+ and contains no user-generated content, ads, or
external links.

## Changes

If this policy ever changes, the updated version will be published
at the same URL.

## Contact

Questions or concerns: open an issue at
<https://github.com/slava-konashkov/KV-TextSniper/issues> or email
`slava@konashkov.com`.
