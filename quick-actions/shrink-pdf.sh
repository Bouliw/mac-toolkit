#!/bin/zsh
# Finder quick action "Shrink PDF": makes a PDF lighter (images recompressed at 150 dpi, duplicate
# fonts and images merged). Writes "name (shrunk).pdf" next to the file; the original is untouched.
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin

notify() {
  [ -n "$MTK_TEST" ] && return
  /usr/bin/osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' "$1" "$2" >/dev/null 2>&1
}
human() { awk -v b=$1 'BEGIN{ if (b>=1000000) printf "%.1f MB", b/1000000; else printf "%d KB", b/1000 }'; }

for f in "$@"; do
  [ -f "$f" ] || continue
  case "${f:l}" in *.pdf) ;; *) continue ;; esac
  dir=$(dirname "$f"); base=$(basename "$f"); name="${base%.*}"
  out="$dir/$name (shrunk).pdf"; i=2
  while [ -e "$out" ]; do out="$dir/$name (shrunk $i).pdf"; i=$((i+1)); done
  before=$(stat -f%z "$f")
  notify "Shrinking PDF" "$base…"
  tmpd=$(mktemp -d /tmp/shrink.XXXXXX); t="$tmpd/out.pdf"
  if gs -q -dNOPAUSE -dBATCH -dSAFER -sDEVICE=pdfwrite -dCompatibilityLevel=1.6 -dPDFSETTINGS=/ebook \
       -dDetectDuplicateImages=true -dCompressFonts=true -dAutoRotatePages=/None \
       -sOutputFile="$t" "$f" >/dev/null 2>"$tmpd/err" && [ -s "$t" ]; then
    after=$(stat -f%z "$t")
    if [ $after -lt $(( before * 95 / 100 )) ]; then
      mv "$t" "$out"
      notify "PDF shrunk" "$(human $before) → $(human $after): $(basename "$out")"
    else
      notify "Already light" "$base can't be made smaller"
    fi
  else
    notify "Shrinking failed" "$base (protected or unreadable PDF)"
  fi
  rm -rf "$tmpd"
done
