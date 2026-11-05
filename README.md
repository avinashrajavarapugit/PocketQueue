# PocketQueue

[![iOS CI](https://github.com/avinashrajavarapugit/PocketQueue/actions/workflows/ci.yml/badge.svg)](https://github.com/avinashrajavarapugit/PocketQueue/actions/workflows/ci.yml)

**Good things, for later.** A native, local-first iOS reading queue for links worth revisiting.

Save articles, videos, documentation, and references. Add a note about why they matter.
Come back when you have time. Use it without an account, or opt into secure cross-device sync.
No ads or analytics.

<p>
  <img src="docs/images/library.png" width="300" alt="PocketQueue library in light mode">
  <img src="docs/images/library-dark.png" width="300" alt="PocketQueue library in dark mode">
</p>

Screenshots show public sample links. A fresh installation starts with an empty library.

## Demo

**[Watch the screen recording (MP4, 46 seconds, 1.8 MB)](docs/demo/pocketqueue-demo.mp4)**

The demo saves public Swift and Apple links with notes and tags, searches the library, favorites a bookmark,
marks it read, and relaunches the app to show persisted state. Recorded in iPhone Simulator with live website
previews; setup footage is trimmed. The video is silent and contains no personal browsing data.

## The important detail

**Saving a link does not depend on the website responding.**

PocketQueue commits the URL, notes, and tags to a local SQLite transaction first. It fetches optional title
and image metadata afterward. A timeout, unsupported website, or app interruption cannot undo a completed save.

## Features

- SwiftUI library with queue, favorites, read, and all filters.
- Local search across titles, URLs, tags, and notes.
- Add, edit notes/tags, favorite, mark read/unread, share, and delete with confirmation.
- Share extension: save a link from Safari without a network request.
- Read next widget with a deep link into the corresponding bookmark.
- Best-effort HTTPS previews, bounded responses, cancellation, and explicit retry.
- Offline URLs, titles, tags, and notes. **Not an offline full-article downloader.**
- Downsampled optional thumbnails with bounded memory/network usage.
- A standalone build for free personal-device signing, without App Groups or extensions.
- Swift 6 concurrency checking, an independently testable Swift package, and simulator CI.
- Optional Supabase email accounts, verification/password-recovery callbacks, and device-only Keychain sessions.
- GraphQL queries and idempotent compare-and-swap mutations protected by server-side ownership policies.
- Durable offline changes, deletion tombstones, and explicit device/cloud conflict resolution.
- Account-scoped caches; guest bookmarks are uploaded only after an explicit copy action.
- Same-account reauthentication and corrupt-session recovery that preserve queued changes.
- In-app account deletion with password reauthentication and a server-side recent-session check.

## Run it

Requirements: a Mac, Xcode 16.4 or newer (Swift 6.1+), and an iOS 17+ simulator/device.
The checked-in Xcode project can be opened without installing XcodeGen.

```sh
git clone https://github.com/avinashrajavarapugit/PocketQueue.git
cd PocketQueue
open PocketQueue.xcodeproj
```

### Simulator: complete app

Choose **PocketQueue**, select an iPhone simulator, and run. The app embeds the share and widget extensions.
No paid Apple Developer membership or privileged backend credentials are needed.

### Use cloud sync

Open **Settings > Account & sync**. Create an account, confirm its email, and sign in.
PocketQueue app accounts are separate from the Supabase dashboard/CLI account used to administer the project.
Signing in opens a separate account library; it does not silently upload your existing bookmarks.
Use **Copy on-device bookmarks to cloud** if you want to copy them.

Local saves work without connectivity. Sync runs while the app is active after edits, on foreground entry,
on connectivity recovery, and from **Sync now**. Conflicting edits stay available until you choose a version.
Use **Sign in again** to refresh an expired session without deleting queued changes.

The included [client configuration](Config/Backend.json) contains only a public project URL and publishable key.
These are intentionally distributable identifiers, **not** administrator credentials. Authorization is enforced by
the hosted database. Never put `service_role` or `sb_secret_` keys in the app.

**Email delivery:** Supabase's default mailer is limited and may only deliver to authorized organization addresses.
For general public signups/password resets, configure your own SMTP provider in Supabase. Do not disable email
confirmation to work around delivery limits. See [backend setup](docs/BACKEND.md).

### Your iPhone: free standalone build

1. Select **PocketQueueLocal**.
2. In Signing & Capabilities, select your Personal Team.
3. If necessary, change that target's bundle identifier to a unique identifier.
4. Connect your iPhone, enable Developer Mode if prompted, and run.

This variant intentionally uses its own app container and excludes extensions. It does not silently fall back
from broken shared storage. Free Personal Team provisioning expires periodically (normally seven days).

### Your iPhone: share extension + widget

Use the **PocketQueue** scheme with a team supporting App Groups:

1. Set unique bundle identifiers for the app, share extension, and widget.
2. Register one App Group and set `APP_GROUP_IDENTIFIER` consistently for all three targets.
3. Select your development team for all three targets.
4. Run on your device. In Safari's Share sheet, choose **PocketQueue** (or **Save to PocketQueue**), under More if needed.
5. Add the **Read next** widget from the Home Screen widget gallery.

Prefer editing [project.yml](project.yml) and regenerating rather than maintaining divergent project settings.
App Store/TestFlight distribution normally requires paid Apple Developer Program membership.
This repository is not an App Store deployment.

## Build and test

```sh
# Fast domain, storage, metadata networking, and state tests, with no simulator:
xcrun swift test --parallel

# If changing project configuration:
brew install xcodegen swiftlint
xcodegen generate
swiftlint lint --strict

# Discover a destination instead of assuming a simulator model:
xcrun simctl list devices available
xcodebuild test \
  -project PocketQueue.xcodeproj \
  -scheme PocketQueue \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_UDID' \
  -derivedDataPath build/DerivedData \
  -resultBundlePath build/TestResults.xcresult \
  -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY=-
```

Ad-hoc simulator signing (`-`) needs no paid account and preserves the App Group entitlements.
Do not disable signing for the full app's cross-process tests: unsigned simulator builds cannot reliably access App Groups.

If a custom XcodeGen installation reports missing base settings, use a complete official installation
(for example, Homebrew's `xcodegen`). The generator requires its bundled settings presets.

### What the tests cover

- URL validation and canonicalization without dropping meaningful queries/fragments.
- Durable saves across independently opened connections.
- Concurrent writers and duplicate-save idempotency.
- Metadata updates preserving notes and never resurrecting deleted bookmarks.
- Invalid/future database schemas failing explicitly instead of resetting user data.
- HTTP errors, MIME validation, response limits, and cancellation.
- Save-before-fetch, retry, filters, search, duplicates, and storage failure UI state.
- Automated UI flows for save, read/favorite, relaunch, search, failed preview, editing, validation, and deletion.
- A real share-sheet integration test that saves in the extension and verifies the main app's shared library.
- Cold-launch widget deep-link navigation and accessibility-size text layouts.
- Actual Home Screen widget installation, rendered bookmark content, and tap-through after terminating the app.
- Bounded recovery from simultaneous first-open SQLite journal initialization.
- Schema-v1 migration, account isolation, durable outbox, late acknowledgements, tombstones, and conflict resolution.
- Keychain/PKCE storage, refresh coalescing, recovery, and local/remote sign-out outcomes.
- Hosted two-user authorization tests and a native Swift two-device sync test, run explicitly with ephemeral fixtures.

Network tests use `URLProtocol` fixtures. Ordinary UI tests use an isolated database and explicitly injected fake metadata.
System sharing, Home Screen widget, and Safari deep-link tests use the real shared library with synthetic `.example` links.
The Safari test terminates the app, opens its custom URL through the system, and verifies the exact saved bookmark.
Normal app launches use the real website-preview client. Test hooks are excluded from Release builds.
The hosted Swift and iOS tests are opt-in: ordinary CI never needs production credentials.
CI also starts a disposable local Supabase stack and tests the actual SQL, Auth, and GraphQL contract.

## Architecture and interview walkthrough

See [Architecture](docs/ARCHITECTURE.md) for boundaries, tradeoffs, failure behavior, and sync decisions.
See [Backend setup](docs/BACKEND.md) for deployment, email delivery, and live verification.
See [Validation](docs/VALIDATION.md) for reproducible checks and the manual extension/widget checklist.
See [Privacy](docs/PRIVACY.md) for data handling.

```text
SwiftUI views -> @MainActor LibraryModel -> BookmarkStoring
                                          |
                                          v
                                    SQLite actor
                                          ^
                                          |
Share extension -------------------------+
Widget ---------------------------------+

LibraryModel -> MetadataFetching -> URLSession -> saved website
CloudAccountModel -> Supabase Auth SDK -> Keychain + Auth REST API
SQLite outbox -> GraphQL client -> owner-scoped Postgres + operation receipts
```

The app, share extension, and widget use the same local Swift package. Authentication uses the official
Supabase Swift SDK's **Auth** product, not the entire Supabase client. Compatible transitive versions are pinned
to keep Xcode 16.4 / Swift 6.1 builds reproducible; the pin-only dependencies can produce SwiftPM
unused-direct-dependency warnings. They do not add additional runtime features.

## Deliberate limits

- No AI summarization, arbitrary HTML rendering, full-text article extraction, or collaborative/shared accounts.
- Preview extraction is best effort for bounded UTF-8 HTML with title/Open Graph metadata.
- Website and image requests reveal your IP address to their servers.
- Cached thumbnails may be evicted; offline metadata/notes do not depend on those images.
- Widgets are scheduled by iOS, not guaranteed to refresh immediately.
- The library targets personal collections, not a million-item database. Current filtering decodes the small collection.
- Sync uses paginated full reconciliation, not subscriptions or a background service. New records inserted before
  an in-progress cursor are picked up on a subsequent sync.
- Deletion tombstones and mutation receipts remain until account deletion; monitor storage before scaling.
- Free hosting has quotas, inactivity pausing, and email delivery limits. It is not an uptime guarantee.
- No claim of production scale, real-user monitoring, or completed App Store release.

## Contributing

Use a small branch and a focused pull request. Explain the behavior change and tradeoffs; add tests for regressions.
CI lints, runs the package tests, builds/tests the app and extensions, and builds the standalone variant.
Keep screenshots/test artifacts free of personal URLs and credentials.

AI assisted initial implementation. The repository includes executable validation rather than treating generated code as proof
of correctness. Further changes should undergo the same review and testing.

## License

[MIT](LICENSE)
