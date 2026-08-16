const fs = require("fs");
const vm = require("vm");

const sourcePath = "src/codexpp/Codex++/headroom-status-indicator.js";
const hook = { enabled: true };
global.window = { __CODEXPP_HEADROOM_STATUS_TEST_HOOK__: hook };
global.document = {};

vm.runInThisContext(fs.readFileSync(sourcePath, "utf8"), { filename: sourcePath });

const keys = [
  "gateway-livez",
  "gateway-health",
  "headroom-livez",
  "headroom-health",
  "relay",
  "route",
  "official-dataplane",
  "codex-connection",
  "api",
  "transport",
  "kompress",
  "token-accounting",
  "monitor-core",
];
const now = new Date().toISOString();
const body = {
  schema_version: 2,
  generated_at: now,
  stale_after_seconds: 15,
  overall: "yellow",
  items: keys.map((key) => ({
    key,
    label: key,
    state: key === "official-dataplane" ? "yellow" : "green",
    summary: "fixture",
    detail: "fixture",
    observed_at: now,
    source: "fixture",
  })),
  metrics: { status_fingerprint: "a".repeat(64) },
  active_issues: [],
  recent_recoveries: [],
};

const snapshot = hook.buildSnapshot({ transportOk: true, status: 200, body });
if (snapshot.overall !== "yellow") throw new Error(`unexpected overall: ${snapshot.overall}`);
if (snapshot.rows.length !== keys.length) throw new Error(`unexpected row count: ${snapshot.rows.length}`);
if (snapshot.rows.map((row) => row.id).join(",") !== keys.join(",")) throw new Error("indicator item order mismatch");
const timestamp = "2026-08-16T00:47:06.680197Z";
const localTimestamp = hook.formatLocalTimestamp(timestamp);
const expectedLocalTimestamp = new Intl.DateTimeFormat(undefined, {
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hour12: false,
}).format(new Date(timestamp));
if (localTimestamp !== expectedLocalTimestamp) throw new Error("local timestamp conversion mismatch");

console.log("headroom indicator contract: PASS (13 items)");
