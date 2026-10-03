#!/bin/zsh
# mac-toolkit: removes the tools and their services. Settings are kept unless --all is given.
setopt null_glob
PREFIX="${MACTOOLKIT_PREFIX:-local.mac-toolkit}"

for p in "$HOME/Library/LaunchAgents/$PREFIX".*.plist; do
  launchctl bootout "gui/$UID" "$p" 2>/dev/null; rm -f "$p"
  print -r -- "  ✓ removed service ${p:t:r}"
done
for v in MTL_HUD_ENABLED MTL_HUD_ELEMENTS MTL_HUD_SCALE MTL_HUD_ALIGNMENT MTL_HUD_OPACITY; do
  launchctl unsetenv "$v"
done

rm -rf "$HOME/Library/Scripts/mac-toolkit"
for w in "Transcribe" "Compress for Discord" "Shrink PDF" "Strip Metadata"; do
  rm -rf "$HOME/Library/Services/$w.workflow"
done
/System/Library/CoreServices/pbs -update 2>/dev/null
rm -f "$HOME/Library/Containers/com.userscripts.macos.Userscripts-Extension/Data/Documents/scripts/auto-pip.user.js"
print -r -- "  ✓ tools removed"

[ "${1:-}" = "--all" ] && rm -rf "$HOME/.config/mac-toolkit" "$HOME/Library/Logs/mac-toolkit" && print -r -- "  ✓ settings and logs removed"
print -r -- "  · delete the \"Download Video\" and \"Send to TV\" shortcuts in the Shortcuts app"
print -r -- "  · a patched FineTune stays in /Applications"
