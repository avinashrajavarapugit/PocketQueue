import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomBytes, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";

// Privileged keys are captured in this process only, never printed, written, or passed as command arguments.
const configuration = JSON.parse(readFileSync(new URL("../Config/Backend.json", import.meta.url), "utf8"));
const cli = process.env.SUPABASE_CLI || "supabase";
const local = process.argv.includes("--local");
assert.match(configuration.projectRef, /^[a-z]{20}$/);
assert.equal(configuration.url, `https://${configuration.projectRef}.supabase.co`,
  "Privileged test access is restricted to the configured project's canonical Supabase origin.");
if (!local && process.env.POCKETQUEUE_RUN_LIVE_TESTS !== "1") {
  throw new Error("Set POCKETQUEUE_RUN_LIVE_TESTS=1 to create and remove isolated users on the configured project.");
}

let url = configuration.url;
let publicKey = configuration.publishableKey;
let adminKey;
function cliJSON(arguments_) {
  try {
    return JSON.parse(execFileSync(cli, arguments_, { encoding: "utf8" }));
  } catch {
    throw new Error("Supabase CLI operation failed; potentially sensitive command output was withheld.");
  }
}
if (local) {
  const status = cliJSON(["status", "--output", "json"]);
  url = status.API_URL;
  publicKey = status.ANON_KEY;
  adminKey = status.SERVICE_ROLE_KEY;
} else {
  const keys = cliJSON([
    "projects", "api-keys", `--remote=${configuration.projectRef}`, "--reveal", "--output", "json",
  ]);
  adminKey = keys.find(key => key.name === "service_role")?.api_key;
}
assert.ok(url && publicKey && adminKey && adminKey !== "******", "Required API configuration is unavailable.");
if (local) {
  assert.ok(["127.0.0.1", "localhost", "[::1]"].includes(new URL(url).hostname),
    "Local test credentials must only be sent to a loopback origin.");
}

const users = [];
const headers = token => ({
  apikey: publicKey,
  "Content-Type": "application/json",
  ...(token ? { Authorization: `Bearer ${token}` } : {}),
});

async function request(path, { method = "POST", body, token, admin = false } = {}) {
  const response = await fetch(url + path, {
    method,
    headers: admin
      ? { apikey: adminKey, Authorization: `Bearer ${adminKey}`, "Content-Type": "application/json" }
      : headers(token),
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(20000),
  });
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null };
}

async function createUser() {
  const email = `pocketqueue-test-${randomUUID()}@example.com`;
  const password = `${randomBytes(24).toString("base64url")}aA7!`;
  const created = await request("/auth/v1/admin/users", {
    admin: true, body: { email, password, email_confirm: true },
  });
  assert.equal(created.status, 200, "Could not create an isolated test user.");
  assert.ok(created.body.id, "The created user has no identity.");
  const user = { id: created.body.id, email, password };
  users.push(user);
  const login = await request("/auth/v1/token?grant_type=password", { body: { email, password } });
  assert.equal(login.status, 200, "Test user sign-in failed.");
  assert.ok(Boolean(login.body.access_token), "Sign-in returned no session.");
  return { ...user, token: login.body.access_token, refreshToken: login.body.refresh_token };
}

async function graphql(token, query, variables = {}) {
  return request("/graphql/v1", { token, body: { query, variables } });
}

const mutation = `
  mutation Apply($operationId: UUID!, $expectedVersion: BigInt!, $bookmark: JSON!, $isDeleted: Boolean!) {
    applyBookmarkChange(operationId: $operationId, expectedVersion: $expectedVersion,
                        bookmark: $bookmark, isDeleted: $isDeleted)
  }`;

const collection = `
  query List($after: Cursor, $count: Int!) {
    bookmarksCollection(first: $count, after: $after, orderBy: [{id: AscNullsLast}]) {
      edges { node {
        ownerId id url title note tags isRead isFavorite createdAt
        metadataState metadataMessage imageUrl revision deleted
      } }
      pageInfo { endCursor hasNextPage }
    }
  }`;

function bookmark(overrides = {}) {
  return {
    id: randomUUID(), url: `https://example.com/${randomUUID()}`, title: "Integration fixture",
    note: "Original", tags: ["test"], isRead: false, isFavorite: false,
    createdAt: Date.now() / 1000, metadataState: "ready", ...overrides,
  };
}

function variables(item, version = 0, deleted = false, operationId = randomUUID()) {
  return { operationId, expectedVersion: String(version), bookmark: JSON.stringify(item), isDeleted: deleted };
}

async function apply(user, values) {
  const result = await graphql(user.token, mutation, values);
  assert.equal(result.status, 200, "GraphQL mutation transport failed.");
  if (result.body.errors?.length) {
    // Schema errors are safe to report; never dump the authenticated request or session.
    throw new Error(`GraphQL mutation failed: ${result.body.errors.map(error => error.message).join("; ")}`);
  }
  assert.equal(typeof result.body.data?.applyBookmarkChange, "string", "Mutation JSON scalar shape changed.");
  return JSON.parse(result.body.data.applyBookmarkChange);
}

async function list(user, count = 50, after = null) {
  const result = await graphql(user.token, collection, { count, after });
  assert.equal(result.status, 200, "GraphQL query transport failed.");
  if (result.body.errors?.length) {
    throw new Error(`GraphQL query failed: ${result.body.errors.map(error => error.message).join("; ")}`);
  }
  assert.ok(result.body.data?.bookmarksCollection, "Missing bookmark collection.");
  return result.body.data.bookmarksCollection;
}

try {
  const alice = await createUser();
  const bob = await createUser();
  console.log("Created two isolated, confirmed test users; credentials are not logged.");

  const item = bookmark();
  const original = variables(item);
  const created = await apply(alice, original);
  assert.equal(created.status, "applied");
  assert.equal(created.record.version, 1);
  assert.equal(created.record.bookmark.id, item.id);
  assert.deepEqual(await apply(alice, original), created, "Retry was not idempotent.");
  const reused = await graphql(alice.token, mutation, { ...original, bookmark: JSON.stringify({ ...item, note: "Changed" }) });
  assert.ok(reused.body.errors?.length, "An operation ID accepted different content.");
  console.log("PASS: atomic create, stable retry receipt, and operation-ID reuse rejection.");

  assert.equal((await list(alice)).edges.length, 1);
  assert.equal((await list(bob)).edges.length, 0, "RLS leaked another account's records.");
  const blindWrite = await apply(bob, variables(item, 1));
  assert.equal(blindWrite.status, "conflict");
  assert.equal(blindWrite.record, null, "Conflict response leaked another user's bookmark.");
  const bobItem = { ...item, note: "Bob's separate record" };
  const bobCreated = await apply(bob, variables(bobItem, 0, false, original.operationId));
  assert.equal(bobCreated.status, "applied", "Operation IDs must be scoped by owner.");
  assert.equal((await list(alice)).edges[0].node.note, "Original");
  assert.equal((await list(bob)).edges[0].node.note, "Bob's separate record");
  console.log("PASS: query isolation, mutation isolation, and account-scoped identities/receipts.");

  const anonymous = await graphql(null, collection, { count: 50, after: null });
  assert.ok(
    anonymous.status === 401 || anonymous.status === 403 || anonymous.body.errors?.length ||
      anonymous.body.data?.bookmarksCollection?.edges?.length === 0,
    "Anonymous caller could read bookmarks.",
  );
  const forged = await graphql("not-a-valid-jwt", collection, { count: 50, after: null });
  assert.ok(forged.status === 401 || forged.status === 403, "Invalid token was accepted.");
  const directInsert = await request("/rest/v1/bookmarks", {
    token: alice.token, body: { owner_id: alice.id, id: randomUUID(), url: "https://example.com/bypass" },
  });
  assert.ok(directInsert.status === 401 || directInsert.status === 403, "Direct DML bypassed the CAS mutation.");
  console.log("PASS: anonymous/invalid-token rejection and direct-write privilege boundary.");

  const updatedItem = { ...item, note: "Newer cloud edit", isFavorite: true };
  const update = await apply(alice, variables(updatedItem, 1));
  assert.equal(update.record.version, 2);
  const stale = await apply(alice, variables({ ...item, note: "Stale edit" }, 1));
  assert.equal(stale.status, "conflict");
  assert.equal(stale.record.bookmark.note, "Newer cloud edit");
  assert.equal((await list(alice)).edges[0].node.note, "Newer cloud edit");
  const duplicate = await apply(alice, variables({ ...item, id: randomUUID() }));
  assert.equal(duplicate.status, "conflict");
  assert.equal(duplicate.record.bookmark.id, item.id);
  console.log("PASS: stale revision conflict, no lost update, and duplicate-URL reconciliation.");

  const deletion = await apply(alice, variables(updatedItem, 2, true));
  assert.equal(deletion.record.isDeleted, true);
  assert.equal(deletion.record.version, 3);
  assert.equal((await list(alice)).edges[0].node.deleted, true, "Deletion tombstone was not fetchable.");
  assert.equal((await list(bob)).edges[0].node.deleted, false);

  await apply(alice, variables(bookmark()));
  await apply(alice, variables(bookmark()));
  const first = await list(alice, 2);
  assert.equal(first.edges.length, 2);
  assert.equal(first.pageInfo.hasNextPage, true);
  const second = await list(alice, 2, first.pageInfo.endCursor);
  assert.equal(second.edges.length, 1);
  assert.equal(second.pageInfo.hasNextPage, false);
  assert.equal(new Set([...first.edges, ...second.edges].map(edge => edge.node.id)).size, 3);
  console.log("PASS: deletion tombstones and cursor pagination without duplicate rows.");

  const refreshed = await request("/auth/v1/token?grant_type=refresh_token", {
    body: { refresh_token: alice.refreshToken },
  });
  assert.equal(refreshed.status, 200, "Refresh-token exchange failed.");
  assert.ok(Boolean(refreshed.body.access_token), "Refresh returned no access token.");

  const sessionID = JSON.parse(Buffer.from(bob.token.split(".")[1], "base64url").toString("utf8")).session_id;
  assert.match(sessionID, /^[0-9a-f-]{36}$/i);
  assert.match(bob.id, /^[0-9a-f-]{36}$/i);
  cliJSON([
    "db", "query", ...(local ? [] : [`--remote=${configuration.projectRef}`]), "--yes",
    `update auth.sessions set created_at = now() - interval '1 hour' where id = '${sessionID}'::uuid and user_id = '${bob.id}'::uuid;`,
  ]);
  const staleDeletion = await request("/rest/v1/rpc/delete_my_account", { token: bob.token, body: {} });
  assert.equal(staleDeletion.status, 403, "Account deletion accepted an old session without reauthentication.");
  const reauthenticated = await request("/auth/v1/token?grant_type=password", {
    body: { email: bob.email, password: bob.password },
  });
  assert.equal(reauthenticated.status, 200, "Reauthentication failed.");
  const deletedAccount = await request("/rest/v1/rpc/delete_my_account", {
    token: reauthenticated.body.access_token, body: {},
  });
  assert.ok(deletedAccount.status === 200 || deletedAccount.status === 204, "Account deletion failed.");
  const formerLogin = await request("/auth/v1/token?grant_type=password", {
    body: { email: bob.email, password: bob.password },
  });
  assert.equal(formerLogin.status, 400, "Deleted account could still sign in.");
  assert.equal((await list({ ...alice, token: refreshed.body.access_token })).edges.length, 3);
  console.log("PASS: session refresh, recent-auth enforcement, and owner-only account deletion.");
  console.log("All hosted backend integration checks passed.");
} finally {
  const failures = [];
  for (const user of users) {
    const result = await request(`/auth/v1/admin/users/${user.id}`, { method: "DELETE", admin: true });
    if (![200, 204, 404].includes(result.status)) failures.push(result.status);
  }
  assert.equal(failures.length, 0, "Some isolated test accounts could not be removed.");
  console.log("Removed isolated test accounts and their cascading test data.");
}
