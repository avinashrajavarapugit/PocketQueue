# Privacy

PocketQueue has no advertising or analytics SDK. Accounts and Supabase-backed cloud sync are optional.

## Stored on your device

- Saved URL, title, thumbnail URL, creation date.
- Notes, tags, read/favorite status, preview status, queued cloud changes, and conflict snapshots.
- Optional image caches managed by the operating system.
- Account session tokens and PKCE state in device-only Keychain storage, not UserDefaults or the shared database.

The full build shares its library only with its own share/widget extensions through an App Group.
The standalone build has a separate app container. Normal device backups may include the application data.

## Optional cloud storage

Signing in opens a separate account library. Existing on-device bookmarks are not uploaded unless you choose
**Copy on-device bookmarks to cloud**. Cloud records contain saved URLs, titles, notes, tags, flags, and preview
metadata, linked to your Supabase user ID. Supabase Auth processes your email address and password for authentication.
The app does not save your password.

RLS restricts reads to the authenticated owner. Revision-checked server functions handle writes. Mutation receipts
and deletion tombstones are retained to support safe retries and offline synchronization.
Supabase may retain infrastructure/security logs such as IP addresses and authentication events.
The included development project is hosted in Sydney; a fork can configure a different project/region.

## Network requests

When the main app fetches a preview, it contacts the saved website. Loading a thumbnail can contact another image host.
Those providers receive normal network information such as your IP address and requested URL.
Preview requests do not send your Safari cookies. Opening the original page uses Apple's SafariServices browser.

Saving through the share extension does not perform preview networking.
If an account is active, it queues the bookmark for upload by the main app. The widget only reads the local cache.
Full articles and videos are not downloaded or republished.

## Diagnostics

Local OSLog messages identify operation categories but do not record saved URLs, notes, or page bodies.
There is no remote telemetry or crash-upload service operated by this project.
If sharing a diagnostic report, review it for personal information first.

## Deletion

Delete individual bookmarks from their detail screen. SQLite deletion is logical deletion, not a promise of forensic
secure erasure; journals, device backups, and caches can retain historical bytes.
Uninstalling the app and associated extensions removes their containers according to iOS behavior.

Cloud bookmark deletion retains a tombstone for other devices. **Delete account permanently** removes the Auth account,
its cloud bookmarks, and its operation receipts, and clears the active account's local cache after success.
The original, separate guest library is kept. Explicit sign-out also removes the current account's local cache,
including unsent changes, after a warning.

**Reset sign-in and keep queued changes** is different: it clears credentials but retains isolated account cache/outbox
data until you sign back into that account. This avoids data loss when credentials are corrupt or expire.
Keychain items can outlive app uninstall; use in-app sign-out or deletion when possible.
System widget snapshots can persist until iOS refreshes them.

The privacy manifest declares email address, user ID, and other user content for app functionality, linked to the user,
with no tracking. Review final App Store privacy answers, provider retention, email delivery, and legal notices before
public distribution. These project notes are not a legal compliance certification.
