#!/bin/zsh
# Finder quick action "Compress for Discord": re-encodes a video under Discord's upload limit
# (10 MB on a free account) at the best possible quality (two-pass H.264, HDR tone-mapped).
# Writes "name (Discord).mp4" next to the file and copies it to the clipboard.
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
LIMIT=10000000
TARGET=$(( LIMIT * 93 / 100 ))

notify() {
  [ -n "$MTK_TEST" ] && return
  /usr/bin/osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' "$1" "$2" >/dev/null 2>&1
}
copy_to_clipboard() {
  [ -n "$MTK_TEST" ] && return
  /usr/bin/osascript -e 'on run argv' -e 'set the clipboard to (POSIX file (item 1 of argv))' -e 'end run' "$1" >/dev/null 2>&1
}

for f in "$@"; do
  [ -f "$f" ] || continue
  dir=$(dirname "$f"); base=$(basename "$f"); name="${base%.*}"
  size=$(stat -f%z "$f")
  if [ "$size" -le "$LIMIT" ]; then
    copy_to_clipboard "$f"
    notify "Already under 10 MB" "$base is copied, paste it into Discord"
    continue
  fi
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f")
  if [ -z "$dur" ]; then notify "Compression failed" "$base is not a readable video"; continue; fi
  audio=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$f" | head -1)
  trc=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer -of csv=p=0 "$f")
  out="$dir/$name (Discord).mp4"; i=2
  while [ -e "$out" ]; do out="$dir/$name (Discord $i).mp4"; i=$((i+1)); done
  notify "Compressing for Discord" "$base…"
  tmp=$(mktemp -d /tmp/discord.XXXXXX)
  factor=100; ok=0
  for attempt in 1 2 3; do
    total=$(awk -v t=$TARGET -v d=$dur -v k=$factor 'BEGIN{printf "%d", t*8/d/1000*k/100}')
    if [ -n "$audio" ]; then
      if [ $total -lt 500 ]; then abit=48; elif [ $total -lt 1500 ]; then abit=96; else abit=128; fi
    else abit=0; fi
    vbit=$(( total - abit ))
    [ $vbit -lt 80 ] && vbit=80
    if   [ $vbit -ge 2500 ]; then h=1080
    elif [ $vbit -ge 1200 ]; then h=720
    elif [ $vbit -ge 500 ];  then h=480
    else h=360; fi
    vf="scale='if(gt(iw,ih),-2,min(iw,$h))':'if(gt(iw,ih),min(ih,$h),-2)'"
    case "$trc" in
      smpte2084|arib-std-b67) vf="zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,$vf" ;;
    esac
    vf="$vf,format=yuv420p"
    fps=(); [ $vbit -lt 1500 ] && fps=(-fpsmax 30)
    ffmpeg -nostdin -y -v error -i "$f" -vf "$vf" $fps -c:v libx264 -preset medium -b:v ${vbit}k \
      -pass 1 -passlogfile "$tmp/pass" -an -f mp4 /dev/null || break
    if [ $abit -gt 0 ]; then aopts=(-c:a aac -b:a ${abit}k -ac 2); else aopts=(-an); fi
    ffmpeg -nostdin -y -v error -i "$f" -vf "$vf" $fps -c:v libx264 -preset medium -b:v ${vbit}k \
      -pass 2 -passlogfile "$tmp/pass" $aopts -movflags +faststart "$out" || break
    if [ $(stat -f%z "$out") -le $LIMIT ]; then ok=1; break; fi
    factor=$(( factor * 85 / 100 ))
  done
  rm -rf "$tmp"
  if [ $ok = 1 ]; then
    copy_to_clipboard "$out"
    notify "Ready for Discord" "$(basename "$out") ($(( $(stat -f%z "$out") / 1000000 )) MB), copied: paste it into Discord"
  else
    [ -e "$out" ] && rm -f "$out"
    notify "Compression failed" "$base"
  fi
done
