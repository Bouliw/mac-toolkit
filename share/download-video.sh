#!/bin/zsh
# "Download Video" (Safari Share menu): downloads the video behind a link with yt-dlp
# (YouTube, X, Instagram, TikTok, Twitch…) as MP4 in the best quality, into Downloads.
# Videos that are neither H.264 nor HEVC (VP9/AV1 above 1080p on YouTube) are converted to HEVC
# on the Mac's media engine, at full resolution, so QuickTime and Final Cut can open them.
# Direct use: download-video.sh --convert file.mp4
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
DEST="$HOME/Downloads"

notify() {
  [ -n "$MTK_TEST" ] && return
  /usr/bin/osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' "$1" "$2" >/dev/null 2>&1
}

# Re-encode to HEVC (VideoToolbox) when QuickTime / Final Cut can't read the video codec
convert_video() {
  local f="$1"
  local vc=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$f")
  case "$vc" in h264|hevc|"") return 0 ;; esac
  local pf=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$f")
  local ac=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$f")
  # target bitrate: source + 20 % (same visual quality), between 4 and 80 Mb/s
  local vbr=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of csv=p=0 "$f")
  [[ "$vbr" == <-> ]] || vbr=$(( $(ffprobe -v error -show_entries format=bit_rate -of csv=p=0 "$f") - 200000 ))
  local target=$(( vbr * 12 / 10 )); (( target < 4000000 )) && target=4000000; (( target > 80000000 )) && target=80000000
  local vopts=(-c:v hevc_videotoolbox -b:v $target -tag:v hvc1)
  case "$pf" in *10*) vopts+=(-profile:v main10 -pix_fmt p010le) ;; *) vopts+=(-pix_fmt nv12) ;; esac
  local aopts=(-an)
  [ -n "$ac" ] && { [ "$ac" = "aac" ] && aopts=(-c:a copy) || aopts=(-c:a aac -b:a 192k); }
  notify "Converting for QuickTime" "$(basename "$f")"
  local tmp="${f%.*}.converting.mp4"
  if ffmpeg -nostdin -y -v error -hwaccel videotoolbox -i "$f" -map 0:v:0 -map '0:a:0?' $vopts $aopts -movflags +faststart "$tmp" && [ -s "$tmp" ]; then
    mv -f "$tmp" "$f"
  else
    rm -f "$tmp"; notify "Conversion failed" "The video still plays in VLC"
  fi
}

if [ "$1" = "--convert" ]; then
  shift; for f in "$@"; do [ -f "$f" ] && convert_video "$f"; done
  notify "Video ready" "Plays in QuickTime and Final Cut"; exit 0
fi

# every http(s) link received (one or more per argument), without duplicates
typeset -A seen; links=()
for word in ${=*}; do
  case "$word" in http://*|https://*) [ -z "${seen[$word]}" ] && { seen[$word]=1; links+=("$word"); } ;; esac
done
[ ${#links} -eq 0 ] && { notify "Download failed" "No video link received"; exit 0; }

for u in $links; do
  notify "Downloading video" "Starting…"
  tmp=$(mktemp -d /tmp/download.XXXXXX)
  if f=$(yt-dlp --no-playlist --no-progress --quiet --no-warnings \
          -f "bv*+ba/b" -S "res,fps,vcodec:avc1,acodec:m4a" --merge-output-format mp4 \
          -o "$DEST/%(title).120B [%(id)s].%(ext)s" --print after_move:filepath "$u" 2>"$tmp/err") && [ -n "$f" ] && [ -f "${f##*$'\n'}" ]; then
    f="${f##*$'\n'}"
    convert_video "$f"
    notify "Video downloaded" "$(basename "$f")"
  else
    reason=$(grep -m1 -o 'ERROR:.*' "$tmp/err" | cut -c8-110)
    notify "Download failed" "${reason:-unsupported link}"
  fi
  rm -rf "$tmp"
done
