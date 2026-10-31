"""CleanLinks rules, through the real tool (clean-links --test <url>). Needs macOS and swiftc: the tool is
built like install.sh does, unless CLEAN_LINKS points to a binary that is already built.
Run: python3 -m unittest discover -s tests -v"""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class CleanLinks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = os.environ.get("CLEAN_LINKS")
        if not cls.binary:
            tmp = tempfile.TemporaryDirectory()
            cls.addClassCleanup(tmp.cleanup)
            cls.binary = os.path.join(tmp.name, "clean-links")
            subprocess.run(["swiftc", "-O", str(ROOT / "clean-links/clean-links.swift"), "-o", cls.binary],
                           check=True, capture_output=True)

    def clean(self, url):
        """The cleaned link, or None when the clipboard would be left alone."""
        # always one argument at least: without any, the tool would start watching the clipboard
        out = subprocess.run([self.binary, "--test", url], capture_output=True, text=True, timeout=30,
                             check=True).stdout
        return None if out == f"(unchanged) {url}\n" else out.rstrip("\n")

    def check(self, cases):
        for url, expected in cases:
            with self.subTest(url=url):
                self.assertEqual(self.clean(url), expected)

    def test_tracking_parameters_are_removed(self):
        self.check([
            ("https://example.com/page?utm_source=news&utm_medium=email&id=42", "https://example.com/page?id=42"),
            ("https://example.com/?utm_source=a", "https://example.com/"),  # nothing left: no dangling "?"
            ("http://example.com/?utm_source=a", "http://example.com/"),
            ("https://example.com/?b=2&UTM_Source=x&FBCLID=y&a=1", "https://example.com/?b=2&a=1"),
            ("https://shop.example/?gclid=1&msclkid=2&igsh=3&mc_cid=4&q=a", "https://shop.example/?q=a"),
            ("https://example.com/?utm_source=a&utm_source=b&id=1&id=2", "https://example.com/?id=1&id=2"),
            ("https://example.com/?flag&utm_source=x", "https://example.com/?flag"),
        ])

    def test_site_rules(self):
        self.check([
            ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=abc123", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
            ("https://music.youtube.com/watch?v=abc&si=x", "https://music.youtube.com/watch?v=abc"),
            ("https://www.youtube.com/watch?v=abc&list=PL1&index=2&si=x&feature=share",
             "https://www.youtube.com/watch?v=abc&list=PL1&index=2"),
            ("https://youtu.be/dQw4w9WgXcQ?si=abc&t=42", "https://youtu.be/dQw4w9WgXcQ?t=42"),
            ("https://open.spotify.com/track/xyz?si=abc&nd=1", "https://open.spotify.com/track/xyz"),
            ("https://www.linkedin.com/in/someone?trk=public_profile&originalSubdomain=fr",
             "https://www.linkedin.com/in/someone?originalSubdomain=fr"),
            ("https://x.com/user/status/1?s=20&t=abc", "https://x.com/user/status/1"),
            ("https://www.reddit.com/r/swift/comments/abc/?rdt=1234", "https://www.reddit.com/r/swift/comments/abc/"),
            ("https://www.google.com/search?q=foo&oq=foo&ei=abc&sourceid=chrome", "https://www.google.com/search?q=foo"),
            # Amazon: query parameters and the /ref=… path suffix, any country
            ("https://www.amazon.com/dp/B0123?ref=abc&pf_rd_r=1&pd_rd_i=2&psc=1&tag=aff-20",
             "https://www.amazon.com/dp/B0123?psc=1"),
            ("https://www.amazon.fr/Some-Product/dp/B0123/ref=sr_1_3?crid=X&qid=1&sr=8-1&th=1",
             "https://www.amazon.fr/Some-Product/dp/B0123?th=1"),
            ("https://www.amazon.com/s?k=shoes&crid=1&sprefix=sh%2Caps%2C100", "https://www.amazon.com/s?k=shoes"),
            # TikTok videos lose their whole query, other pages keep theirs
            ("https://www.tiktok.com/@user/video/123?is_from_webapp=1&sender_device=pc",
             "https://www.tiktok.com/@user/video/123"),
            ("https://www.tiktok.com/@user?lang=en", None),
        ])

    def test_site_rules_stay_on_their_site(self):
        # the same parameter names mean something else elsewhere
        self.check([
            ("https://example.com/?si=1&ref=2&trk=3&feature=4&s=5&t=6&tag=7&qid=8", None),
            ("https://github.com/Bouliw/mac-toolkit/tree/main?ref=main", None),
            ("https://notyoutube.com/?si=1", None),
            ("https://box.com/?s=1&t=2", None),
            ("https://www.dropbox.com/?s=1&t=2", None),
        ])

    def test_everything_else_is_left_alone(self):
        self.check([
            ("https://example.com/", None),
            ("https://example.com/?x=1", None),
            ("https://example.com/login?password=hunter2&token=abc", None),
            ("https://example.com/page#utm_source=a", None),  # a fragment is not a query
            ("https://example.com/search?q=c%2B%2B&x=a%26b%3Dc&u=https%3A%2F%2Fother.example%2F", None),
            ("https://www.youtube.com/watch?v=abc&list=PL1&t=42s", None),
        ])

    def test_fragment_encoding_and_credentials_survive_cleaning(self):
        self.check([
            ("https://example.com/page?utm_source=a#section-2", "https://example.com/page#section-2"),
            ("https://example.com/search?q=caf%C3%A9+cr%C3%A8me&utm_source=x", "https://example.com/search?q=caf%C3%A9+cr%C3%A8me"),
            ("https://example.com/search?q=hello%20world&utm_source=x", "https://example.com/search?q=hello%20world"),
            ("https://user:p%40ss@example.com/?utm_source=a", "https://user:p%40ss@example.com/"),
        ])

    def test_only_a_single_link_is_touched(self):
        # plain text, passwords and anything that is not exactly one http(s) link never change
        self.check([
            ("hello world", None),
            ("password123!", None),
            ("utm_source=x", None),
            ("example.com/?utm_source=a", None),
            ("ftp://example.com/?utm_source=a", None),
            ("https://example.com/?utm_source=a and some text", None),
            ("https://example.com/?utm_source=a https://example.org/?fbclid=1", None),
            ("https://example.com/?utm_source=a\nhttps://example.org/?fbclid=1", None),
            # whitespace around a single link is ignored
            ("  https://example.com/?utm_source=a\n", "https://example.com/"),
        ])

    def test_cleaning_twice_changes_nothing_more(self):
        for url in ("https://www.youtube.com/watch?v=abc&si=x", "https://www.amazon.fr/dp/B0123/ref=sr_1_3?qid=1",
                    "https://example.com/?utm_source=a&id=1#top"):
            with self.subTest(url=url):
                self.assertIsNone(self.clean(self.clean(url)))


if __name__ == "__main__":
    unittest.main()
