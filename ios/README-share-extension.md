# ZLinkShare — the share extension

`ZLinkShare` puts **ZLink** in the iOS share sheet: pick a connection → host → workspace →
thread (recent first, or *New thread*), add a comment, **Send**. Files are uploaded into the
workspace (`<workspace>/.zlink/uploads/YYYY-MM-DD/…`, `project.upload.begin/chunk/commit`) and
the message goes out with `thread.send` + `upload_refs`, exactly like the app's composer.
Shares larger than 10 MiB are handed to the app through the App Group container
(`Inbox/<id>/`); the app uploads and sends them the next time it is opened.

| | |
|---|---|
| Extension bundle id | `cx.m42.zlink.share` |
| App Group | `group.cx.m42.zlink` (app and extension) |
| Shared credential | the gateway token, in the keychain access group `group.cx.m42.zlink` (App Group ids are keychain access groups; no separate keychain-sharing entitlement) |
| Shared profiles | `UserDefaults(suiteName: "group.cx.m42.zlink")`, written by the app |
| Spec | `ios/project-share.yml` (includes `project.yml`) |
| Shared sources | `ZedLink/SharedSupport.swift`, `GatewayClient.swift`, `Models.swift`, `ProjectUploader.swift` |

## Two builds

* **Default** — `cd ios && xcodegen generate` (`project.yml`): the app alone, no App Group, no
  extension. The simulator workflows and the TestFlight lane use this whenever the secret
  `IOS_SHARE_PROFILE_BASE64` is absent, so the current TestFlight build keeps working with the
  six existing secrets. At runtime the app sees no App Group and keeps everything private.
* **With the extension** — `cd ios && xcodegen generate --spec project-share.yml`. The TestFlight
  lane switches to it when `IOS_SHARE_PROFILE_BASE64` is set. Bundle ids and profiles are per
  target and come from the xcodebuild command line
  (`ZLINK_APP_BUNDLE_ID`, `ZLINK_APP_PROFILE`, `ZLINK_SHARE_PROFILE`); `ios/ci/ios-ci-signing.py`
  checks both profiles (App ID, App Store type, certificate, App Group, Push for the app) and
  writes both into `ExportOptions.plist`.

## Manual Apple steps (only the account holder can do these)

Team `ZK66E83UL5`, on <https://developer.apple.com/account/resources>:

1. **Register the App Group.** Identifiers → **+** → *App Groups* → Continue.
   Description `ZLink shared`, identifier `group.cx.m42.zlink` → Register.
2. **Give the app the App Group.** Identifiers → App IDs → `cx.m42.zlink` → enable
   **App Groups** → *Configure* → tick `group.cx.m42.zlink` → Continue → **Save**
   (confirm the warning: existing profiles for this App ID must be regenerated).
   Keep Push Notifications enabled.
3. **Register the extension's App ID.** Identifiers → **+** → *App IDs* → *App* → Continue.
   Description `ZLink Lab Share`, Bundle ID **Explicit** `cx.m42.zlink.share`.
   Capabilities: **App Groups** only (no Push) → Continue → Register. Then open it, *App Groups*
   → *Configure* → tick `group.cx.m42.zlink` → Save.
4. **Regenerate the app's App Store profile.** Profiles → the App Store profile for
   `cx.m42.zlink` (the one in `IOS_PROFILE_BASE64`) → Edit → (same distribution certificate) →
   Save → Download. It must now list the App Group. Update the secret:
   `base64 -i <file>.mobileprovision | pbcopy` → repository *Settings → Secrets and variables →
   Actions* → `IOS_PROFILE_BASE64` → Update. (The new profile also signs the default build: the
   app only uses a subset of its entitlements.)
5. **Create the extension's App Store profile.** Profiles → **+** → *Distribution → App Store
   Connect* → App ID `cx.m42.zlink.share` → the same distribution certificate as the `.p12` in
   `IOS_DIST_CERT_P12_BASE64` → name it e.g. `ZLink Share App Store` → Generate → Download.
   Add it as a **new** secret: `base64 -i <file>.mobileprovision | pbcopy` →
   `IOS_SHARE_PROFILE_BASE64`.
6. Run **iOS TestFlight** (push to `ios/testflight` or *Run workflow*). The gate step logs
   “IOS_SHARE_PROFILE_BASE64 is set: building with the ZLinkShare extension and the App Group.”
   Nothing changes in App Store Connect: the extension ships inside the app's build.

To go back to the app-only build, delete `IOS_SHARE_PROFILE_BASE64`.

If `asc` is used instead of the web UI, the equivalent is registering the group and the second
bundle id, enabling the App Groups capability on both, and creating an App Store profile for
`cx.m42.zlink.share`; the CI checks the same things either way.

## After installing a build with the extension

Open ZLink Lab once: the app moves the gateway credential into the shared keychain group and
publishes the saved connections to the App Group on launch. Until then the extension says
“Open ZLink Lab and pair a connection first.” The extension needs a desktop Zed whose bridge
advertises `project.upload.begin` and `workspace.list`.

## Not verified here

This was written on Linux without Xcode or a Swift toolchain: neither target has been compiled,
signed or run. Check on the first CI run: the archive step (both targets), the export with two
profiles, the share sheet entry on a device, a share to an existing thread, a share to a new
thread in a closed workspace, and a >10 MiB hand-off.
