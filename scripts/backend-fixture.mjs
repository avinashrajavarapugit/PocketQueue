import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomBytes, randomUUID } from "node:crypto";
import { readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { isAbsolute } from "node:path";

const [action, path] = process.argv.slice(2);
assert.ok(["create", "verify-ios", "cleanup"].includes(action) && path && isAbsolute(path), "Provide an action and absolute private fixture path.");
const config = JSON.parse(readFileSync(new URL("../Config/Backend.json", import.meta.url), "utf8"));
assert.match(config.projectRef, /^[a-z]{20}$/);
assert.equal(config.url, `https://${config.projectRef}.supabase.co`,
  "Privileged fixture access is restricted to the project's canonical Supabase origin.");
const cli = process.env.SUPABASE_CLI || "supabase";
let keys;
try {
  keys = JSON.parse(execFileSync(cli, [
    "projects", "api-keys", `--remote=${config.projectRef}`, "--reveal", "--output", "json",
  ], { encoding: "utf8" }));
} catch {
  throw new Error("Could not obtain authorized backend test access; credential output was withheld.");
}
const adminKey = keys.find(key => key.name === "service_role")?.api_key;
assert.ok(adminKey && adminKey !== "******", "Backend test access is unavailable.");

async function adminRequest(path, method = "GET", body) {
  const response = await fetch(config.url + path, {
    method, headers: { apikey: adminKey, Authorization: `Bearer ${adminKey}`, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(20000),
  });
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null };
}

if (action === "create") {
  const users = [];
  try {
    for (let index = 0; index < 2; index++) {
      const email = `pocketqueue-ios-test-${randomUUID()}@example.com`;
      const password = `${randomBytes(24).toString("base64url")}aA7!`;
      const result = await adminRequest("/auth/v1/admin/users", "POST", { email, password, email_confirm: true });
      assert.equal(result.status, 200, "Could not create a private test fixture.");
      users.push({ id: result.body.id, email, password });
    }
    writeFileSync(path, JSON.stringify({
      purpose: "PocketQueue ephemeral integration", runID: randomUUID(), projectRef: config.projectRef,
      url: config.url, publishableKey: config.publishableKey, users,
    }), { mode: 0o600, flag: "wx" });
    console.log("Created two ephemeral users and a private 0600 fixture; credentials were not printed.");
  } catch (error) {
    for (const user of users) {
      const result = await adminRequest(`/auth/v1/admin/users/${user.id}`, "DELETE");
      assert.ok([200, 204, 404].includes(result.status), "Failed to clean up a partially created fixture.");
    }
    throw error;
  }
} else {
  const fixture = JSON.parse(readFileSync(path, "utf8"));
  assert.equal(fixture.purpose, "PocketQueue ephemeral integration");
  assert.equal(fixture.projectRef, config.projectRef);
  for (const user of fixture.users) {
    assert.match(user.id, /^[0-9a-f-]{36}$/i);
    assert.ok(user.email.startsWith("pocketqueue-ios-test-") && user.email.endsWith("@example.com"));
  }
  if (action === "verify-ios") {
    const user = fixture.users[0];
    const login = await fetch(config.url + "/auth/v1/token?grant_type=password", {
      method: "POST", headers: { apikey: config.publishableKey, "Content-Type": "application/json" },
      body: JSON.stringify({ email: user.email, password: user.password }), signal: AbortSignal.timeout(20000),
    });
    assert.equal(login.status, 200, "Could not authenticate the fixture for read-back.");
    const session = await login.json();
    const response = await fetch(config.url +
      `/rest/v1/bookmarks?owner_id=eq.${user.id}&url=eq.https%3A%2F%2Fexample.com%2F&select=note,deleted`, {
      headers: { apikey: config.publishableKey, Authorization: `Bearer ${session.access_token}` },
      signal: AbortSignal.timeout(20000),
    });
    assert.equal(response.status, 200);
    const rows = await response.json();
    assert.ok(rows.some(row => row.note === "Synced from the live iOS client" && row.deleted === false),
      "The real iOS client's bookmark did not reach the hosted database.");
    console.log("Verified: the real iOS app authenticated and synced its bookmark into hosted Postgres.");
  } else {
    for (const user of fixture.users) {
      const existing = await adminRequest(`/auth/v1/admin/users/${user.id}`);
      if (existing.status === 404) continue;
      assert.equal(existing.status, 200, "Could not verify fixture ownership before cleanup.");
      assert.equal(existing.body.email, user.email, "Refusing to remove a user that is not the fixture.");
      const removed = await adminRequest(`/auth/v1/admin/users/${user.id}`, "DELETE");
      assert.ok([200, 204].includes(removed.status), "Could not remove an ephemeral test account.");
    }
    unlinkSync(path);
    console.log("Removed the ephemeral users, cascading hosted data, and private credential fixture.");
  }
}
