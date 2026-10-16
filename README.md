# Offline Player (clean-room rebuild) — setup

Target: iOS 17+, Xcode 15+, Swift 5 language mode. Written without access to Xcode, so expect a few small compile fixes.

## 1. Project
1. Xcode > New > iOS App (SwiftUI). Name it what you want shown in Files (this becomes the folder name).
2. Delete the template `ContentView.swift`/App file, add all `.swift` files from this folder.
3. File > Add Package Dependencies > `https://github.com/httpswift/swifter` (product: Swifter).
4. Put your logo in `Assets.xcassets/AppIcon`. **Files shows the app icon on the app's folder automatically**; there is no other key or setting for a custom folder icon.

## 2. Info.plist (Target > Info > "Custom iOS Target Properties", or edit the source)
```xml
<key>CFBundleDisplayName</key><string>Offline Player</string>

<!-- Expose Documents/ in the Files app (On My iPhone > Offline Player) -->
<key>UIFileSharingEnabled</key><true/>
<key>LSSupportsOpeningDocumentsInPlace</key><true/>

<!-- Background audio, lock-screen controls and Picture-in-Picture -->
<key>UIBackgroundModes</key>
<array><string>audio</string></array>

<!-- Wi-Fi transfer server -->
<key>NSLocalNetworkUsageDescription</key>
<string>Used to receive files from your computer over Wi-Fi.</string>
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsLocalNetworking</key><true/>
  <key>NSAllowsArbitraryLoadsInWebContent</key><true/>
</dict>
```
The five subfolders are created at launch (`FileService.bootstrap()`), so the folder is visible in Files immediately. Photo picking uses PHPicker, so no photo permission string is needed.

## 3. What each file does
| File | Role |
|---|---|
| `OfflinePlayerApp.swift` | Entry point, SwiftData models (playlists, download history) |
| `FileService.swift` | Folder paths, unique names, rename/move/delete, sorting, import |
| `Browser.swift` | WKWebView, JS hook (`ended` event + long-press image), `DownloadManager` |
| `Player.swift` | `MediaPlayerManager` (AVQueuePlayer, background audio, lock screen, loop) + player UI |
| `WiFiServer.swift` | Swifter upload page for desktop-to-phone transfer |
| `Views.swift` | Tabs, Files browser with QuickLook, playlists, settings |

## 4. Limits you should know about
- **Auto-download works for direct file URLs** (a `<video src="https://…/file.mp4">`, podcasts, your own server, open-licensed media). Most big streaming sites (YouTube included) play through `blob:` MediaSource streams, DRM, or signed segmented URLs. The hook reports those as "can't save" and does not try to get around them.
- Apple's App Store guideline 5.2.3 forbids apps that download media from third-party services without authorization. If you plan to publish, keep the downloader to content you have the rights to, or ship without it.
- Downloads use `URLSession` with a ~30 s background grace period. For large files in the background, switch to `URLSessionConfiguration.background` and implement `handleEventsForBackgroundURLSession`.
- PiP: tap the PiP button in the video controls, then leave the player; it also starts automatically when the app goes to the background. In-app PiP is not triggered by switching tabs.
- Swifter holds each upload in RAM. For multi-GB files use GCDWebServer.
