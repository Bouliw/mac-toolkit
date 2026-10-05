#!/usr/bin/python3
# WallperSync: keeps the macOS system wallpaper (lock screen, Mission Control, desktop swipes,
# new desktops) in line with the live wallpaper playing in Wallper, whenever it changes.
# When Wallper's lock screen video is installed (macOS 26+), every desktop is pointed to it, so the
# lock screen stays animated and Mission Control shows the same video, paused.
# Otherwise a still frame of the video is used, saved in WALLPAPER_DIR (config),
# ~/Pictures/Wallpapers by default.
import base64
import datetime
import json
import os
import plistlib
import re
import subprocess
import sys
import time
import unicodedata
import urllib.parse

HOME = os.path.expanduser('~')
HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, 'wallper-frame')
STATE = os.path.join(HERE, 'state.json')
LOG = os.path.join(HOME, 'Library/Logs/mac-toolkit/wallper-sync.log')
CONFIG = os.path.join(HOME, '.config/mac-toolkit/config')
INDEX = os.path.join(HOME, 'Library/Application Support/com.apple.wallpaper/Store/Index.plist')
AERIALS = os.path.join(HOME, 'Library/Application Support/com.apple.wallpaper/aerials/videos')
IMAGE = 'com.apple.wallpaper.choice.image'
AERIAL = 'com.apple.wallpaper.choice.aerials'
# how long Wallper gets to prepare the lock screen video of a new wallpaper before a still frame is used
LOCK_SCREEN_WAIT = 300


def config_value(key, default):
    try:
        m = re.search(rf'^{key}="([^"]*)"', open(CONFIG).read(), re.M)
        if m and m.group(1):
            return os.path.expanduser(m.group(1).replace('$HOME', HOME))
    except OSError:
        pass
    return default


FOLDER = config_value('WALLPAPER_DIR', os.path.join(HOME, 'Pictures/Wallpapers'))
# desktop images that count as "the previous wallpaper" and get replaced everywhere
OLD_MARKERS = ['com.zhou.dynamicwallpaper', unicodedata.normalize('NFC', FOLDER + '/Wallper - ')]


def log(msg):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        if os.path.exists(LOG) and os.path.getsize(LOG) > 200_000:
            os.replace(LOG, LOG + '.1')
        with open(LOG, 'a') as f:
            f.write(time.strftime('%Y-%m-%d %H:%M:%S ') + msg + '\n')
    except Exception:
        pass


def wallper_prefs():
    out = subprocess.run(['/usr/bin/defaults', 'export', 'sandimax.Wallper', '-'], capture_output=True).stdout
    return plistlib.loads(out) if out else {}


def file_url(path):
    return 'file://' + urllib.parse.quote(unicodedata.normalize('NFD', path), safe="/'")


def path_from_url(u):
    p = urllib.parse.unquote(urllib.parse.urlparse(u).path)
    return unicodedata.normalize('NFC', p)


def lock_screen_asset(prefs, video):
    """Returns (asset ID of Wallper's lock screen video or None, whether it shows the current video)."""
    asset = prefs.get('ls27DesiredAssetID')
    if not isinstance(asset, str) or not asset or not os.path.exists(os.path.join(AERIALS, asset + '.mov')):
        return None, False
    installed = str(prefs.get('wallper.lockscreen.slot.installed') or
                    prefs.get('wallper.lockscreen.lastInstalledVideoID') or '').split('|')[0]
    current = os.path.splitext(os.path.basename(video))[0]
    return asset, installed.lower() == current.lower()


def configuration(choice):
    try:
        c = plistlib.loads(choice.get('Configuration'))
    except Exception:
        return {}
    return c if isinstance(c, dict) else {}


def is_old_image(choice, keep=None):
    c = configuration(choice)
    if choice.get('Provider') != IMAGE or c.get('type') != 'imageFile' or not isinstance(c.get('url'), dict):
        return False
    p = path_from_url(str(c['url'].get('relative', '')))
    return p != keep and any(x in p for x in OLD_MARKERS)


def is_asset(choice, asset):
    return bool(asset) and choice.get('Provider') == AERIAL and configuration(choice).get('assetID') == asset


def aerial_choice(asset):
    return {'Provider': AERIAL, 'Files': [],
            'Configuration': plistlib.dumps({'assetID': asset}, fmt=plistlib.FMT_BINARY)}


def image_choice(url):
    return {'Provider': IMAGE, 'Files': [],
            'Configuration': plistlib.dumps({'type': 'imageFile', 'url': {'relative': url}},
                                            fmt=plistlib.FMT_BINARY)}


def desktops(o):
    """Yields every desktop setting of the wallpaper store (displays, spaces and defaults)."""
    if isinstance(o, dict):
        for k, v in o.items():
            if k == 'Desktop' and isinstance(v, dict) and isinstance(v.get('Content'), dict):
                yield v
            else:
                yield from desktops(v)
    elif isinstance(o, list):
        for v in o:
            yield from desktops(v)


def use_lock_screen_video(asset, previous_asset, saved):
    """Points every desktop showing a frame, the old app's image or a previous asset to the lock screen video."""
    def change(d):
        n = 0
        for desk in desktops(d):
            choices = desk['Content'].get('Choices') or []
            if choices and all(is_old_image(c) or is_asset(c, previous_asset) for c in choices):
                options = desk['Content'].get('EncodedOptionValues')
                if isinstance(options, bytes) and 'image_options' not in saved:
                    saved['image_options'] = options  # placement of the frame, reused if frames come back
                desk['Content']['Choices'] = [aerial_choice(asset)]
                desk['Content']['EncodedOptionValues'] = '$null'
                desk['LastSet'] = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
                n += 1
        return n
    return change


def use_frame(url, path, asset, options):
    """Points every desktop showing an older frame, the old app's image or the lock screen video to the frame."""
    def change(d):
        n = 0
        for desk in desktops(d):
            choices = desk['Content'].get('Choices') or []
            if choices and all(is_old_image(c, path) or is_asset(c, asset) for c in choices):
                if any(c.get('Provider') == AERIAL for c in choices):
                    desk['Content']['EncodedOptionValues'] = options or '$null'
                desk['Content']['Choices'] = [image_choice(url)]
                n += 1
        return n
    return change


def edit_index(change):
    d = plistlib.load(open(INDEX, 'rb'))
    n = change(d)
    if n:
        tmp = INDEX + '.tmp-wallper-sync'
        with open(tmp, 'wb') as f:
            plistlib.dump(d, f, fmt=plistlib.FMT_BINARY)
        os.replace(tmp, INDEX)
    return n


def apply(change, restart=False):
    """Edits the wallpaper store, then restarts the agent so every desktop reloads it."""
    n = edit_index(change)
    if n or restart:
        subprocess.run(['/usr/bin/killall', 'WallpaperAgent'], capture_output=True)
        time.sleep(2)
        # if the agent wrote its old state back while quitting, go over it once more
        n2 = edit_index(change)
        if n2:
            subprocess.run(['/usr/bin/killall', 'WallpaperAgent'], capture_output=True)
            time.sleep(2)
        n += n2
    return n


def load_state():
    try:
        return json.load(open(STATE))
    except Exception:
        return {}


def save_state(state):
    json.dump(state, open(STATE, 'w'), ensure_ascii=False, indent=1)


def main():
    force = '--force' in sys.argv
    prefs = wallper_prefs()
    items = prefs.get('LastAppliedWallpapers') or []
    if not items:
        return
    item = sorted(items, key=lambda i: int(i.get('screenIndex', 0) or 0))[0]
    video = urllib.parse.unquote(urllib.parse.urlparse(str(item.get('url', ''))).path)
    if not video.lower().endswith(('.mp4', '.mov', '.m4v')) or not os.path.exists(video):
        return
    state = load_state()

    asset, ready = lock_screen_asset(prefs, video)
    if asset and not ready:
        if time.time() - float(item.get('appliedAt') or 0) < LOCK_SCREEN_WAIT:
            return  # Wallper is still preparing it and updates its settings when done, which runs this again
        asset = None

    if asset:
        mov = os.stat(os.path.join(AERIALS, asset + '.mov'))
        signature = f'lock screen|{asset}|{video}|{mov.st_size}|{int(mov.st_mtime)}'
        if not force and state.get('signature') == signature:
            return
        saved = {}
        previous = state.get('asset') if state.get('asset') != asset else None
        n = apply(use_lock_screen_video(asset, previous, saved))
        if 'image_options' in saved and 'image_options' not in state:
            state['image_options'] = base64.b64encode(saved['image_options']).decode()
        state.update(signature=signature, asset=asset, video=video, updated=time.strftime('%Y-%m-%d %H:%M:%S'))
        save_state(state)
        log(f'new wallpaper: {os.path.basename(video)} -> lock screen video {asset}, '
            f'{n} desktop settings updated')
        return

    st = os.stat(video)
    signature = f'frame|{video}|{st.st_size}|{int(st.st_mtime)}'
    if not force and state.get('signature') == signature and os.path.exists(state.get('image', '')):
        return
    # two alternating files, so macOS always sees a new path and refreshes the wallpaper
    slot = 'B' if state.get('slot') == 'A' else 'A'
    os.makedirs(FOLDER, exist_ok=True)
    image = os.path.join(FOLDER, f'Wallper - current {slot}.png')
    r = subprocess.run([TOOL, 'frame', video, image], capture_output=True, text=True)
    if r.returncode != 0:
        log('frame extraction failed: ' + r.stderr.strip())
        sys.exit(1)
    options = base64.b64decode(state['image_options']) if state.get('image_options') else None
    n = apply(use_frame(file_url(image), unicodedata.normalize('NFC', image), state.get('asset'), options),
              restart=True)
    s = subprocess.run([TOOL, 'set', image], capture_output=True, text=True)
    state.pop('asset', None)
    state.update(signature=signature, image=image, slot=slot, video=video,
                 updated=time.strftime('%Y-%m-%d %H:%M:%S'))
    save_state(state)
    log(f'new wallpaper: {os.path.basename(video)} -> {os.path.basename(image)} '
        f'({r.stdout.strip()}), {n} desktop settings updated, {s.stdout.strip()}')


if __name__ == '__main__':
    main()
