# mac-toolkit

[![Tests](https://github.com/Bouliw/mac-toolkit/actions/workflows/tests.yml/badge.svg)](https://github.com/Bouliw/mac-toolkit/actions/workflows/tests.yml)

Small tools I use every day on my Mac. Most run quietly in the background; the others live in the Finder's right-click menu or in Safari's Share menu.

| Tool | What it does |
|---|---|
| **HeadsetGuard** | Keeps a Bluetooth headset's audio stream awake so the start of short sounds (Discord notifications) is no longer cut off, and stops macOS from switching the input to the headset's mic when it connects. Picking that mic by hand still works. |
| **CleanLinks** | Strips tracking parameters from links as soon as they are copied: `utm_*`, `fbclid`, YouTube and Spotify `?si=`, Amazon `ref`, LinkedIn `trk`… Leaves passwords and plain text alone. |
| **FPS counter** | Turns on Apple's Metal performance HUD in games, reduced to a small FPS counter in the top-right corner. |
| **Finder quick actions** | *Transcribe*: local transcription with whisper.cpp (`.txt` + `.srt`). *Compress for Discord*: two-pass H.264 under the 10 MB upload limit, HDR tone-mapped. *Shrink PDF*: Ghostscript. *Strip Metadata*: photos, videos, PDF and Office files. |
| **Download Video** | Share menu action: downloads a video with yt-dlp in the best quality. VP9/AV1 files are converted to HEVC on the media engine so QuickTime and Final Cut can open them. yt-dlp is updated daily. |
| **Send to TV** | Share menu action: sends the YouTube video open in Safari, at the current timestamp, or a Twitch channel to an LG webOS TV. Pauses Safari and wakes the TV with Wake-on-LAN. |
| **Auto PiP** | Safari userscript: the playing video goes picture-in-picture when you switch tabs or desktops and comes back when you return. Full screen is left alone. |
| **WallperSync** | Keeps the system wallpaper (lock screen, Mission Control, desktop swipes) in sync with the live wallpaper set in Wallper. With Wallper's lock screen option on (macOS 26+), the lock screen stays animated; otherwise a still frame of the video is used. |
| **finetune-patch** | Build script for FineTune with its audio device management removed. See [finetune-patch](finetune-patch). |

## Requirements

- Apple silicon Mac, macOS 15 or later (used daily on macOS 26)
- Command Line Tools (`xcode-select --install`) for the Swift tools
- [Homebrew](https://brew.sh) for the Finder actions and the downloader; `install.sh` installs the formulae it needs
- *Send to TV*: an LG TV in developer mode, set up with [ares-cli](https://github.com/webos-tools/cli) (`ares-setup-device`, then `ares-novacom --getkey`); `install.sh` reuses that key and the action talks to the TV over SSH with macOS's own `ssh`, which Shortcuts is allowed to use on the local network. By default it opens the YouTube and Twitch apps from the webOS Homebrew Channel; app IDs can be changed in the config (the Twitch app has to read a `channel` launch parameter, which webOS hands over as a JSON string). To let it turn the TV on, enable *TV On With Mobile › Turn on via Wi-Fi* in the TV settings
- *Auto PiP*: the [Userscripts](https://github.com/quoid/userscripts) Safari extension
- *WallperSync*: the Wallper app

## Install

```sh
git clone https://github.com/Bouliw/mac-toolkit.git
cd mac-toolkit
./install.sh                 # everything available on this Mac
./install.sh clean-links     # or only some tools
./install.sh --list          # list of tools
```

Tools go to `~/Library/Scripts/mac-toolkit`, background services to `~/Library/LaunchAgents` (`local.mac-toolkit.*`), logs to `~/Library/Logs/mac-toolkit` and settings to `~/.config/mac-toolkit/config`. Running the script again updates everything in place.

The two Share menu actions are shortcuts: click *Add Shortcut* when the window opens, and turn on *Allow Running Scripts* in Shortcuts › Settings › Advanced. In Safari they are under Share › Shortcuts.

FineTune is only built on request: `./install.sh finetune-patch`.

## Uninstall

```sh
./uninstall.sh         # keeps ~/.config/mac-toolkit
./uninstall.sh --all   # removes settings and logs too
```

## License

MIT, except `finetune-patch/`, which is GPL-3.0 like FineTune.
