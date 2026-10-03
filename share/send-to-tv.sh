#!/bin/zsh
# "Send to TV" (Safari Share menu): plays what is open in Safari on an LG webOS TV in developer mode.
#  - YouTube: the video (or playlist) starts where you were in Safari.
#  - Twitch: the channel (or VOD) opens in the TV's Twitch app.
# Safari is paused, and a Wake-on-LAN packet turns on a TV in standby.
# When the TV has to be woken up, the rest of the job is handed over to launchd
# (send-to-tv.sh --queued): it can take longer than Shortcuts lets a script run.
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
CONFIG="$HOME/.config/mac-toolkit/config"   # TV_IP, TV_MAC…: see config.example
[ -f "$CONFIG" ] && . "$CONFIG"
TV_KEY="${TV_SSH_KEY:-$HOME/.config/mac-toolkit/tv_key}"
APP_YT="${TV_APP_YOUTUBE:-youtube.leanback.v4}"
APP_TW="${TV_APP_TWITCH:-twitch.adamffdev.v1}"
LOG="$HOME/Library/Logs/mac-toolkit/send-to-tv.log"
QUEUE="$HOME/Library/Application Support/mac-toolkit/send-to-tv.request"
AGENT="${MACTOOLKIT_PREFIX:-local.mac-toolkit}.send-to-tv"

log() { mkdir -p "${LOG:h}"; print -r -- "$(date '+%F %T') $*" >> "$LOG"; }
notify() {
  [ -n "$TV_TEST" ] && { print -r -- "NOTIFY: $1 | $2"; return; }
  /usr/bin/osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' "$1" "$2" >/dev/null 2>&1
}

if [ -z "$TV_IP" ] || [ ! -f "$TV_KEY" ]; then
  notify "Send to TV" "No TV configured: run install.sh again"
  exit 1
fi

# Safari: current position of the video in the tab showing it (read), or pause that tab (pause)
safari_tab() {
  pgrep -xq Safari || return
  /usr/bin/osascript - "$1" "$key" <<'AS' 2>/dev/null
on run argv
  set mode to item 1 of argv
  set needle to item 2 of argv
  if mode is "read" then
    set js to "(function(){var v=document.querySelector('#movie_player video')||document.querySelector('video');if(!v)return '';return String(Math.floor(v.currentTime));})()"
  else
    set js to "(function(){document.querySelectorAll('video').forEach(function(v){v.pause();});return 'ok';})()"
  end if
  tell application "Safari"
    try
      set t to current tab of front window
      if (URL of t) contains needle then return (do JavaScript js in t)
    end try
    repeat with w in windows
      try
        repeat with t in tabs of w
          if (URL of t) contains needle then return (do JavaScript js in t)
        end repeat
      end try
    end repeat
  end tell
  return ""
end run
AS
}
if [ "$1" = "--queued" ]; then
  # started by launchd for a TV that is waking up: the request was prepared by the Share action
  [ -f "$QUEUE" ] || exit 0
  { read -r kind; read -r app; read -r params; read -r done_msg; } < "$QUEUE"
  rm -f "$QUEUE"
  queued=1
else
# 1) The link: first http(s) word received (Shortcuts may pass several values), else the clipboard
url=""
for word in ${=*}; do case "$word" in http://*|https://*) url="$word"; break ;; esac; done
if [ -z "$url" ]; then
  for word in ${=$(pbpaste 2>/dev/null)}; do case "$word" in http://*|https://*) url="$word"; break ;; esac; done
fi

# 2) YouTube (video id, playlist, timestamp) or Twitch (channel, VOD)
info=$(/usr/bin/python3 - "$url" <<'PY'
import re, sys
from urllib.parse import urlparse, parse_qs
try:
    p = urlparse(sys.argv[1].strip())
except Exception:
    print("-"); sys.exit()
host = (p.hostname or "").lower(); q = parse_qs(p.query)
if host == "youtu.be" or host.endswith(".youtu.be") or host == "youtube.com" \
        or host.endswith(".youtube.com") or host.endswith("youtube-nocookie.com"):
    vid = ""
    if "youtu.be" in host:
        vid = p.path.strip("/").split("/")[0]
    elif "v" in q:
        vid = q["v"][0]
    else:
        m = re.match(r"^/(shorts|live|embed|v)/([^/?#]+)", p.path)
        if m: vid = m.group(2)
    if not re.fullmatch(r"[A-Za-z0-9_-]{11}", vid or ""): vid = ""
    playlist = q.get("list", [""])[0]
    if not re.fullmatch(r"[A-Za-z0-9_-]{10,64}", playlist or ""): playlist = ""
    t = (q.get("t") or q.get("start") or [""])[0]
    sec = 0
    m = re.fullmatch(r"(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s?)?", t or "")
    if t and m:
        sec = int(m.group(1) or 0) * 3600 + int(m.group(2) or 0) * 60 + int(m.group(3) or 0)
    print("yt" if (vid or playlist) else "-", vid or "-", playlist or "-", sec)
elif host == "twitch.tv" or host.endswith(".twitch.tv"):
    parts = [x for x in p.path.split("/") if x]
    reserved = {"directory", "p", "settings", "subscriptions", "inventory", "wallet", "drops", "search",
                "downloads", "login", "signup", "turbo", "prime", "store", "friends", "messages", "following",
                "jobs", "user", "broadcast", "dashboard", "moderator", "popout", "embed", "clip", "clips"}
    if len(parts) >= 2 and parts[0] == "videos" and parts[1].isdigit():
        print("tw", "videos/" + parts[1])
    elif parts and re.fullmatch(r"[A-Za-z0-9_]{2,25}", parts[0]) and parts[0].lower() not in reserved:
        print("tw", parts[0].lower())
    else:
        print("-")
else:
    print("-")
PY
)
fields=(${(s: :)info})
kind=${fields[1]}
case "$kind" in
  yt) vid=${fields[2]}; playlist=${fields[3]}; pos=${fields[4]}; key="$vid"; [ "$vid" = "-" ] && key="list=$playlist" ;;
  tw) channel=${fields[2]}; key="twitch.tv/$channel" ;;
  *)  notify "Send to TV" "This is neither a YouTube video nor a Twitch channel."
      log "rejected: ${url:-no link} (received: ${(j: | :)@})"; exit 1 ;;
esac

if [ "$kind" = "yt" ] && [ "$vid" != "-" ]; then
  now=$(safari_tab read)
  if [[ "$now" == <-> ]] && (( now > 0 )); then
    pos=$(( now > 3 ? now - 2 : 0 ))   # start 2 s earlier so nothing is missed
  fi
fi

# 3) The app and its parameters on the TV
if [ "$kind" = "yt" ]; then
  app="$APP_YT"
  target=""
  [ "$vid" != "-" ] && target="v=$vid"
  [ "$playlist" != "-" ] && target="${target:+$target&}list=$playlist"
  (( pos > 0 )) && target="$target&t=$pos"
  # "target": YouTube app from the Homebrew Channel (also works when it is already open);
  # "contentTarget": official YouTube app
  params="{\"target\":\"$target\",\"contentTarget\":\"$target\"}"
else
  app="$APP_TW"
  params="{\"channel\":\"$channel\"}"
fi
  if [ "$kind" = "tw" ]; then
    done_msg="Twitch: $channel"
  elif (( pos > 0 )); then
    done_msg="Resuming at $(printf '%d:%02d' $((pos/60)) $((pos%60)))"
  else
    done_msg="Playing."
  fi
fi
[ -n "$TV_DRY" ] && { print -r -- "APP: $app | PARAMS: $params"; exit 0; }

# The TV is driven through its developer-mode SSH access, with macOS's own ssh. A Node tool such as
# ares-launch is denied local network access when it runs from Shortcuts; Apple's binaries are not.
tv_ssh() {
  /usr/bin/ssh -tt -i "$TV_KEY" -p "${TV_SSH_PORT:-9922}" -o BatchMode=yes -o ConnectTimeout=5 \
    -o IdentitiesOnly=yes -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$HOME/.config/mac-toolkit/known_hosts" \
    -o LogLevel=ERROR "${TV_SSH_USER:-prisoner}@$TV_IP" "$1" </dev/null 2>&1 | tr -d '\r'
}
luna() { tv_ssh "/usr/bin/luna-send-pub -n 1 luna://$1 '$2'"; }

# 4) The TV: Wake-on-LAN every time (turns the screen on from standby, harmless when it's already on)
tv_up() { nc -z -G 1 "$TV_IP" 9922 >/dev/null 2>&1; }
wake_tv() {
  [ -n "$TV_MAC" ] || return 0
  /usr/bin/python3 -c '
import socket, sys
packet = b"\xff" * 6 + bytes.fromhex(sys.argv[1].replace(":", "")) * 16
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for _ in range(3):
    for addr in ("255.255.255.255", sys.argv[2], sys.argv[3]):
        for port in (9, 7):
            try: s.sendto(packet, (addr, port))
            except OSError: pass
' "$TV_MAC" "${TV_IP%.*}.255" "$TV_IP"
}
wake_tv
if ! tv_up; then
  if [ -z "$queued" ] && launchctl print "gui/$UID/$AGENT" >/dev/null 2>&1; then
    # waking up takes up to half a minute: launchd finishes the job, Safari is paused now
    safari_tab pause >/dev/null
    mkdir -p "${QUEUE:h}"
    print -r -- "$kind"$'\n'"$app"$'\n'"$params"$'\n'"$done_msg" > "$QUEUE"
    notify "Send to TV" "Turning the TV on…"
    launchctl kickstart "gui/$UID/$AGENT" >/dev/null 2>&1 && exit 0
  fi
  [ -n "$queued" ] || notify "Send to TV" "Turning the TV on…"
  # a TV on Wi-Fi only listens now and then while asleep: keep knocking while waiting
  for i in {1..40}; do tv_up && break; (( i % 3 == 0 )) && wake_tv; sleep 1; done
  if ! tv_up; then
    notify "TV unreachable" "Turn it on, or enable \"Turn on via Wi-Fi\" in its settings."
    log "TV unreachable"; exit 1
  fi
  woke=1
  # then wait until it is back on the Internet, and let webOS finish starting: an app opened
  # too early stays stuck loading the video
  for i in {1..20}; do
    luna com.webos.service.connectionmanager/getStatus '{}' | grep -q '"isInternetConnectionAvailable":true' && break
    sleep 1
  done
  # a game console woken up through HDMI-CEC takes over the screen during its first seconds: let it
  sleep 12
fi

# 5) Launch the right app
# the Twitch app only reads the channel at startup, and an app left running through standby can no
# longer load a video: close it first in both cases
if [ "$kind" = "tw" ] || [ -n "$woke" ]; then
  luna com.webos.applicationManager/dev/closeByAppId "{\"id\":\"$app\"}" | grep -q '"returnValue":true' && sleep 2
fi
for attempt in 1 2 3 4 5 6; do
  output=$(luna com.webos.applicationManager/launch "{\"id\":\"$app\",\"subscribe\":false,\"params\":$params}")
  print -r -- "$output" | grep -q '"returnValue"' && break
  # no answer: right after waking up, the TV's network comes back a few seconds after the screen
  sleep 3
done
if print -r -- "$output" | grep -q '"returnValue":true'; then
  [ -n "$queued" ] || safari_tab pause >/dev/null
  notify "On the TV" "$done_msg"
  log "ok: $app $params${woke:+ (after waking the TV)}"
else
  notify "Send to TV" "The TV couldn't start the video."
  log "failed: $app $params: $(print -r -- "$output" | tr '\n' ' ' | cut -c1-300)"
  exit 1
fi
