#!/bin/zsh
# Finder quick action "Strip Metadata": writes a copy "name (clean).ext" without metadata
# (GPS location, camera, author, company, software, dates…). Photos, videos, PDF, Word, Excel,
# PowerPoint. The original is untouched.
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
HERE="${0:A:h}"

notify() {
  [ -n "$MTK_TEST" ] && return
  /usr/bin/osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' "$1" "$2" >/dev/null 2>&1
}

cleaned=0; failed=0; last=""
for f in "$@"; do
  [ -f "$f" ] || continue
  dir=$(dirname "$f"); base=$(basename "$f"); name="${base%.*}"; ext="${base##*.}"
  out="$dir/$name (clean).$ext"; i=2
  while [ -e "$out" ]; do out="$dir/$name (clean $i).$ext"; i=$((i+1)); done
  tmpd=$(mktemp -d /tmp/strip.XXXXXX); res="$tmpd/res.$ext"
  case "${ext:l}" in
    pdf)
      # exiftool empties the metadata, qpdf rewrites the file so older revisions are gone too
      exiftool -q -q -all:all= -o "$tmpd/a.pdf" "$f" 2>/dev/null
      qpdf --linearize "$tmpd/a.pdf" "$res" >/dev/null 2>&1 ;;
    docx|xlsx|pptx|docm|xlsm|pptm)
      /usr/bin/python3 "$HERE/strip_office_metadata.py" "$f" "$res" 2>/dev/null ;;
    *)
      # keep the colour profile and orientation so the image looks the same
      exiftool -q -q -all= -tagsFromFile @ -ColorSpaceTags -Orientation -o "$res" "$f" 2>/dev/null ;;
  esac
  if [ -s "$res" ]; then mv "$res" "$out"; cleaned=$((cleaned+1)); last=$(basename "$out")
  else failed=$((failed+1)); fi
  rm -rf "$tmpd"
done

if [ $cleaned -eq 1 ] && [ $failed -eq 0 ]; then notify "Metadata removed" "$last"
elif [ $cleaned -gt 0 ]; then notify "Metadata removed" "$cleaned file(s) cleaned$([ $failed -gt 0 ] && echo ", $failed failed")"
else notify "Nothing cleaned" "Unsupported format or protected file"; fi
