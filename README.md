<p align="center">
  <img src="docs/fire-icon.png" width="160" alt="Fire app icon">
</p>

<h1 align="center">Fire</h1>

<p align="center">
  A menu bar manager for macOS that works on <strong>macOS 27</strong>.<br>
  Hide the menu bar items you don't need and bring them back with one click.
</p>

---

Fire is a fork of [**Ice**](https://github.com/jordanbaird/Ice) by Jordan Baird, rebuilt so that it
works on macOS 27, where the original no longer can.

> **Why a fork?** In macOS 27, menu bar items are no longer windows that other apps can see or
> move. They are hosted by a new system process (`MenuBarAgent`). Ice relies on exactly those
> windows, so on macOS 27 its menu bar layout is empty and hiding does nothing. Fire replaces that
> part, and keeps the rest of Ice.

## Features

- Hide menu bar items behind the Fire icon and show them again with a click
- Rearrange items with **⌘ + drag** (a macOS feature, nothing to learn)
- Show hidden items on click, hover or scroll (inherited from Ice)
- Menu bar appearance (tint, border, shadow, shape) (inherited from Ice)
- Hotkeys, launch at login, automatic re-hide (inherited from Ice)

## How it works on macOS 27

Fire cannot push other apps' items out of the menu bar anymore, and the system does not allow a
third-party app to tell `MenuBarAgent` to hide an item. So Fire hides items **visually**:

1. It finds all menu bar items through the macOS **Accessibility** API (`AXExtrasMenuBar`).
2. Everything to the **left of the Fire icon** is considered hidden.
3. Fire covers that area with small panels that reproduce the menu bar background, captured with
   **ScreenCaptureKit**. Clicks on the covered area are absorbed.

Clicking the Fire icon removes the cover, clicking it again puts it back.

### Using it

- Hold **⌘** and drag items to the left of the Fire icon to hide them, or to its right to keep them
  visible.
- Drag the **Fire icon** itself to change where the boundary is.
- Click the Fire icon to show or hide the items.

### Limitations

- The items still exist, they are only covered. Apps that read the menu bar (for example
  screenshot tools) can still see them.
- The *Menu Bar Layout* view in the settings stays empty on macOS 27. Arrange items with ⌘ + drag.
- When an app starts or quits, the cover is updated within about a second.
- Fire relies on private behaviour of macOS and may need updates with future macOS releases.

## Requirements

- macOS 14 or later (developed and tested on **macOS 27.0**, Apple silicon)
- Permissions: **Accessibility** and **Screen & System Audio Recording**
  (Fire asks for them on first launch)

## Install

### Download

Download `Fire.zip` from the [latest release](https://github.com/tr1k25/Fire/releases/latest),
unzip it and move `Fire.app` to your Applications folder.

The app is signed ad hoc and not notarized, so macOS blocks the first launch. Open it with
right-click → **Open**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/Fire.app
```

### Build from source

You need Xcode 27 (or a version with the macOS 27 SDK).

```bash
git clone https://github.com/tr1k25/Fire.git
cd Fire
./build.sh --install        # builds and installs to ~/Applications/Fire.app
```

`./build.sh --universal` builds for Apple silicon and Intel.

> Because the app is signed ad hoc, macOS treats every new build as a new app and asks for the
> Accessibility and Screen Recording permissions again. Create a self-signed code signing
> certificate and sign the build with it to avoid that.

## What changed compared to Ice

- New `HiddenItemCover` that finds items through Accessibility and covers hidden ones
- Hit-testing for "click on an empty menu bar area" uses Accessibility instead of window lists
- Fixed a busy loop in the run loop event monitor that made the settings window unresponsive
- Replaced the Sparkle updater with a lightweight check against GitHub releases
- Bundled CompactSlider with a fix for the macOS 27 SDK
- New name, icon and menu bar icon

## License and credits

Fire is licensed under the **GNU General Public License v3.0**, like Ice. See [LICENSE](LICENSE).

- **Ice** — Copyright © Jordan Baird, GPL-3.0 — https://github.com/jordanbaird/Ice
- **CompactSlider** — Copyright © Alexey Bukhtin, MIT — https://github.com/buh/CompactSlider
- **AXSwift**, **Ifrit**, **LaunchAtLogin-Modern** — see their repositories for licenses

Fire is not affiliated with or endorsed by the Ice project.

---

## Auf Deutsch

**Fire** ist ein Menüleisten-Manager für macOS, der auf **macOS 27** funktioniert. Es basiert auf
[Ice](https://github.com/jordanbaird/Ice), das dort nicht mehr läuft, weil macOS 27 die
Menüleisten-Symbole nicht mehr als Fenster bereitstellt.

Fire findet die Symbole über die Bedienungshilfen, überdeckt alles links vom Fire-Symbol mit dem
nachgebildeten Menüleisten-Hintergrund und blendet es per Klick wieder ein. Symbole ordnest du mit
**⌘ + Ziehen** an. Dafür braucht Fire die Rechte *Bedienungshilfen* und *Bildschirmaufnahme*.

Bauen: `./build.sh --install`. Lizenz: GPL-3.0.
