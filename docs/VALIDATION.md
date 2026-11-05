# Validation and demo guide

## Backend integration verification

On November 5, 2026:

- Full iOS run: **92 passing tests, zero failures**, with two credential-dependent live cases intentionally gated.
- The live native Swift test separately used the real Auth SDK and Keychain with two local databases, verified
  cross-device sync, offline conflicts, explicit resolution, deletion propagation, and another account's isolation.
- The live iOS test separately authenticated through the actual SDK, saved and synced a bookmark, and signed out.
  An independent RLS-protected API read confirmed that the iOS note reached hosted Postgres.
- Hosted backend tests verified query/mutation isolation, rejected anonymous and forged tokens, prohibited direct
  table writes, stable idempotency receipts, stale revisions, duplicate URLs, tombstones, pagination, session refresh,
  and rejection of account deletion from an old session until reauthentication.
- SQL migrations and declared Auth/API configuration were deployed to the configured project.
- All ephemeral hosted users and private credential fixture files were removed after verification.
- Code review found session-recovery data-loss paths; they were fixed with preserved outboxes, same-account
  reauthentication, and an actionable guest-recovery screen, with regression coverage.

The default test suite includes deterministic auth/UI fixtures, not real passwords. See
[Backend setup and verification](BACKEND.md) for the opt-in native/hosted commands and SMTP limitations.
Actual inbox delivery, physical-device signing, and App Store submission are not claimed by these checks.

## Original local-only baseline

On November 4, 2026, using Xcode 27.1 and an isolated iPhone 16 / iOS 18.6 simulator:

- **24 core unit/integration tests + 8 UI tests passed** (32 test functions; the parameterized URL test has six cases).
- Strict SwiftLint passed with no violations.
- Full Debug/test and Release app/extension builds passed.
- The standalone app build passed without App Group entitlements.
- The real share extension saved into the main app's shared library.
- A cold-launch widget-format deep link opened the expected bookmark.
- The actual small Home Screen widget was installed through the system widget gallery, displayed a saved bookmark,
  and reopened that exact bookmark and its notes after the app was terminated.
- The library remained navigable at the largest accessibility text size.
- The real metadata client fetched titles from three public HTTPS pages outside the fixture tests.
- Concurrent database initialization tests passed 50 consecutive stress runs after fixing a reproduced WAL promotion race.

The simulator coverage report measured 95.6% line coverage for the core package, 80.6% for the app target,
and 88.2% for the share extension. These are one run's line-coverage numbers, not proof of correctness.
The widget target still reported 16.8% line coverage; the separate system-UI test verifies actual Home Screen
rendering and tap-through rather than inferring them from that number.
Physical-device signing, VoiceOver operation, Instruments profiling, medium-widget layout, and App Store
distribution were not validated by this simulator run.

[View the actual Home Screen widget screenshot](images/widget.png). The screenshot uses a synthetic example URL
created by the UI test, not personal browsing data.

### Reproduce the actual widget check

```sh
xcodebuild test \
  -project PocketQueue.xcodeproj \
  -scheme PocketQueue \
  -only-testing:PocketQueueUITests/PocketQueueUITests/testHomeScreenWidgetDisplaysAndOpensBookmark \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_UDID' \
  -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY=-
```

Use an English-language, disposable simulator for the system-UI test. It adds a Home Screen widget and synthetic
bookmark to the real shared app container, rather than the isolated database used by ordinary UI tests.

## Automated checks

The repository includes:

- Swift Testing suites for domain rules, SQLite integration, metadata networking, and library state.
- XCTest UI flows that use accessibility identifiers rather than screen-coordinate taps.
- A strict SwiftLint gate.
- A CI build of the app, share extension, widget, and standalone variant.
- A disposable local Supabase CI stack exercising real Auth, GraphQL, and SQL authorization without production secrets.
- Auth/PKCE, schema migration, owner-scoped outbox, stale acknowledgements, conflict resolution, and recovery tests.

Ordinary UI tests isolate their data using a random test identifier. Their fake website metadata is deliberately injected;
passing those tests does not establish that every external website can be previewed. System sharing, widget, and
Safari URL-opening tests use the real shared library with synthetic `.example` links. The URL test launches the
terminated app through Safari's confirmation prompt, rather than relying on XCTest's direct URL-launch implementation.

Run the commands in the README. Results bundles include UI diagnostics and coverage when run through the shared scheme.

## Manual acceptance checklist

Use an ordinary launch, not `--ui-testing`, for live-network and extension checks.

1. Save an HTTPS page with a title. Confirm a preview arrives.
2. Save an HTTP link. Confirm it remains saved and explains why its preview is unavailable.
3. Disable connectivity, save another link, terminate, and relaunch. Confirm the URL and note remain.
4. Restore connectivity and tap Retry preview.
5. Edit notes, mark read, favorite, search by tag, and delete with confirmation.
6. In Safari, share a link to PocketQueue. Open the app and confirm the bookmark appears.
7. Share the same URL again. Confirm the existing notes are unchanged.
8. The small Read next widget and tap-through are automated above; also check the medium layout before release.
9. Check empty, pending, failed, and populated states in light/dark mode and accessibility text sizes.
10. Use VoiceOver to navigate the library, add form, details, and destructive confirmation.
11. Confirm signup/recovery email delivery with your configured SMTP provider and an actual inbox.
12. Sign into the same account on two devices and check an offline edit conflict; use Sign in again rather than
    destructive sign-out when testing session expiry.

## Performance and diagnostics

- Instruments Time Profiler: scroll a library with many thumbnail URLs and inspect main-thread work.
- Allocations: verify thumbnail memory reaches a bounded steady state rather than growing with every revisit.
- Console: filter subsystem `com.avinashrajavarapu.pocketqueue`. Errors should contain categories, not saved content.
- Xcode Organizer: available for distributed-app diagnostics when the app is actually released.

No production performance numbers or production crash-monitoring claims are made without measurements.

## Three-minute interview walkthrough

1. Show save-first behavior under a preview failure.
2. Relaunch and find the bookmark through local search.
3. Show notes/favorite/read state and a widget deep link.
4. Open the concurrent-writer and late-metadata tests.
5. Explain one deliberate limit: opt-in account libraries, paginated full reconciliation, or system-controlled widget refresh.

## Release boundary

The project is suitable for local/simulator development and source-based portfolio review.
Publishing source or passing CI is not an App Store release. Before public distribution, complete physical-device
checks, an accessibility audit, privacy-label review, signing/provisioning, store metadata, and App Review submission.
