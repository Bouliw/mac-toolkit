// ==UserScript==
// @name         Auto PiP
// @description  Puts the playing video in picture-in-picture when you leave the tab or the desktop, and brings it back into the page as soon as you return. Does nothing in full screen, around a full-screen switch, or while the video plays on an AirPlay device.
// @version      1.4
// @match        *://*/*
// @run-at       document-start
// @inject-into  content
// ==/UserScript==

(() => {
  "use strict";

  const FULLSCREEN_GUARD_MS = 2500; // everything is ignored for this long around a full-screen switch
  let lastFullscreen = 0;
  let videoInPip = null;            // the video THIS script put in picture-in-picture

  const markFullscreen = () => { lastFullscreen = Date.now(); };
  const inFullscreen = () =>
    !!(document.fullscreenElement || document.webkitFullscreenElement || document.webkitIsFullScreen);
  const recentFullscreen = () => Date.now() - lastFullscreen < FULLSCREEN_GUARD_MS;

  // Everything that announces a full-screen switch: state change, F key, double-click on the video
  ["fullscreenchange", "webkitfullscreenchange"].forEach((e) =>
    document.addEventListener(e, markFullscreen, true));
  document.addEventListener("keydown", (e) => {
    const t = e.target;
    const typing = t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName));
    if (!typing && (e.key === "f" || e.key === "F" || e.key === "Escape")) markFullscreen();
  }, true);
  document.addEventListener("dblclick", markFullscreen, true);

  // a video sent to an AirPlay device (TV) keeps playing there: no picture-in-picture for it
  const onAirPlay = (v) => !!v.webkitCurrentPlaybackTargetIsWireless;

  function playingVideo() {
    const videos = [...document.querySelectorAll("video")].filter(
      (v) => !v.paused && !v.ended && v.readyState > 2 && v.duration > 0 && !onAirPlay(v)
    );
    videos.sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight);
    return videos[0] || null;
  }

  // Before going into picture-in-picture, the video is moved to the bottom-right corner of the page:
  // the macOS animation starts from where the video is, so it has almost no distance to travel.
  function moveToCorner(v) {
    const before = v.getAttribute("style");
    v.style.setProperty("position", "fixed", "important");
    v.style.setProperty("left", "auto", "important");
    v.style.setProperty("top", "auto", "important");
    v.style.setProperty("right", "16px", "important");
    v.style.setProperty("bottom", "16px", "important");
    v.style.setProperty("width", "320px", "important");
    v.style.setProperty("height", "180px", "important");
    v.style.setProperty("z-index", "2147483647", "important");
    v.getBoundingClientRect(); // force the new layout
    let restored = false;
    const restore = () => {
      if (restored) return; restored = true;
      if (before === null) v.removeAttribute("style"); else v.setAttribute("style", before);
    };
    v.addEventListener("webkitpresentationmodechanged", () => setTimeout(restore, 50), { once: true });
    setTimeout(restore, 1500);
  }

  function enterPip(v) {
    try {
      moveToCorner(v);
      if (v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode("picture-in-picture")) {
        if (v.webkitPresentationMode !== "picture-in-picture") v.webkitSetPresentationMode("picture-in-picture");
      } else if (document.pictureInPictureEnabled && document.pictureInPictureElement !== v) {
        v.requestPictureInPicture().catch(() => {});
      }
      videoInPip = v;
    } catch (_) {}
  }

  function exitPip() {
    const v = videoInPip;
    videoInPip = null;
    if (!v) return;
    try {
      if (v.webkitPresentationMode === "picture-in-picture") v.webkitSetPresentationMode("inline");
      else if (document.pictureInPictureElement === v) document.exitPictureInPicture().catch(() => {});
    } catch (_) {}
  }

  document.addEventListener("visibilitychange", () => {
    if (document.hidden) {
      if (inFullscreen() || recentFullscreen()) return;
      const v = playingVideo();
      if (v) enterPip(v);
    } else {
      exitPip(); // back right away, without waiting for the window to get focus
    }
  }, true);

  // If you close or bring back the player yourself, the script forgets it; native full screen counts too
  document.addEventListener("webkitpresentationmodechanged", (e) => {
    const v = e.target;
    if (v.webkitPresentationMode === "fullscreen") markFullscreen();
    if (v === videoInPip && v.webkitPresentationMode === "inline") videoInPip = null;
  }, true);

  // AirPlay started while the video is in picture-in-picture: put it back in the page
  document.addEventListener("webkitcurrentplaybacktargetiswirelesschanged", (e) => {
    if (e.target === videoInPip && onAirPlay(e.target)) exitPip();
  }, true);
})();
