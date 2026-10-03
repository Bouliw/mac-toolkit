# finetune-patch

[FineTune](https://github.com/ronitsingh10/FineTune) is a very good per-app volume mixer for macOS. It also manages the default audio devices on its own: it keeps a priority list, reverts macOS when a new output connects, and picks the fallback when one disconnects. I wanted macOS, and my own headset and mic setup, to stay in charge of devices, and FineTune to do per-app volume only.

`build.sh` rebuilds FineTune 1.9.0 that way and installs it in `/Applications`:

- `patch.py` removes the priority and override logic when a device connects or disconnects, for outputs and inputs. Apps that follow the system default keep following it.
- Sparkle is stubbed out, so this build never updates itself.
- No Xcode needed: it builds with Swift Package Manager and the Command Line Tools. `no_previews.py` disables the SwiftUI `#Preview` blocks, whose macro only ships with Xcode.
- The compiled assets (icons, accent colour) come from the official release DMG.

The app is ad-hoc signed, so macOS asks again for the audio capture and Bluetooth permissions after each build. The previous version is kept in `~/Library/Application Support/mac-toolkit/finetune`.

FineTune is © Ronit Singh, licensed under GPL-3.0. The files in this folder are released under the same licence (see `LICENSE`).
