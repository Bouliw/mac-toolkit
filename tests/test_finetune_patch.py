"""finetune-patch scripts on a small fixture: patch.py (upstream text to patch, loud failure when it changed)
and no_previews.py (#Preview blocks). No FineTune source and no network needed.
Run: python3 -m unittest discover -s tests -v"""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PATCH = ROOT / "finetune-patch/patch.py"
NO_PREVIEWS = ROOT / "finetune-patch/no_previews.py"

# The lines patch.py looks for, as in FineTune v1.9.0, with a little code around them
ENGINE = r'''final class AudioEngine {
    private func handleDeviceDisconnected(_ deviceUID: String, name deviceName: String) {
        let wasDefaultOutput = deviceVolumeMonitor.defaultDeviceUID == deviceUID
        showDisconnectNotification(deviceName: deviceName)

        // If the disconnected device was the system default, override to priority fallback
        if wasDefaultOutput {
            reEvaluateOutputDefault(excluding: deviceUID)
        }
    }

    private func handleDeviceConnected(_ deviceUID: String, name deviceName: String) {
        restorePinnedApps(deviceUID)

        // Only override the default if the newly connected device IS the highest-priority
        // device (i.e., a higher-priority device just came back).
        let currentDefault = deviceVolumeMonitor.defaultDeviceUID
        if isNewDeviceHigherPriority, deviceUID != currentDefault {
            reEvaluateOutputDefault()
        }
        outputPriorityState = .pendingAutoSwitch(connectedDeviceUID: deviceUID)
        logger.debug("Entered PENDING_AUTOSWITCH for \(deviceName) (\(timeout)s grace)")
    }

    // MARK: - Alive Watchers
    private func installAliveWatcher(deviceID: AudioDeviceID, uid: String, name: String) {}

    private func handleInputDisconnected(_ deviceUID: String) {
        let priorityFallback = resolveHighestPriority(excluding: deviceUID)

        // If the disconnected device was the default input, override to priority fallback
        if wasDefaultInput {
            reEvaluateInputDefault(excluding: deviceUID)
        }

        updateLockedInput()
    }
}
'''


class FineTunePatch(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.src = Path(tmp.name)
        self.engine = self.src / "FineTune/Audio/Engine/AudioEngine.swift"
        self.updater = self.src / "FineTune/Utilities/UpdateManager.swift"
        self.engine.parent.mkdir(parents=True)
        self.updater.parent.mkdir(parents=True)

    def patch(self, engine_text=ENGINE):
        self.engine.write_text(engine_text)
        return subprocess.run([str(PATCH), str(self.src)], capture_output=True, text=True, timeout=30)

    def test_default_devices_are_left_to_macos(self):
        r = self.patch()
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "patched"), r.stderr)
        s = self.engine.read_text()
        for gone in ("reEvaluateOutputDefault", "reEvaluateInputDefault", "PENDING_AUTOSWITCH", "priority fallback",
                     "Only override the default"):
            self.assertNotIn(gone, s)
        # the code around the patched lines is untouched
        for kept in ("showDisconnectNotification(deviceName: deviceName)", "restorePinnedApps(deviceUID)",
                     "// MARK: - Alive Watchers", "resolveHighestPriority(excluding: deviceUID)", "updateLockedInput()"):
            self.assertIn(kept, s)
        self.assertEqual(s.count("[mac-toolkit]"), 3)
        self.assertIn("installAliveWatcher(deviceID: device.id", s)

    def test_updater_is_replaced_by_a_stub(self):
        self.patch()
        s = self.updater.read_text()
        self.assertIn("final class UpdateManager", s)
        self.assertNotIn("import Sparkle", s)
        self.assertIn("func checkForUpdates() {}", s)

    def test_changed_upstream_text_fails_and_changes_nothing(self):
        # a new FineTune version must break the build loudly, not produce a half-patched app
        cases = [
            ("disconnect patch", ENGINE.replace("If the disconnected device was the system default", "Something else")),
            ("connect patch", ENGINE.replace("Only override the default if", "Something else")),
            ("input patch", ENGINE.replace("If the disconnected device was the default input", "Something else")),
            ("disconnect patch", ENGINE + ENGINE),  # a line found twice is not patched either
        ]
        for tag, text in cases:
            with self.subTest(tag=tag, copies=text.count("final class")):
                self.updater.unlink(missing_ok=True)
                r = self.patch(text)
                self.assertNotEqual(r.returncode, 0)
                self.assertIn(tag, r.stderr)
                self.assertEqual(self.engine.read_text(), text)
                self.assertFalse(self.updater.exists())


class NoPreviews(unittest.TestCase):
    SOURCE = '''import SwiftUI

struct A: View { var body: some View { Text("a") } }

#Preview {
    VStack {
        Text("}")
        Text("{ \\" }")
    }
}

struct B {}

    #Preview("Dark", traits: .landscapeLeft) { B() }
'''
    WRAPPED = '''import SwiftUI

struct A: View { var body: some View { Text("a") } }

#if false
#Preview {
    VStack {
        Text("}")
        Text("{ \\" }")
    }
}
#endif

struct B {}

#if false
    #Preview("Dark", traits: .landscapeLeft) { B() }
#endif
'''

    def test_previews_are_wrapped_in_if_false(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "a").mkdir()
            (root / "a/.build").mkdir()
            plain = "struct C {}\n"
            (root / "a/View.swift").write_text(self.SOURCE)
            (root / "a/Plain.swift").write_text(plain)
            (root / "a/.build/Generated.swift").write_text(self.SOURCE)
            (root / "a/notes.txt").write_text(self.SOURCE)
            r = subprocess.run([str(NO_PREVIEWS), str(root / "a")], capture_output=True, text=True, timeout=30)
            self.assertEqual((r.returncode, r.stdout.strip()), (0, "previews disabled: 2"), r.stderr)
            self.assertEqual((root / "a/View.swift").read_text(), self.WRAPPED)
            # no preview, build folder and other file types: untouched
            self.assertEqual((root / "a/Plain.swift").read_text(), plain)
            self.assertEqual((root / "a/.build/Generated.swift").read_text(), self.SOURCE)
            self.assertEqual((root / "a/notes.txt").read_text(), self.SOURCE)


if __name__ == "__main__":
    unittest.main()
