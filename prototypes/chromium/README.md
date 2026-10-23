# Vane Chromium Prototype

A standalone, experimental macOS app for evaluating Chromium under a native
SwiftUI sidebar. This does **not** change the WebKit engine in the normal Vane
app, migrate existing data, register a default browser, or publish a release.

## Build and try

Requires an Apple Silicon Mac, macOS 26+, Xcode 26+, CMake 3.21+, and Python
3.12+. From the repository root:

```sh
prototypes/chromium/build.sh
open "prototypes/chromium/.build/Vane Chromium Prototype.app"
```

The first build downloads the pinned 135 MB CEF SDK into
`~/Library/Caches/VaneChromiumPrototype`, verifies its SHA-256, and builds the C++
wrapper. CEF binaries are not committed. The app includes upstream licensing
and third-party credits in its Resources directory. The local build is ad-hoc
signed, with hardened-runtime exceptions for JIT and CEF's dynamic loading;
it is not a notarized distribution candidate. CEF's subprocess sandbox remains
enabled. Do not pass `--no-sandbox`.

Browsing data is separate at
`~/Library/Application Support/Vane Chromium Prototype`.
**Vane Chromium Prototype → Show Prototype Data…** opens this folder. A second
copy of the prototype using the same directory shares Chromium's process
singleton; use an absolute `--vane-profile=/path/to/a/disposable/directory`
argument for an independent test instance. Never point this at another browser's
profile or Vane's normal data folder.

## What the spike covers

- SwiftUI sidebar tabs alongside Chromium's full address/extension toolbar and page surface.
- Back, forward, reload, new/close/select tab, and address/search navigation.
- Chromium's extension manager and a link to the Chrome Web Store.
- An explicit **Playback Check** page for codec and DRM API availability.
- Separate test-profile site storage and extension storage.
- Brief sidebar transitions, respecting Reduce Motion, system Low Power Mode,
  and the prototype's own Battery Saver switch.

This is a subset of Vane's interface, not a port of Spaces, profiles, sync,
password storage, downloads UI, Boosts, Peek, Split View, or the updater. Tabs
are not restored after quitting. Closing tabs and quitting force-close their
pages, so unsaved page edits are not protected. Chromium may present popups and
some extension surfaces in separate runtime-managed windows.

## Why Chromium owns the window

The pinned CEF SDK explicitly falls back to Alloy style when a native macOS
parent view is supplied. That means replacing `WKWebView` with a Chromium
`NSView` does not test the full Chrome browser UI/runtime integration.

This prototype instead uses one Chrome-style `CefWindow` and `CefBrowserView`
per sidebar tab: CEF also rejects a second Chrome BrowserView in the same custom
window. Inactive tab windows are hidden; selecting a tab swaps the visible
window at the current window bounds. This has additional window/memory overhead
and needs a different production tab-ownership design before a full migration.
A transparent native SwiftUI overlay supplies the shared sidebar. Chromium's
own toolbar supplies address navigation and extension action buttons/popups;
the overlay passes pointer events through to that toolbar and the page. The bridge in
`Bridge.h` keeps CEF types out of Swift and WebKit out of this app. This window
ownership change is a material migration constraint, not a drop-in engine swap.

See the upstream [macOS window-info contract](https://github.com/chromiumembedded/cef/blob/master/include/internal/cef_types_mac.h)
and [CEF Views API](https://github.com/chromiumembedded/cef/tree/master/include/views).

## Verification

After building, run:

```sh
python3 prototypes/chromium/smoke.py
```

The test serves a loopback fixture, starts the actual native app with an unpacked
Manifest V3 extension and a disposable profile, and repeats the launch. It
requires the actual Chrome runtime style, a Chromium page, extension content
script injection, service-worker messaging, page/extension storage persistence,
and successful application shutdown. It records launch PIDs, start times and
bundle paths in `.build/test-launches.jsonl`, and cleans up only those test
processes. It does not read real browsing data or use password-manager accounts.

Manual acceptance checks before proposing a production migration:

1. Browse real HTTPS sites; create, switch and close several tabs; resize the
   window and check keyboard shortcuts and input in page forms.
2. Use **Extensions** to load an unpacked extension. Check Web Store installation,
   extension updates, action popups, shortcuts, host permissions and isolation.
3. Test 1Password and Bitwarden with dedicated test accounts: login save/fill,
   unlock, desktop-app/native messaging, and credential/passkey flows. Installing
   an extension alone does not establish password-manager compatibility.
4. Run **Playback Check**, then test authorized Netflix and Disney+ accounts:
   actual playback, decoded resolution, captions, seeking, fullscreen, PiP and
   sustained playback. Compare with current Vane and Safari.
5. Measure idle CPU, battery, memory and tab-switch latency on the same workloads.
   Establish engine update, signing/notarization and profile migration plans.

## Streaming boundary

This SDK is a stock CEF build. The prototype does not bundle Widevine or a
custom proprietary-codec build. The Playback Check reports the actual build's
capabilities; an accepted EME configuration alone is not successful protected
playback. Netflix/Disney+ compatibility, quality, DRM distribution eligibility,
and password-manager desktop integration remain separate acceptance gates.

Google documents a license agreement requirement for Widevine, including
[Chromium/CEF support](https://developers.google.com/widevine/drm/overview).
Chromium also does not automatically bring Google account browser sync or
Google Password Manager integration.

## Pinned dependency

- CEF `156.0.7+g47dbc1d+chromium-156.0.8078.17`, macOS ARM64 minimal distribution.
- Official archive SHA-1: `038a6ce70a814181f6a507d40155c81e80b328e3`.
- SHA-256 verified by `fetch-cef.py`:
  `d9a4e98dfde499bfecc49ec2290395fbfffc3923fed5f967bb95c6e05e03e903`.
- Source: [CEF automated builds](https://cef-builds.spotifycdn.com/index.html).

Keep this pin current if the prototype is used for ongoing browsing. Production
adoption requires promptly shipping Chromium security updates.
