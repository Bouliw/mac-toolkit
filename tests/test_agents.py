"""The launchd agents against install.sh: what it fills in, the label it restarts, the program it expects.
Run: python3 -m unittest discover -s tests -v"""
import plistlib
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PREFIX = "local.mac-toolkit"


class Agents(unittest.TestCase):
    def test_agents_match_install_script(self):
        installer = (ROOT / "install.sh").read_text()
        installed = set(re.findall(r"^\s*install_agent (\S+)", installer, re.M))
        agents = {p.stem: p for p in (ROOT / "agents").glob("*.plist")}
        self.assertEqual(set(agents), installed)  # every agent is installed, every installed agent has its file
        for name, path in agents.items():
            with self.subTest(agent=name):
                text = path.read_text()
                # install.sh only fills in these three placeholders
                self.assertEqual(re.findall(r"__[A-Z_]+__", re.sub(r"__(HOME|PREFIX|HEADSET_NAME)__", "", text)), [])
                text = text.replace("__PREFIX__", PREFIX).replace("__HOME__", "/h").replace("__HEADSET_NAME__", "")
                agent = plistlib.loads(text.encode())
                # install.sh restarts the service by this label
                self.assertEqual(agent["Label"], f"{PREFIX}.{name}")
                # and tells services apart by the last argument that is a path
                program = [a for a in agent["ProgramArguments"] if "/" in a][-1]
                self.assertTrue(program.startswith("/h/Library/Scripts/mac-toolkit/"), program)
                # the program is a file of this repository, as is or built from its .swift source
                source = ROOT / program.split("/mac-toolkit/", 1)[1]
                self.assertTrue(source.exists() or source.with_suffix(".swift").exists(), program)


if __name__ == "__main__":
    unittest.main()
