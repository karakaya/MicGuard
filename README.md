# MicGuard

Keeps your audio devices and volume the way you set them. macOS switches to AirPods the moment you put them on, drops audio to the low-bitrate call codec, and conference apps like Zoom / Meet mess with your mic volume via auto gain. MicGuard stops both.

Vibe-coded macOS menu bar app. Swift + SwiftUI, no external dependencies, no network access, no microphone permission required.

![MicGuard menu bar UI](ss1.png)

## Install

```bash
brew install --cask milan0x/tap/micguard
```

No separate `brew tap` step needed, the command adds the tap automatically. Homebrew installs the same Apple-notarized DMG that ships on [Releases](../../releases), so it opens without Gatekeeper warnings.

Or download the notarized build from [Releases](../../releases) yourself, open the DMG, drag to Applications.

Or build it from source:

```bash
swift build
# or open the package in Xcode
```

## What it does

**Devices** — pin your input and output device, or let MicGuard pick the top connected device from a priority list. macOS won't be able to silently switch you away. When a higher-priority device plugs in, MicGuard can auto-switch to it (opt-in).

**Volume** — three strategies for input volume:
- *None* — don't manage
- *Lock volume* — continuous protection, snap back to target whenever something nudges it
- *Reset when mic stops* — restore your target after each meeting ends *(default)*

**Per-device output levels** — set a one-time default volume that applies whenever a specific output device becomes active. Useful when your monitor speakers are wildly louder than your headphones.

**Mic-in-use indicator** — when any mic is hot, the menu bar mic icon switches to a colored pill (orange pill matches macOS native, red pill for higher visibility, or off if you trust macOS's own orange dot).

**Prevention flashes** — when MicGuard reverts a hijack, the menu bar briefly flashes `INPUT HELD` or `OUTPUT HELD` so you know it acted on your behalf.

## Privacy

Nothing leaves your machine. No analytics, no mic access — MicGuard uses CoreAudio device metadata only, so macOS never prompts for microphone permission.

## Requirements

macOS 13 Ventura or later.

## License

Personal use only. You can use it and modify it for yourself but you can't redistribute it. See [LICENSE](LICENSE).
