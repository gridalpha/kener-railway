// Points Kener's stored `siteURL` setting at the deployment's own public URL.
//
// The setting is seeded as the literal http://localhost:3000 and is reachable
// only through the admin UI, so with nobody to click it every RSS channel link,
// every embed snippet and every notification e-mail on a green deployment points
// at localhost. ORIGIN is the value the deployer already had to supply, so the
// row can simply be brought into line with it.
//
// Guarded on the row still holding the shipped default, which makes it
// idempotent and means an operator who sets their own value in the admin UI
// keeps it across every later deploy.

const SHIPPED_DEFAULT = "http://localhost:3000";

const url = process.env.DATABASE_URL ?? "";
const scheme = url.split("://")[0];
const origin = (process.env.ORIGIN ?? "").replace(/\/+$/, "");
const timeoutMs = Number(process.env.KENER_SITE_URL_TIMEOUT_MS ?? 300_000);

const log = (...args) => console.log("[kener-railway:site-url]", ...args);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

if (!origin.startsWith("http")) {
  log("ORIGIN is not an absolute URL, leaving siteURL alone");
  process.exit(0);
}

if (scheme !== "postgresql") {
  log(`database backend is ${scheme || "unset"}, not PostgreSQL — leaving siteURL alone`);
  process.exit(0);
}

const { default: pg } = await import("/app/node_modules/pg/lib/index.js");

// The app runs its migrations and seeds after it starts listening, so the row
// this repairs does not exist for the first few seconds of a cold deployment.
const deadline = Date.now() + timeoutMs;

while (Date.now() < deadline) {
  const client = new pg.Client({
    connectionString: url,
    connectionTimeoutMillis: 10_000,
    statement_timeout: 10_000,
  });

  try {
    await client.connect();
    const { rows } = await client.query(
      "SELECT to_regclass('public.site_data') IS NOT NULL AS present",
    );

    if (rows[0]?.present) {
      const result = await client.query(
        "UPDATE site_data SET value = $1 WHERE key = 'siteURL' AND value = $2",
        [origin, SHIPPED_DEFAULT],
      );

      if (result.rowCount > 0) {
        log(`siteURL set to ${origin}`);
      } else {
        log("siteURL already customised, left untouched");
      }
      process.exit(0);
    }
  } catch (error) {
    log(`waiting for the database: ${error.message}`);
  } finally {
    await client.end().catch(() => {});
  }

  await sleep(5000);
}

log("gave up waiting for the site_data table; siteURL left at its shipped default");
process.exit(0);
