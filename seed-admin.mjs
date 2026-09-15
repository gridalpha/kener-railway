// Claims Kener's owner account against a loopback instance, before the public
// listener is ever bound.
//
// Kener ships no signup page. The first account is created by the `signup` form
// action on /account/signin, which succeeds for as long as the users table is
// empty — so a fresh public deployment hands the admin seat to whoever loads the
// page first. Doing it here closes that window outright.
//
// Safe to re-run: once an account exists the action answers "Set up already
// done", which is treated as success, so an operator's later password change is
// never reverted.

const baseUrl = process.env.KENER_BOOTSTRAP_URL ?? "http://127.0.0.1:3999";
const bootLog = process.env.KENER_BOOTSTRAP_LOG;
const readyMarker = process.env.KENER_BOOTSTRAP_READY_MARKER ?? "Kener is running on port";
const readyTimeoutMs = Number(process.env.KENER_BOOTSTRAP_TIMEOUT_MS ?? 240_000);

const email = process.env.KENER_ADMIN_EMAIL;
const password = process.env.KENER_ADMIN_PASSWORD;
const name = process.env.KENER_ADMIN_NAME || "Admin";

const log = (...args) => console.log("[kener-railway:seed]", ...args);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

if (!email || !password) {
  log("no admin credentials supplied, nothing to seed");
  process.exit(0);
}

// Kener's own rule: at least one digit, one lowercase, one uppercase, min 8.
if (!/^(?=.*\d)(?=.*[a-z])(?=.*[A-Z]).{8,}$/.test(password)) {
  log("KENER_ADMIN_PASSWORD does not satisfy Kener's policy (8+ chars, upper, lower, digit)");
  process.exit(1);
}

// Waiting on /healthcheck is not enough: Express registers that route before
// listen(), while migrations and seeds run *inside* the listen callback. Seeding
// against a half-migrated schema fails on a missing table or a missing `admin`
// role, so wait for the line the app prints once migrations, seeds and the
// schedulers are all up.
async function waitForReady() {
  const { readFile } = await import("node:fs/promises");
  const deadline = Date.now() + readyTimeoutMs;

  while (Date.now() < deadline) {
    if (bootLog) {
      const contents = await readFile(bootLog, "utf8").catch(() => "");
      if (contents.includes(readyMarker)) return true;
    } else {
      const ok = await fetch(`${baseUrl}/healthcheck`, { signal: AbortSignal.timeout(5000) })
        .then((r) => r.ok)
        .catch(() => false);
      if (ok) return true;
    }
    await sleep(2000);
  }

  return false;
}

if (!(await waitForReady())) {
  log(`bootstrap instance never reported ready within ${readyTimeoutMs}ms`);
  process.exit(1);
}

// SvelteKit answers a form action with a full HTML page render unless this header
// is set, in which case it returns the action result as JSON. The Origin header
// is what its CSRF check compares against ORIGIN, which the entrypoint pins to
// this same loopback URL for the bootstrap instance.
const response = await fetch(`${baseUrl}/account/signin?/signup`, {
  method: "POST",
  headers: {
    "content-type": "application/x-www-form-urlencoded",
    "x-sveltekit-action": "true",
    origin: baseUrl,
  },
  body: new URLSearchParams({ name, email, password }).toString(),
  redirect: "manual",
  signal: AbortSignal.timeout(60_000),
});

const text = await response.text();

if (/set\s*up already done/i.test(text)) {
  log(`an account already exists, leaving it untouched`);
  process.exit(0);
}

// The action ends in `throw redirect(302, …)`, which SvelteKit reports as a
// redirect result — as JSON here, or as a bare 30x if the header were ignored.
if (/"type"\s*:\s*"redirect"/.test(text) || (response.status >= 300 && response.status < 400)) {
  log(`owner account created for ${email}`);
  process.exit(0);
}

log(`signup failed with HTTP ${response.status}: ${text.slice(0, 500)}`);
process.exit(1);
