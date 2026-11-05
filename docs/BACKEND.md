# Backend setup and verification

## What is deployed

Supabase project `veyvxdqrvlntdloxegmd` hosts Postgres, Auth, and `pg_graphql`.
The checked-in [configuration](../Config/Backend.json) contains only a client-safe publishable key and URL.
Database migrations and declared Auth/API settings are in [supabase/](../supabase/).

Authentication uses the official Supabase Swift SDK's Auth product. Bookmark queries and mutations use a small,
typed GraphQL client over URLSession. The client does not contain an administrator key or database password.

## Deploy to your own Supabase project

Create a project in a Free organization, select a region, keep standard Postgres, enable the Data API and automatic
RLS, and disable automatic exposure of new tables. Store the database password privately.

```sh
brew install supabase/tap/supabase
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase db push --remote --dry-run
supabase db push --remote --yes
supabase config diff --remote
supabase config push --remote --yes
```

These commands target the linked hosted project. Review their displayed target before approving changes.
Config push changes only explicitly declared properties. Do not use remote reset commands on a real user database.

Update `Config/Backend.json` with that project's URL, **publishable** key, and project reference. Keep privileged
keys out of the app, source control, shell history, and chat. The CLI stores its own management authorization privately.

## Email verification and recovery

The project requires confirmed email addresses, passwords of at least 12 characters with upper/lowercase letters
and a digit, rotating refresh tokens, and the exact callback `pocketqueue://auth/callback`.
The app stores its PKCE verifier in Keychain and validates callback scheme/host/path.

For automatic callback completion, open the verification/reset link on the device that initiated the flow.
An account confirmed elsewhere can still sign in normally with its password. Recovery must use the originating
device's PKCE state. The app provides a new-password screen after a successful recovery callback.

**Default SMTP is not a public production email service.** Supabase's built-in mailer has strict quotas and recipient
restrictions, often limited to organization members. Configure a suitable SMTP provider in the dashboard before
inviting arbitrary users. Keep its credentials in Supabase's settings, not this repository. Do not turn off
confirmation just to get around email-delivery limits. Hosted verification tests use explicitly created, confirmed,
temporary accounts and do not claim to test delivery to real inboxes.

## Security boundaries

- Public clients can SELECT only their own rows under RLS.
- Public clients cannot write the table directly. `applyBookmarkChange` derives ownership from the JWT and enforces
  revision checks, payload bounds, URL uniqueness, and idempotency receipts.
- The private receipt table is not exposed through the API.
- Account deletion takes no target-user parameter and requires a recently created authenticated session.
- Schema changes require migrations. The checked-in publishable key alone grants no access to private bookmarks.

## Run backend tests without production credentials

On a machine with a running Docker daemon:

```sh
supabase start --exclude studio,imgproxy,realtime,storage-api,edge-runtime,logflare,vector,supavisor
supabase db reset --yes
node scripts/backend-integration.mjs --local
supabase stop --no-backup
```

With no `--remote`, reset operates on the local development stack. CI uses a disposable Ubuntu runner and this local
stack, independently from the macOS iOS job. It creates and removes its own test users. The test process captures local
service credentials without printing them.

## Explicit hosted contract test

With your authorized CLI session:

```sh
POCKETQUEUE_RUN_LIVE_TESTS=1 node scripts/backend-integration.mjs
```

This creates two confirmed synthetic users in the configured project, verifies Auth/GraphQL/RLS, idempotent retries,
conflicts, tombstones, pagination, token refresh, and owner-only deletion, then removes those users and their test data.
It does not inspect or modify other users' data.

## Native Swift and real iOS verification

The native test exercises two independent local SQLite stores against the actual hosted GraphQL API using the real
Auth SDK and Keychain. It checks offline divergence, conflict resolution, propagated deletion, and account isolation.

```sh
mkdir -p .local-secrets
node scripts/backend-fixture.mjs create "$PWD/.local-secrets/hosted-fixture.json"
POCKETQUEUE_LIVE_FIXTURE="$PWD/.local-secrets/hosted-fixture.json" \
  xcrun swift test --filter HostedSyncTests
# Always clean up, including after a failed test:
node scripts/backend-fixture.mjs cleanup "$PWD/.local-secrets/hosted-fixture.json"
```

The fixture file is created with mode 0600 and contains temporary test credentials. Its directory is ignored by Git.
Never commit it or paste its content into a terminal command, issue, PR, or chat.

For the optional real iOS test, use an English-language **disposable simulator**:

1. Create the private fixture above and build/install the Debug app.
2. Copy the fixture into that app sandbox's Documents directory as `BackendTestCredentials.json`, keeping mode 0600.
3. Run `testLiveBackendAuthenticationAndSync` with `TEST_RUNNER_POCKETQUEUE_LIVE_IOS=1` in the xcodebuild environment.
   The app reads the fixture privately; passwords are not entered through XCTest or placed in launch arguments.
4. Run `node scripts/backend-fixture.mjs verify-ios /ABSOLUTE/PRIVATE/FIXTURE.json` to verify the saved iOS note through
   the user's RLS-protected API, then run `cleanup`.
5. Remove the copied credential fixture from the simulator. Its container path may change during test installation.

The live hook uses a separate Keychain service and is absent from Release builds. Ordinary CI skips these hosted
tests; it runs deterministic client tests plus the local backend contract tests instead.

## Operational limits

There are no paid add-ons enabled by this code. Free-tier quotas, inactivity pausing, and provider limits still apply.
Receipts and tombstones are retained until account deletion; monitor storage growth before expanding beyond a
personal collection. Supabase's service/security logs and backups have provider-controlled retention.

This is a deployed portfolio backend, not a claim of production uptime, a public SMTP deployment, or App Store approval.
