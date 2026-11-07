# Snapix

A macOS screenshot, annotation and OCR tool, written from scratch in Swift (AppKit + SwiftUI, ScreenCaptureKit, Vision).

## Build & run

    ./build.sh              # -> build/Snapix.app (ad-hoc signed)
    ./install.sh            # build, quit the running copy, install into /Applications and relaunch (--no-launch to skip)
    open build/Snapix.app
    .build/debug/Snapix --selftest /some/dir   # non-interactive checks (stitching, render, contrast, formats)

First launch: grant **Screen Recording** (and **Accessibility** for automatic scrolling capture) in System Settings.
Ad-hoc signatures change on every rebuild, so macOS may ask again after rebuilding.

## Features

Capture (menu bar icon + global hotkeys, rebindable in Preferences › Shortcuts)
- Area (frozen screen, pixel loupe, live W×H), fullscreen, any window (hover to pick), active window, 3 s delayed, repeat last area
- Scrolling capture: automatic down or up (synthetic scroll + frame stitching) and manual (scroll either way, press Done)
- Optional adjustable selection: handles, move by dragging or holding Space, arrow-key nudge, Return / double-click to capture
- Open image from clipboard / file

Editor
- Tools (single-key shortcuts): select V, arrow A (3 styles), rectangle R, oval O, line L, freehand P, text T (optional background),
  highlighter H, blur/erase B (pixelate, gaussian, erase), spotlight S, counter C, ruler M, magnifier G, image overlay I, crop X
- Select/move/resize shapes, Delete, arrow-key nudge, Shift to constrain, unlimited undo/redo, zoom/pinch, colour under cursor
- Backdrop (K): padding, inner/outer radius, shadow, gradient or solid, angle, presets, randomize
- Edge snapping for boxes/crop (hold ⌥ to bypass) and "Snap to Similar Region" (right-click a shape)
- Resize image, crop (Return to apply) with Uncrop, merge annotations into the image, print, drag the result out of the editor into other apps
- Image overlay: lay a clipboard image over the screenshot, drag to align, slider sets opacity
- Library: every capture is kept (Application Support/Snapix/History, last 200) and can be reopened, copied, pinned or deleted

Analysis
- OCR + QR/barcode (Vision) from a drag area or the editor; optional "remove line breaks"
- Colour picker with HEX / RGB / CSS / HSL / Swift / C# output
- Contrast checker: WCAG ratio + APCA Lc (pick two colours, or analyse a region in the editor)

Output
- Copy, save (PNG / JPEG / automatic by content), save as, downscale Retina, filename template, upload to your own HTTP endpoint
- Pin to screen (drag, scroll to resize, ⌥-scroll for opacity, double-click to edit, right-click menu)
- After-capture actions and Esc-to-copy/save, launch at login

URL scheme: `snapix://area`, `fullscreen`, `window`, `active-window`, `delayed`, `repeat`, `scrolling`, `scrolling-up`, `scrolling-manual`, `library`, `ocr`, `pick-color`, `contrast`, `clipboard`
with an optional `?then=copy,save,edit,pin`.

UI languages: English and French (Resources/fr.lproj; follows the macOS language).

## Releasing

Versions and `CHANGELOG.md` are generated from [Conventional Commit](https://www.conventionalcommits.org) messages by `scripts/release.py`; pushing a `v*` tag publishes a universal build as a GitHub release. `scripts/ci.sh` runs the same checks as CI. See [docs/RELEASING.md](docs/RELEASING.md).
