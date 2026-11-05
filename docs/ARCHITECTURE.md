# Architecture and tradeoffs

## Product invariant

Saving user intent is independent of enriching it. A bookmark is durable before optional metadata work starts.
Network errors never convert a successful local save into a failed save.

## Boundaries

- **PocketQueueCore:** models, URL validation, repository protocol, SQLite implementation, metadata client/parser,
  library/account state models, Auth SDK adapter, GraphQL client, and sync engine. Built with SwiftPM and linked into iOS targets.
- **App:** SwiftUI presentation, SafariServices browser, thumbnail loading, and composition.
- **Shared:** App Group configuration, database location, and active-account store selection; never authentication tokens.
- **ShareExtension:** UIKit lifecycle hosting SwiftUI. Reads a shared URL and commits it directly.
- **WidgetExtension:** async App Intent timeline provider reading the active account's cache; never authenticates or syncs.
- **Supabase:** Auth, a typed Postgres bookmark table, RLS, and a GraphQL mutation backed by an atomic SQL function.

Dependencies are passed through initializers. There is no global service locator or third-party DI framework.

## Why SwiftUI and a view model?

SwiftUI describes the current state; `@Observable @MainActor LibraryModel` owns loading, filtering, and user-facing errors.
Domain/storage/network behavior remains independently testable. UIKit is used where platform APIs require it:
the share-extension controller and Safari browser. There is no reason to duplicate the library UI in UIKit.

## Why SQLite instead of SwiftData?

For this project, explicit short transactions and cross-process writes are the interesting requirements.
The app and share extension can save simultaneously. WAL, a busy timeout, unique URL constraint, and `BEGIN IMMEDIATE`
provide coordination that a Swift actor alone cannot provide across processes.
The synchronous transaction API inherits its caller's actor isolation; the mutable connection is not declared Sendable.
Transaction closures capture immutable account IDs rather than the owning actor, and verify the active account inside the transaction.

Simultaneous first opens can make `PRAGMA journal_mode=WAL` return `SQLITE_BUSY` without waiting for SQLite's
normal busy handler. Initialization retries only that idempotent operation, with a three-second monotonic deadline
and short waits. Other failures surface immediately; user mutations are not blindly replayed. A regression test
holds an exclusive lock, verifies the bounded failure, then checks that saving recovers without erasing existing data.

The cost is a small C API wrapper and explicit schema management. SwiftData/Core Data would be reasonable alternatives,
especially for richer relational queries and UI-driven model observation.

Schema version 2 preserves the original guest table and adds owner-scoped cloud records, an outbox, conflict snapshots,
and an active-account marker. Each local edit and its outbox record commit in the same transaction. Store instances
bind to one account; each transaction verifies that it is still active, so a stale share sheet or late response cannot
write into another account. Future schema versions are rejected; corrupt data is never silently erased.

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
- The root retains incoming bookmark links while authentication/cache restoration runs. Widget links carry the
  account scope; a stale widget cannot open a same-ID bookmark in another account or in the guest library.
- Sync is foreground-only, serialized, cancellable, and retriggered after local edits or connectivity recovery.
- Old account tasks cannot update new account UI state; store-level scope checks also reject stale writes.
- Token refresh is coalesced by the Auth adapter. Offline startup restores cached identity without requiring a network request.

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
| Offline or failed sync | Local outbox retained; visible status and retry |
| Lost mutation response | Retry the same operation ID; server returns its persisted receipt |
| Conflicting device edits | Keep both snapshots for an explicit choice; identical content converges automatically |
| Expired session | Reauthenticate the same account without discarding pending changes |
| Corrupt/missing credentials | Recover guest mode while retaining isolated account cache/outbox for later sign-in |

## Security and privacy

The on-device library still needs no credentials. Optional accounts use the official Supabase Auth SDK with PKCE.
Session tokens, refresh tokens, and PKCE state use Keychain with device-only, after-first-unlock accessibility.
They are not stored in UserDefaults or the App Group. Embedded credentials in bookmark URLs are rejected.
No passwords, tokens, URLs, notes, or page bodies are written to application diagnostic logs.

The shared library directory uses complete-until-first-user-authentication file protection on iOS, allowing extensions
to access it after the first unlock. A stricter locked-device policy would trade widget availability for stronger protection.
The widget marks its content privacy-sensitive. Review this policy if adding more sensitive user content.

There is no server-side webpage-fetching proxy. Saved websites and their image providers
still receive direct device requests; users should not treat preview fetching as anonymous.

## Cloud sync protocol

1. A local edit writes the visible record and a new operation UUID atomically. Repeated edits coalesce per bookmark.
2. The GraphQL mutation sends the operation UUID, expected server revision, full desired bookmark, and deletion flag.
3. The server derives ownership from `auth.uid()`, not client input. An account-scoped transaction lock also protects
   concurrent first inserts. Clients have SELECT access under RLS, but no direct INSERT/UPDATE/DELETE privileges.
4. The function either applies the revision-checked change or returns a conflict snapshot. The exact result and a
   request fingerprint are retained under `(owner, operation UUID)`. Reusing an ID with a different request is rejected.
5. An acknowledgement only clears the matching queued operation. If the user edited meanwhile, the newer edit stays
   queued and is rebased onto the acknowledged revision. Stale responses cannot undo a later conflict resolution.
6. The client reconciles pages ordered by immutable UUID, including deletion tombstones. It never interprets an empty
   or partial GraphQL error response as a successful deletion of local data.
7. Conflict choices are checked against the revision actually displayed. If a newer cloud snapshot arrives while
   the user is deciding, resolution is rejected and the refreshed snapshot is shown rather than overwritten unseen.

The API's bookmark fields are typed. The custom mutation's JSON scalar is a string per `pg_graphql`'s contract.
DTOs explicitly decode it, including timestamps and BigInt revisions. A handwritten typed client keeps this small
API understandable; Apollo code generation would be attractive for a larger schema with many operations.

SQLite remains the durable local source of truth; a GraphQL response cache would not replace the offline outbox.
Full paginated reconciliation is deliberately simpler than a change-log cursor. Per-row revisions are not used as
global change cursors: commit ordering could otherwise cause missed changes. The tradeoff is more reads, plus
eventual pickup on a subsequent sync for concurrent inserts preceding a page cursor.

## Account lifecycle and data ownership

- Guest data is never uploaded implicitly. Copying it into an account is explicit and keeps the original guest copy.
- Account records, outbox entries, and conflicts are scoped by authenticated user ID.
- Same-account reauthentication preserves all local work. Credential recovery activates guest mode without deleting
  quarantined account records, allowing them to be recovered on a later sign-in.
- Explicit sign-out warns about unsent changes, clears credentials, removes that account's local cache, and switches
  the shared app/extension scope back to guest. Remote revocation failure is reported as local-only sign-out.
- Account deletion requires password reauthentication in the app and a session created within 15 minutes on the server.
  Deleting the Auth user cascades to bookmarks and operation receipts. The separate guest library remains.
- System widget snapshots and device backups have OS-controlled lifetimes; cache deletion is not forensic erasure.

## Useful interview demonstrations

1. Save a link with metadata networking failing; show it survives relaunch.
2. Explain why an actor does not coordinate two extension/app processes, then show the concurrent-writer test.
3. Edit notes while enrichment finishes; show that metadata only updates its own fields.
4. Explain the standalone free-signing target and why App Group failure must not silently split the library.
5. Profile thumbnail scrolling with Instruments; report measured results, not theoretical performance claims.
6. Edit on two devices while one is offline; show the conflict and resolve it without losing either snapshot.
7. Reauthenticate an expired session without deleting its queued changes.
8. Show that a second account cannot read or modify the first account's rows, even through raw API requests.
