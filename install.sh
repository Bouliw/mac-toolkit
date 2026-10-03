#!/bin/zsh
# mac-toolkit: installs the tools into ~/Library/Scripts/mac-toolkit and starts their services.
#   ./install.sh                  everything available on this Mac (except finetune-patch)
#   ./install.sh tool [tool…]     only these tools
#   ./install.sh --list           list of tools
setopt null_glob
HERE="${0:A:h}"
BASE="$HOME/Library/Scripts/mac-toolkit"
AGENTS="$HOME/Library/LaunchAgents"
PREFIX="${MACTOOLKIT_PREFIX:-local.mac-toolkit}"
CONFIG="$HOME/.config/mac-toolkit/config"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

typeset -A DESCRIPTION
DESCRIPTION=(
  headset-guard   "Bluetooth headset: no more clipped sounds, its mic is never picked automatically"
  clean-links     "strips tracking parameters (utm, fbclid, ?si=…) from copied links"
  fps-counter     "Metal FPS counter in games"
  quick-actions   "Finder: Transcribe, Compress for Discord, Shrink PDF, Strip Metadata"
  download-video  "Share menu: Download Video (yt-dlp, updated daily)"
  send-to-tv      "Share menu: send a YouTube video or a Twitch channel to an LG TV"
  auto-pip        "Safari: automatic picture-in-picture when you switch tabs"
  wallper-sync    "system wallpaper kept in sync with Wallper"
  finetune-patch  "FineTune rebuilt: per-app volume, audio devices left to macOS"
)
DEFAULT_TOOLS=(headset-guard clean-links fps-counter quick-actions download-video send-to-tv auto-pip wallper-sync)

title() { print -P "\n%B$1%b"; }
ok()    { print -r -- "  ✓ $1"; }
note()  { print -r -- "  · $1"; }
skip()  { print -r -- "  – skipped: $1"; }

# ---------- helpers ----------

set_config() {  # set_config KEY value: saves a setting in the config file
  /usr/bin/python3 - "$CONFIG" "$1" "$2" <<'PY'
import re, sys
path, key, value = sys.argv[1:4]
text = open(path).read()
line = f'{key}="{value}"'
if re.search(rf'^{key}=', text, re.M):
    text = re.sub(rf'^{key}="[^"]*"', lambda m: line, text, count=1, flags=re.M)
else:
    text += line + "\n"
open(path, "w").write(text)
PY
  typeset -g "$1=$2"
}

ask() {  # ask "question" [default]: answer in $REPLY (empty when not run from a terminal)
  REPLY=""
  [ -t 0 ] && read -r "REPLY?  $1${2:+ [$2]}: "
  [ -z "$REPLY" ] && REPLY=${2:-}
}
yes_no() { ask "$1 (y/N)"; [[ "$REPLY" == [yYoO]* ]]; }

need_brew() {  # installs the missing Homebrew formulae
  command -v brew >/dev/null || { skip "Homebrew is required (https://brew.sh)"; return 1; }
  local missing=() f
  for f in "$@"; do brew list --formula "$f" >/dev/null 2>&1 || missing+=("$f"); done
  if (( ${#missing} )); then
    note "Homebrew: ${missing[*]}"
    HOMEBREW_NO_ENV_HINTS=1 brew install --quiet "${missing[@]}" || return 1
  fi
}

copy_files() {  # copy_files file… folder
  local dst=${@[-1]} f
  mkdir -p "$dst"
  for f in "${@[1,-2]}"; do
    cp "$f" "$dst/" || return 1
    [[ "${f:t}" == *.sh || "${f:t}" == *.py || "${f:t}" != *.* ]] && chmod +x "$dst/${f:t}"
  done
  return 0
}

build_swift() {  # build_swift source.swift folder binary: only rebuilds when the source changed
  local src=$1 dir=$2 bin=$3
  if [ -x "$dir/$bin" ] && cmp -s "$src" "$dir/${src:t}"; then ok "$bin is up to date"; return 0; fi
  xcode-select -p >/dev/null 2>&1 || { skip "Command Line Tools required: xcode-select --install"; return 1; }
  copy_files "$src" "$dir" || return 1
  xcrun swiftc -O "$dir/${src:t}" -o "$dir/$bin.tmp" 2>&1 | grep 'error' >&2
  [ -x "$dir/$bin.tmp" ] || { skip "could not compile ${src:t}"; return 1; }
  mv -f "$dir/$bin.tmp" "$dir/$bin" && ok "$bin compiled"
}

install_agent() {  # install_agent name: installs and (re)starts the service described in agents/name.plist
  local name=$1 label="$PREFIX.$1" dst="$AGENTS/$PREFIX.$1.plist" p
  mkdir -p "$AGENTS" "$HOME/Library/Logs/mac-toolkit"
  sed -e "s|__HOME__|$HOME|g" -e "s|__PREFIX__|$PREFIX|g" \
      -e "s|__HEADSET_NAME__|${HEADSET_NAME:-}|g" "$HERE/agents/$name.plist" > "$dst"
  # a service installed under another name that runs the same program is replaced
  local prog=$(/usr/bin/python3 -c 'import plistlib,sys; print([a for a in plistlib.load(open(sys.argv[1],"rb"))["ProgramArguments"] if "/" in a][-1])' "$dst")
  for p in "$AGENTS"/*.plist; do
    [ "$p" = "$dst" ] && continue
    if grep -qF "<string>$prog</string>" "$p" 2>/dev/null; then
      launchctl bootout "gui/$UID" "$p" 2>/dev/null; rm -f "$p"
      note "replaced older service ${p:t:r}"
    fi
  done
  launchctl bootout "gui/$UID/$label" 2>/dev/null && sleep 1
  launchctl bootstrap "gui/$UID" "$dst" && ok "service $label started"
}

install_shortcut() {  # install_shortcut "Name" script: Share-menu action (Shortcuts app)
  local name=$1 script=$2 tmp
  # names returned by "shortcuts list" are decomposed Unicode: compare after normalising
  if shortcuts list 2>/dev/null | /usr/bin/python3 -c 'import sys, unicodedata as u
n = u.normalize("NFC", sys.argv[1])
sys.exit(0 if any(u.normalize("NFC", l.rstrip("\n")) == n for l in sys.stdin) else 1)' "$name"; then
    ok "shortcut \"$name\" already installed"; return
  fi
  tmp=$(mktemp -d /tmp/mac-toolkit.XXXXXX)
  if /usr/bin/python3 "$HERE/lib/shortcut.py" "$script" "$tmp/unsigned.shortcut" \
     && shortcuts sign --mode anyone --input "$tmp/unsigned.shortcut" --output "$tmp/$name.shortcut" >/dev/null 2>&1; then
    open "$tmp/$name.shortcut"
    note "shortcut \"$name\": click \"Add Shortcut\" in the window that opens"
  else
    skip "shortcut \"$name\" (signing goes through Apple's servers: an internet connection is needed)"
  fi
}

# ---------- tools ----------

install_headset_guard() {
  if [ -z "${HEADSET_NAME:-}" ]; then
    ask "Headset name, or part of it (Enter = any Bluetooth headset)"
    [ -n "$REPLY" ] && set_config HEADSET_NAME "$REPLY"
  fi
  build_swift "$HERE/headset-guard/headset-guard.swift" "$BASE/headset-guard" headset-guard || return
  install_agent headset-guard
}

install_clean_links() {
  build_swift "$HERE/clean-links/clean-links.swift" "$BASE/clean-links" clean-links || return
  install_agent clean-links
}

install_fps_counter() {
  copy_files "$HERE/fps-counter/fps-counter" "$BASE/fps-counter" || return
  install_agent fps-counter
  note "the counter shows up in the top-right corner of games started from now on"
}

install_quick_actions() {
  need_brew ffmpeg whisper-cpp ghostscript exiftool qpdf || return
  copy_files "$HERE"/quick-actions/*(.) "$BASE/quick-actions" || return
  local w
  mkdir -p "$HOME/Library/Services"
  for w in "$HERE"/services/*.workflow; do
    rm -rf "$HOME/Library/Services/${w:t}"; cp -R "$w" "$HOME/Library/Services/"
  done
  /System/Library/CoreServices/pbs -update 2>/dev/null
  ok "quick actions added to the Finder's right-click menu"
  local m="$HOME/.cache/whisper-cpp"
  if [ ! -f "$m/ggml-large-v3-turbo.bin" ] && [ ! -f "$m/ggml-large-v3.bin" ]; then
    if yes_no "Download the Whisper large-v3-turbo model for \"Transcribe\" (1.6 GB)?"; then
      mkdir -p "$m"
      curl -fL --progress-bar -o "$m/ggml-large-v3-turbo.bin.part" \
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin" \
        && mv "$m/ggml-large-v3-turbo.bin.part" "$m/ggml-large-v3-turbo.bin" && ok "Whisper model installed"
    else
      note "\"Transcribe\" will look for the model in $m"
    fi
  fi
}

install_download_video() {
  need_brew yt-dlp ffmpeg || return
  copy_files "$HERE/share/download-video.sh" "$BASE/share" || return
  copy_files "$HERE/update-ytdlp/update-ytdlp" "$BASE/update-ytdlp" || return
  install_agent update-ytdlp
  install_shortcut "Download Video" "$BASE/share/download-video.sh"
}

install_send_to_tv() {
  # reuses the developer-mode key that ares-cli fetched (ares-setup-device, then ares-novacom --getkey)
  local device=${TV_ARES_DEVICE:-tv} info
  info=$(/usr/bin/python3 - "$device" <<'PY'
import glob, json, os, sys
for path in glob.glob(os.path.expanduser("~/.webos/*/novacom-devices.json")):
    for d in json.load(open(path)):
        if d.get("name") == sys.argv[1] and d.get("passphrase"):
            key = (d.get("privateKey") or {}).get("openSsh", "")
            print(d.get("host", ""), d.get("port", 9922), d.get("username", "prisoner"), key, d["passphrase"])
            sys.exit()
PY
)
  local fields=(${=info})
  if (( ${#fields} < 5 )) || [ ! -f "$HOME/.ssh/${fields[4]}" ]; then
    skip "no developer-mode key for \"$device\" (set the TV up with ares-cli: ares-setup-device, then ares-novacom --getkey)"
    return
  fi
  [ -z "${TV_IP:-}" ] && set_config TV_IP "${fields[1]}"
  set_config TV_SSH_PORT "${fields[2]}"
  set_config TV_SSH_USER "${fields[3]}"
  # unencrypted copy of the key, readable only by you, so the action can connect without a prompt
  local key="${CONFIG:h}/tv_key"
  cp "$HOME/.ssh/${fields[4]}" "$key" && chmod 600 "$key" \
    && ssh-keygen -p -q -P "${fields[5]}" -N "" -f "$key" >/dev/null 2>&1 \
    || { skip "could not prepare the TV key"; rm -f "$key"; return; }
  ok "TV key ready"
  if [ -z "${TV_MAC:-}" ]; then
    ping -c 1 -t 2 "$TV_IP" >/dev/null 2>&1
    local mac=$(arp -n "$TV_IP" 2>/dev/null | awk '{ n = split($4, a, ":"); if (n != 6) exit
      for (i = 1; i <= 6; i++) { x = a[i]; if (length(x) < 2) x = "0" x; printf "%s%s", (i > 1 ? ":" : ""), x } }')
    [ -n "$mac" ] && { set_config TV_MAC "$mac"; note "Wake-on-LAN enabled ($mac)"; }
  fi
  copy_files "$HERE/share/send-to-tv.sh" "$BASE/share" || return
  install_agent send-to-tv   # finishes the job when the TV has to be woken up first
  install_shortcut "Send to TV" "$BASE/share/send-to-tv.sh"
  note "to let it turn the TV on: TV settings › General › External Devices › TV On With Mobile › Turn on via Wi-Fi"
}

install_auto_pip() {
  local d="$HOME/Library/Containers/com.userscripts.macos.Userscripts-Extension/Data/Documents"
  [ -d "$d/scripts" ] || { skip "the Userscripts Safari extension is missing (App Store): install it, then run this again"; return; }
  cp "$HERE/safari/auto-pip.user.js" "$d/scripts/"
  [ -f "$d/manifest.json" ] && /usr/bin/python3 - "$d/manifest.json" <<'PY'
import json, sys
path = sys.argv[1]
m = json.load(open(path))
scripts = m.setdefault("match", {}).setdefault("*://*/*", [])
if "auto-pip.user.js" not in scripts:
    scripts.append("auto-pip.user.js")
json.dump(m, open(path, "w"), indent=2, ensure_ascii=False)
PY
  ok "\"Auto PiP\" added to Userscripts"
}

install_wallper_sync() {
  defaults read sandimax.Wallper >/dev/null 2>&1 || { skip "Wallper is not installed"; return; }
  copy_files "$HERE/wallper-sync/sync.py" "$BASE/wallper-sync" || return
  build_swift "$HERE/wallper-sync/wallper-frame.swift" "$BASE/wallper-sync" wallper-frame || return
  install_agent wallper-sync
}

install_finetune_patch() {
  zsh "$HERE/finetune-patch/build.sh"
}

# ---------- main ----------

if [ "${1:-}" = "--list" ]; then
  for t in $DEFAULT_TOOLS finetune-patch; do printf "  %-16s %s\n" "$t" "${DESCRIPTION[$t]}"; done
  exit 0
fi

mkdir -p "${CONFIG:h}"
[ -f "$CONFIG" ] || cp "$HERE/config.example" "$CONFIG"
source "$CONFIG"

chosen=("$@")
(( ${#chosen} )) || chosen=($DEFAULT_TOOLS)
for t in $chosen; do
  if (( ! ${+DESCRIPTION[$t]} )); then print -r -- "Unknown tool: $t (see ./install.sh --list)"; continue; fi
  title "$t: ${DESCRIPTION[$t]}"
  install_${t//-/_}
done
print -r -- $'\n'"Done. Settings: $CONFIG"
