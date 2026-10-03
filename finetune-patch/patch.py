#!/usr/bin/python3
# Patches FineTune 1.9.0 so that the default output and input devices stay under macOS control:
# no priority list, no reverting macOS when a device connects, no fallback choice on disconnect.
# Also replaces the Sparkle updater with a stub.
# Usage: patch.py <FineTune source folder>
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
engine = src / "FineTune/Audio/Engine/AudioEngine.swift"
s = engine.read_text()

old = """        // If the disconnected device was the system default, override to priority fallback
        if wasDefaultOutput {
            reEvaluateOutputDefault(excluding: deviceUID)
        }
"""
new = """        // [mac-toolkit] macOS picks the new default output; FineTune follows it in handleDefaultDeviceChanged.
        _ = wasDefaultOutput
"""
assert s.count(old) == 1, "disconnect patch"
s = s.replace(old, new)

start = "        // Only override the default if the newly connected device IS the highest-priority\n"
end = "        logger.debug(\"Entered PENDING_AUTOSWITCH for \\(deviceName) (\\(timeout)s grace)\")\n"
assert s.count(start) == 1, "connect patch"
i = s.index(start)
j = s.index(end, i) + len(end)
s = s[:i] + """        // [mac-toolkit] No priority list and no reverting macOS: the default output stays with macOS.
        if let device = deviceMonitor.device(for: deviceUID),
           !isAliveCheck(device.id) {
            installAliveWatcher(deviceID: device.id, uid: deviceUID, name: deviceName)
        }
""" + s[j:]

old = """        // If the disconnected device was the default input, override to priority fallback
        if wasDefaultInput {
            reEvaluateInputDefault(excluding: deviceUID)
        }
"""
new = """        // [mac-toolkit] macOS picks the new default input.
"""
assert s.count(old) == 1, "input patch"
s = s.replace(old, new)
engine.write_text(s)

(src / "FineTune/Utilities/UpdateManager.swift").write_text('''// [mac-toolkit] No Sparkle: this build never updates itself.
import Foundation
import Combine

@MainActor
final class UpdateManager: NSObject, ObservableObject {
    @Published var canCheckForUpdates = false
    override init() { super.init() }
    func checkForUpdates() {}
    var automaticallyChecksForUpdates: Bool { get { false } set {} }
    var automaticallyDownloadsUpdates: Bool { get { false } set {} }
    var lastUpdateCheckDate: Date? { nil }
}
''')
print("patched")
