"""WallperSync logic on a fictitious wallpaper store: which desktops are switched to the lock screen video or
back to a frame, and which are never touched. No Wallper, no WallpaperAgent, nothing outside a temp folder.
Run: python3 -m unittest discover -s tests -v"""
import importlib.util
import os
import plistlib
import sys
import tempfile
import unicodedata
import unittest
import warnings
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True


def load_sync(home):
    """sync.py reads $HOME and the config at import time: load it against a temp home."""
    saved = os.environ.get("HOME")
    os.environ["HOME"] = home
    try:
        spec = importlib.util.spec_from_file_location("wallper_sync", ROOT / "wallper-sync/sync.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        if saved is None:
            del os.environ["HOME"]
        else:
            os.environ["HOME"] = saved


class WallperSyncCase(unittest.TestCase):
    def setUp(self):
        warnings.simplefilter("ignore", ResourceWarning)  # sync.py leaves the files it reads to be closed on exit
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = tmp.name
        self.sync = load_sync(self.home)
        self.folder = self.sync.FOLDER

    def frame(self, name):
        return self.sync.image_choice(self.sync.file_url(f"{self.folder}/{name}"))

    def user_image(self):
        return self.sync.image_choice(self.sync.file_url(f"{self.home}/Pictures/My own wallpaper.png"))

    @staticmethod
    def desktop(*choices, options=b"placement"):
        return {"Desktop": {"Content": {"Choices": list(choices), "EncodedOptionValues": options}}}

    def choices(self, d):
        return d["Desktop"]["Content"]["Choices"]


class Paths(WallperSyncCase):
    def test_file_url_is_decomposed_and_path_comes_back_composed(self):
        path = unicodedata.normalize("NFC", "/Data/Pictures/Wallper - café d'été.png")
        url = self.sync.file_url(path)
        # macOS stores file names decomposed (e + U+0301), spaces escaped, apostrophes as they are
        self.assertEqual(url, "file:///Data/Pictures/Wallper%20-%20cafe%CC%81%20d'e%CC%81te%CC%81.png")
        self.assertEqual(self.sync.path_from_url(url), path)

    def test_config_value(self):
        config = Path(self.home) / "config"
        self.sync.CONFIG = str(config)
        self.assertEqual(self.sync.config_value("A", "default"), "default")  # no file
        config.write_text('A="$HOME/Frames"\nB=""\n')
        self.assertEqual(self.sync.config_value("A", "default"), f"{self.home}/Frames")
        self.assertEqual(self.sync.config_value("B", "default"), "default")  # empty means default
        self.assertEqual(self.sync.config_value("C", "default"), "default")  # not in the file


class LockScreenAsset(WallperSyncCase):
    def test_asset_is_used_once_wallper_installed_the_current_video(self):
        aerials = Path(self.home) / "aerials"
        aerials.mkdir()
        self.sync.AERIALS = str(aerials)
        video = "/Videos/Ocean.MP4"
        prefs = {"ls27DesiredAssetID": "ASSET-1"}
        self.assertEqual(self.sync.lock_screen_asset(prefs, video), (None, False))  # video not in the aerials yet
        (aerials / "ASSET-1.mov").touch()
        self.assertEqual(self.sync.lock_screen_asset(prefs, video), ("ASSET-1", False))  # nothing installed yet
        prefs["wallper.lockscreen.slot.installed"] = "ocean|2"  # id, case ignored, then a suffix
        self.assertEqual(self.sync.lock_screen_asset(prefs, video), ("ASSET-1", True))
        prefs["wallper.lockscreen.slot.installed"] = "forest|2"  # another video: still being prepared
        self.assertEqual(self.sync.lock_screen_asset(prefs, video), ("ASSET-1", False))
        for bad in (None, "", 42):
            self.assertEqual(self.sync.lock_screen_asset({"ls27DesiredAssetID": bad}, video), (None, False))


class IsOldImage(WallperSyncCase):
    def test_only_wallper_frames_and_the_old_app_count(self):
        s = self.sync
        self.assertTrue(s.is_old_image(self.frame("Wallper - current A.png")))
        self.assertTrue(s.is_old_image(self.frame("Wallper - café.png")))  # accents: file names are decomposed
        old_app = s.image_choice("file:///Library/Caches/com.zhou.dynamicwallpaper/x.png")
        self.assertTrue(s.is_old_image(old_app))
        self.assertFalse(s.is_old_image(self.user_image()))
        self.assertFalse(s.is_old_image(s.aerial_choice("ASSET-1")))
        self.assertFalse(s.is_old_image({"Provider": s.IMAGE, "Configuration": b"not a plist"}))
        self.assertFalse(s.is_old_image({"Provider": s.IMAGE}))
        # the frame that is current right now is not "old"
        current = unicodedata.normalize("NFC", f"{self.folder}/Wallper - current A.png")
        self.assertFalse(s.is_old_image(self.frame("Wallper - current A.png"), keep=current))
        self.assertTrue(s.is_old_image(self.frame("Wallper - current B.png"), keep=current))


class Desktops(WallperSyncCase):
    def test_every_desktop_setting_is_found(self):
        a, b, c = self.desktop(), self.desktop(), self.desktop()
        store = {"Displays": {"D1": a}, "Spaces": {"1": {"Displays": {"D2": b}}},
                 "SystemDefault": [{"x": c}], "Other": {"Idle": {"Content": {"Choices": []}}},
                 "Broken": {"Desktop": {"Content": "no choices"}}}
        found = list(self.sync.desktops(store))
        self.assertEqual(len(found), 3)
        self.assertTrue(all(any(f is d["Desktop"] for f in found) for d in (a, b, c)))


class Switching(WallperSyncCase):
    def test_lock_screen_video_replaces_frames_and_nothing_else(self):
        s = self.sync
        frames = self.desktop(self.frame("Wallper - current A.png"))
        previous = self.desktop(s.aerial_choice("OLD-ASSET"))
        users = self.desktop(self.user_image())
        mixed = self.desktop(self.frame("Wallper - current A.png"), self.user_image())
        apple = self.desktop(s.aerial_choice("APPLE-AERIAL"))
        empty = self.desktop()
        saved = {}
        n = s.use_lock_screen_video("NEW-ASSET", "OLD-ASSET", saved)(
            {"Displays": {"1": frames, "2": previous, "3": users, "4": mixed, "5": apple, "6": empty}})
        self.assertEqual(n, 2)
        for d in (frames, previous):
            self.assertEqual(self.choices(d), [s.aerial_choice("NEW-ASSET")])
            self.assertEqual(d["Desktop"]["Content"]["EncodedOptionValues"], "$null")
            self.assertIn("LastSet", d["Desktop"])
        # the placement of the frame is kept to be restored later (only the first time)
        self.assertEqual(saved, {"image_options": b"placement"})
        self.assertEqual(plistlib.loads(self.choices(frames)[0]["Configuration"]), {"assetID": "NEW-ASSET"})
        # a wallpaper that is not Wallper's, alone or mixed with Wallper's, and Apple's aerials stay as they are
        self.assertEqual(self.choices(users), [self.user_image()])
        self.assertEqual(len(self.choices(mixed)), 2)
        self.assertEqual(self.choices(apple), [s.aerial_choice("APPLE-AERIAL")])
        self.assertEqual(self.choices(empty), [])
        self.assertNotIn("LastSet", users["Desktop"])

    def test_frame_replaces_the_lock_screen_video_and_older_frames(self):
        s = self.sync
        video = self.desktop(s.aerial_choice("ASSET-1"), options="$null")
        older = self.desktop(self.frame("Wallper - current B.png"))
        current = self.desktop(self.frame("Wallper - current A.png"))
        users = self.desktop(self.user_image())
        apple = self.desktop(s.aerial_choice("APPLE-AERIAL"))
        path = unicodedata.normalize("NFC", f"{self.folder}/Wallper - current A.png")
        url = s.file_url(path)
        n = s.use_frame(url, path, "ASSET-1", b"saved placement")(
            {"Displays": {"1": video, "2": older, "3": current, "4": users, "5": apple}})
        self.assertEqual(n, 2)
        for d in (video, older):
            self.assertEqual(self.choices(d), [s.image_choice(url)])
        # the placement saved for frames comes back when leaving the video, other desktops keep theirs
        self.assertEqual(video["Desktop"]["Content"]["EncodedOptionValues"], b"saved placement")
        self.assertEqual(older["Desktop"]["Content"]["EncodedOptionValues"], b"placement")
        # already on the current frame, the user's own wallpaper and Apple's aerials: untouched
        self.assertEqual(self.choices(current), [self.frame("Wallper - current A.png")])
        self.assertEqual(self.choices(users), [self.user_image()])
        self.assertEqual(self.choices(apple), [s.aerial_choice("APPLE-AERIAL")])

    def test_wallpaper_store_is_rewritten_only_when_something_changes(self):
        s = self.sync
        index = Path(self.home) / "Index.plist"
        s.INDEX = str(index)
        users = self.desktop(self.user_image())
        store = {"Displays": {"1": self.desktop(self.frame("Wallper - current A.png")), "2": users}, "Keep": [1, "two"]}
        with open(index, "wb") as f:
            plistlib.dump(store, f, fmt=plistlib.FMT_BINARY)
        self.assertEqual(s.edit_index(s.use_lock_screen_video("ASSET-1", None, {})), 1)
        after = index.read_bytes()
        d = plistlib.loads(after)
        self.assertEqual(d["Displays"]["1"]["Desktop"]["Content"]["Choices"], [s.aerial_choice("ASSET-1")])
        self.assertEqual(d["Displays"]["2"], users)
        self.assertEqual(d["Keep"], [1, "two"])
        # nothing left to change: same file, no temporary file left behind
        self.assertEqual(s.edit_index(s.use_lock_screen_video("ASSET-1", None, {})), 0)
        self.assertEqual(index.read_bytes(), after)
        self.assertEqual(sorted(p.name for p in Path(self.home).iterdir() if p.suffix == ".plist" or "tmp" in p.name),
                         ["Index.plist"])


if __name__ == "__main__":
    unittest.main()
