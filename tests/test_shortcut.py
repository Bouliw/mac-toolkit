"""lib/shortcut.py: the Share menu shortcut built for Download Video and Send to TV.
Run: python3 -m unittest discover -s tests -v"""
import os
import plistlib
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILDER = ROOT / "lib/shortcut.py"


class Shortcut(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = tmp.name

    def build(self, script):
        out = Path(self.home) / "out.shortcut"
        subprocess.run([str(BUILDER), script, str(out)], env={**os.environ, "HOME": self.home},
                       capture_output=True, timeout=30, check=True)
        with open(out, "rb") as f:
            return plistlib.load(f)

    def test_script_runs_with_the_shared_link_and_item(self):
        shortcut = self.build(f"{self.home}/Library/Scripts/mac-toolkit/share/send-to-tv.sh")
        detect, run = shortcut["WFWorkflowActions"]
        self.assertEqual(detect["WFWorkflowActionIdentifier"], "is.workflow.actions.detect.link")
        self.assertEqual(run["WFWorkflowActionIdentifier"], "is.workflow.actions.runshellscript")
        script = run["WFWorkflowActionParameters"]["Script"]["Value"]
        # the path is relative to $HOME, so the shortcut does not hold this Mac's home folder
        self.assertEqual(script["string"], '/bin/zsh "$HOME/Library/Scripts/mac-toolkit/share/send-to-tv.sh" '
                                           "'￼' '￼' >/dev/null 2>&1")
        self.assertNotIn(self.home, script["string"])
        self.assertIn("ActionExtension", shortcut["WFWorkflowTypes"])

    def test_variables_sit_on_the_placeholders(self):
        # Shortcuts counts positions in UTF-16 code units, which differ from characters outside the BMP
        for script in ("/opt/tools/download-video.sh", "/opt/🎬 tools/download-video.sh"):
            with self.subTest(script=script):
                detect, run = self.build(script)["WFWorkflowActions"]
                value = run["WFWorkflowActionParameters"]["Script"]["Value"]
                text = value["string"]
                positions = [len(text[:m.start()].encode("utf-16-le")) // 2 for m in re.finditer("￼", text)]
                self.assertEqual(sorted(value["attachmentsByRange"]), sorted(f"{{{p}, 1}}" for p in positions))
                link, item = (value["attachmentsByRange"][f"{{{p}, 1}}"] for p in positions)
                self.assertEqual(link["OutputUUID"], detect["WFWorkflowActionParameters"]["UUID"])
                self.assertEqual(link["Type"], "ActionOutput")
                self.assertEqual(item, {"Type": "ExtensionInput"})


if __name__ == "__main__":
    unittest.main()
