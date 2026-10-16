# Build on GitHub (free), install from your PC (free Apple ID)

## A. Build the .ipa in the cloud (no Mac, no Xcode)
1. Create a free GitHub account, then a new repository (public = free macOS build minutes).
2. Upload everything in this folder, **including the hidden `.github` folder** (drag the folders into
   "Add file > Upload files", or use `git push`). The repo root must contain `project.yml`, `Sources/`, `.github/`.
3. Repo > Actions > "Build unsigned IPA" > Run workflow. Takes ~5-10 min.
4. Open the finished run > Artifacts > download `OfflinePlayer-ipa` (a zip containing `OfflinePlayer.ipa`).
5. If the run fails, download the `build-log` artifact (or paste the red error lines) and send it to Claude.
   I have never compiled this code, so expect one or two rounds of fixes.

## B. Sign and install on your iPhone from your PC
1. Install **iTunes and iCloud from apple.com** (not the Microsoft Store versions), then **Sideloadly** (sideloadly.io).
2. iPhone: Settings > Privacy & Security > **Developer Mode** > On (restarts the phone).
3. Plug in the iPhone, open Sideloadly, drag in `OfflinePlayer.ipa`, enter your Apple ID, press Start.
   Tip: use a spare Apple ID with two-factor on, not your main one.
4. iPhone: Settings > General > VPN & Device Management > your Apple ID > **Trust**.

## Free-account limits
- The app stops opening after **7 days**; re-run Sideloadly (it also has an auto-refresh option while the PC is on).
- Max 3 sideloaded apps at once, and 10 new App IDs per week.
- Your data in the app's Documents folder survives a re-sign if you install over the same app and bundle ID.
