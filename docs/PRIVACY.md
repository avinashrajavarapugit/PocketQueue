# Privacy

PocketQueue has no account system, advertising SDK, analytics SDK, or developer-operated backend.

## Stored on your device

- Saved URL, title, thumbnail URL, creation date.
- Notes, tags, read/favorite status, and preview status.
- Optional image caches managed by the operating system.

The full build shares its library only with its own share/widget extensions through an App Group.
The standalone build has a separate local library. Normal device backups may include the application data;
PocketQueue does not provide an independent cloud-sync service.

## Network requests

When the main app fetches a preview, it contacts the saved website. Loading a thumbnail can contact another image host.
Those providers receive normal network information such as your IP address and requested URL.
Preview requests do not send your Safari cookies. Opening the original page uses Apple's SafariServices browser.

Saving through the share extension does not perform preview networking.
Full articles and videos are not downloaded or republished.

## Diagnostics

Local OSLog messages identify operation categories but do not record saved URLs, notes, or page bodies.
There is no remote telemetry or crash-upload service operated by this project.
If sharing a diagnostic report, review it for personal information first.

## Deletion

Delete individual bookmarks from their detail screen. SQLite deletion is logical deletion, not a promise of forensic
secure erasure; journals, device backups, and caches can retain historical bytes.
Uninstalling the app and associated extensions removes their containers according to iOS behavior.

The included privacy manifest declares no tracking or collected data. App Store privacy answers must be reassessed
if future versions add analytics, accounts, remote storage, or new required-reason APIs.
