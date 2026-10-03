#!/bin/zsh
# Finder quick action "Transcribe": local transcription (whisper.cpp on Metal) of an audio or video file.
# Writes "name.txt" and "name.srt" next to the file. The language is detected automatically.
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
MODEL="$HOME/.cache/whisper-cpp/ggml-large-v3-turbo.bin"
[ -f "$MODEL" ] || MODEL="$HOME/.cache/whisper-cpp/ggml-large-v3.bin"

notify() {
  [ -n "$MTK_TEST" ] && return
  /usr/bin/osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' "$1" "$2" >/dev/null 2>&1
}

if [ ! -f "$MODEL" ]; then notify "Transcription failed" "No Whisper model in ~/.cache/whisper-cpp"; exit 1; fi

for f in "$@"; do
  [ -f "$f" ] || continue
  dir=$(dirname "$f"); base=$(basename "$f"); name="${base%.*}"
  out="$dir/$name"
  if [ -e "$out.txt" ] || [ -e "$out.srt" ]; then
    i=2; while [ -e "$dir/$name ($i).txt" ] || [ -e "$dir/$name ($i).srt" ]; do i=$((i+1)); done
    out="$dir/$name ($i)"
  fi
  tmp=$(mktemp -d /tmp/transcribe.XXXXXX)
  notify "Transcribing" "$base"
  if ffmpeg -nostdin -v error -i "$f" -vn -ac 1 -ar 16000 -c:a pcm_s16le "$tmp/audio.wav" \
     && whisper-cli -m "$MODEL" -l auto -otxt -osrt -np -of "$tmp/out" -f "$tmp/audio.wav" >/dev/null 2>"$tmp/err.log" \
     && [ -s "$tmp/out.txt" ]; then
    mv "$tmp/out.txt" "$out.txt"; mv "$tmp/out.srt" "$out.srt"
    notify "Transcription done" "$(basename "$out").txt and .srt"
  else
    notify "Transcription failed" "$base (no audio track or unreadable format)"
  fi
  rm -rf "$tmp"
done
