"""Strip Metadata on Office files: strip_office_metadata.py and the Finder action around it, on tiny
fictitious documents. Run: python3 -m unittest discover -s tests -v"""
import os
import re
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "quick-actions/strip_office_metadata.py"
ACTION = ROOT / "quick-actions/strip-metadata.sh"

CORE = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/">'
        '<dc:title>Quarterly figures</dc:title><dc:creator>Alice Example</dc:creator>'
        '<cp:lastModifiedBy>Bob Example</cp:lastModifiedBy><dcterms:created>2024-01-02T03:04:05Z</dcterms:created>'
        '</cp:coreProperties>')
APP = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
       '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
       '<Application>Example Office</Application><Company>Acme Corp</Company><Manager>Carol Example</Manager>'
       '<Template>Normal.dotm</Template><TotalTime>42</TotalTime><HyperlinkBase>https://intranet.example/</HyperlinkBase>'
       '<Pages>3</Pages></Properties>')
APP_EMPTY_TAGS = APP.replace('<Company>Acme Corp</Company>', '<Company/>').replace('<Template>Normal.dotm</Template>', '<Template />')
CUSTOM = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
          '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties">'
          '<property name="Project" pid="2"><lpwstr>Secret project</lpwstr></property></Properties>')
BODY = '<w:document><w:body>Written by Alice Example, Acme Corp</w:body></w:document>'


def make_document(path, main_part="word/document.xml", app=APP, props=True):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", "<Types/>")
        z.writestr("_rels/.rels", "<Relationships/>")
        if props:
            z.writestr("docProps/core.xml", CORE)
            z.writestr("docProps/app.xml", app)
            z.writestr("docProps/custom.xml", CUSTOM)
        z.writestr(main_part, BODY)


def parts(path):
    with zipfile.ZipFile(path) as z:
        assert z.testzip() is None
        return {i.filename: z.read(i.filename).decode() for i in z.infolist()}


class StripOfficeMetadata(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)

    def run_script(self, src, dst):
        # run through its shebang, the interpreter the Finder action really uses
        return subprocess.run([str(SCRIPT), str(src), str(dst)], capture_output=True, text=True, timeout=30)

    def test_author_company_and_dates_are_removed(self):
        for ext, main in (("docx", "word/document.xml"), ("xlsx", "xl/workbook.xml")):
            for app in (APP, APP_EMPTY_TAGS):
                with self.subTest(ext=ext, empty_tags=app is APP_EMPTY_TAGS):
                    src, dst = self.dir / f"in.{ext}", self.dir / f"out.{ext}"
                    make_document(src, main, app)
                    self.assertEqual(self.run_script(src, dst).returncode, 0)
                    out = parts(dst)
                    for gone in ("Alice", "Bob", "Quarterly", "2024-01-02", "Acme", "Carol", "Normal.dotm",
                                 "TotalTime", "intranet", "Secret"):
                        self.assertFalse(any(gone in v for k, v in out.items() if k.startswith("docProps/")), gone)
                    # what is not metadata stays, byte for byte, in the same order
                    self.assertEqual(list(out), list(parts(src)))
                    self.assertEqual(out[main], BODY)
                    self.assertEqual(out["[Content_Types].xml"], "<Types/>")
                    self.assertIn("<Application>Example Office</Application>", out["docProps/app.xml"])
                    self.assertIn("<Pages>3</Pages>", out["docProps/app.xml"])
                    self.assertTrue(re.search(r"<cp:coreProperties[^>]*></cp:coreProperties>", out["docProps/core.xml"]))

    def test_file_without_metadata_parts_is_copied_as_is(self):
        src, dst = self.dir / "in.docx", self.dir / "out.docx"
        make_document(src, props=False)
        self.assertEqual(self.run_script(src, dst).returncode, 0)
        self.assertEqual(parts(dst), parts(src))

    def test_unreadable_file_fails_without_output(self):
        # the Finder action counts a file as cleaned when the output exists and is not empty
        src, dst = self.dir / "in.docx", self.dir / "out.docx"
        src.write_text("not a zip")
        self.assertNotEqual(self.run_script(src, dst).returncode, 0)
        self.assertFalse(dst.exists())


class StripMetadataAction(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)

    def run_action(self, *files):
        # MTK_TEST turns the notification off
        subprocess.run(["/bin/zsh", str(ACTION), *map(str, files)], env={**os.environ, "MTK_TEST": "1"},
                       capture_output=True, timeout=60, check=True)

    def test_writes_a_clean_copy_next_to_the_original(self):
        src = self.dir / "My report (final).docx"
        make_document(src)
        original = src.read_bytes()
        self.run_action(src)
        self.run_action(src)
        names = sorted(p.name for p in self.dir.iterdir())
        self.assertEqual(names, ["My report (final) (clean 2).docx", "My report (final) (clean).docx",
                                 "My report (final).docx"])
        self.assertEqual(src.read_bytes(), original)
        self.assertNotIn("Alice", parts(self.dir / "My report (final) (clean).docx")["docProps/core.xml"])

    def test_unreadable_file_leaves_no_copy(self):
        src = self.dir / "broken.docx"
        src.write_text("not a zip")
        self.run_action(src)
        self.assertEqual([p.name for p in self.dir.iterdir()], ["broken.docx"])


if __name__ == "__main__":
    unittest.main()
