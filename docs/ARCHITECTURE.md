# Architecture and tradeoffs

## Product invariant

Saving user intent is independent of enriching it. A bookmark is durable before optional metadata work starts.
Network errors never convert a successful local save into a failed save.

## Boundaries

- **PocketQueueCore:** models, URL validation, repository protocol, SQLite implementation, metadata client/parser,
  and an observable main-actor library model. Built with SwiftPM on macOS and linked into iOS targets.
- **App:** SwiftUI presentation, SafariServices browser, thumbnail loading, and composition.
- **Shared:** App Group configuration and database location, not user-interface or networking state.
- **ShareExtension:** UIKit lifecycle hosting SwiftUI. Reads a shared URL and commits it directly.
- **WidgetExtension:** async App Intent timeline provider reading the same repository; never fetches webpage metadata.

Dependencies are passed through initializers. There is no global service locator or third-party DI framework.

## Why SwiftUI and a view model?

SwiftUI describes the current state; `@Observable @MainActor LibraryModel` owns loading, filtering, and user-facing errors.
Domain/storage/network behavior remains independently testable. UIKit is used where platform APIs require it:
the share-extension controller and Safari browser. There is no reason to duplicate the library UI in UIKit.

## Why SQLite instead of SwiftData?

For this project, explicit short transactions and cross-process writes are the interesting requirements.
The app and share extension can save simultaneously. WAL, a busy timeout, unique URL constraint, and `BEGIN IMMEDIATE`
provide coordination that a Swift actor alone cannot provide across processes.

The cost is a small C API wrapper and explicit schema management. SwiftData/Core Data would be reasonable alternatives,
especially for richer relational queries and UI-driven model observation.

Schema version 1 stores stable indexed identity/URL columns plus a Codable payload. Updates re-read the latest payload
inside a transaction, apply only the requested change, and commit. Late metadata cannot overwrite notes or recreate a
deleted row. Future schema versions are rejected explicitly; corrupt data is never silently erased.

Current operations decode the collection to find matching records. This is intentionally simple for a small personal
library. At larger sizes, add indexed per-ID/URL lookups, SQL pagination, a normalized tag table, and SQLite FTS.
Do not claim this implementation is optimized for hundreds of thousands of bookmarks.

## Concurrency and lifecycle

- UI state is main-actor isolated.
- Repository operations are actor-isolated. Each short-lived SQLite connection stays within synchronous actor work.
- Each process has its own actor; SQLite, not the actor, coordinates the processes.
- Metadata enrichment uses a structured task group with at most three active operations.
- SwiftUI owns the refresh task. A new refresh/scene transition cancels its predecessor.
- A cancellation does not mark the bookmark as permanently failed; pending work can resume on the next active launch.
- Deletion during enrichment is expected: the late result is discarded, not reinserted.
- The library reloads on foreground entry so extension writes become visible.
- The refresh task belongs to the navigation stack, not its root list. A cold widget deep link must load data even
  when the detail screen immediately replaces that list. A UI regression test covers this lifecycle boundary.
- Widget refresh requests are hints; timeline scheduling is owned by iOS.

No background polling, detached synchronization worker, or promise of continuous execution is involved.

## Preview networking

URLs may be HTTP or HTTPS bookmarks, but automatic previews require HTTPS. App Transport Security is not disabled.
Requests use an ephemeral session without browsing cookies and have a 15-second timeout.
Responses must be successful HTML/XHTML and no larger than 512 KiB. No scripts are executed.

The parser extracts title/Open Graph hints; it is not a universal HTML parser. Unsupported encodings or missing titles
produce a visible failure with manual retry. It does not bypass authentication, paywalls, or website restrictions.

Images are optional, HTTPS-only, capped at 2 MiB per response, and downsampled to 240 pixels.
The memory cache is bounded. A placeholder is normal when an image is unavailable, with a privacy-safe diagnostic log.
Optional URLCache entries are not a guarantee of permanent offline image availability.

## State and source of truth

SQLite is the source of truth for saved URLs, notes, tags, flags, and preview metadata.
The view model is a projection, not a second persistent store. Filtering/search are local and synchronous for the small
in-memory collection: no debounce is needed because there is no remote search request to throttle.

Writes update disk first, then reload the UI. This avoids optimistic rollback complexity for inexpensive local writes.
Duplicate links retain the original bookmark and notes; they do not unexpectedly overwrite user content.

## Failure policy

| Failure | Behavior |
|---|---|
| Invalid URL | Inline form error; input remains available |
| SQLite write failure | Explicit error; never claim the bookmark was saved |
| Preview timeout/offline | Bookmark stays saved; status and retry available |
| Failed optional thumbnail | Placeholder and privacy-safe diagnostic log |
| Cancelled metadata fetch | Pending item remains eligible on the next refresh |
| Deleted during fetch | Late result discarded |
| Unsupported schema/corruption | Explicit error; no destructive recovery |
| Broken App Group | Setup error; no separate hidden fallback database |
| Widget cannot read data | Unavailable state, not a fabricated healthy/empty library |

## Security and privacy

No credentials are required, so adding Keychain code would be artificial. Embedded credentials in bookmark URLs are rejected.
No URLs, notes, page contents, or tokens are written to diagnostic logs.

The shared library directory uses complete-until-first-user-authentication file protection on iOS, allowing extensions
to access it after the first unlock. A stricter locked-device policy would trade widget availability for stronger protection.
The widget marks its content privacy-sensitive. Review this policy if adding more sensitive user content.

There is no backend proxy, so there is no server-side URL-fetching/SSRF surface. Saved websites and their image providers
still receive direct device requests; users should not treat preview fetching as anonymous.

## Why no GraphQL or login?

They are not needed for a single-device local-first product. Adding them only to name technologies would expand risk
without improving the core experience.

A future sync release needs a separate design: account identity, server authorization, durable outbox, operation IDs,
conflict resolution, tombstones, account-switch cache isolation, and secure token storage.
GraphQL could then expose the library graph, but a normalized GraphQL cache would not replace the durable offline outbox.

## Useful interview demonstrations

1. Save a link with metadata networking failing; show it survives relaunch.
2. Explain why an actor does not coordinate two extension/app processes, then show the concurrent-writer test.
3. Edit notes while enrichment finishes; show that metadata only updates its own fields.
4. Explain the standalone free-signing target and why App Group failure must not silently split the library.
5. Profile thumbnail scrolling with Instruments; report measured results, not theoretical performance claims.
