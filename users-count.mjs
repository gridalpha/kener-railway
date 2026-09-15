// Prints how many accounts Kener already has, so the entrypoint knows whether the
// loopback bootstrap is needed at all. Prints `unknown` when it cannot tell — a
// missing table on a first boot, a database that is still starting, or a backend
// other than PostgreSQL — and the caller then runs the bootstrap anyway, which is
// safe: Kener's own signup action refuses a second first-user.
//
// Deliberately talks to the database rather than to the app, because the whole
// point is to answer before anything has been started.

const url = process.env.DATABASE_URL ?? "";
const scheme = url.split("://")[0];

let answer = "unknown";

if (scheme === "postgresql") {
  const { default: pg } = await import("/app/node_modules/pg/lib/index.js");

  const client = new pg.Client({
    connectionString: url,
    connectionTimeoutMillis: 10_000,
    statement_timeout: 10_000,
  });

  try {
    await client.connect();
    const { rows } = await client.query("SELECT to_regclass('public.users') IS NOT NULL AS present");

    if (rows[0]?.present) {
      const result = await client.query("SELECT count(*)::int AS c FROM users");
      answer = String(result.rows[0].c);
    } else {
      // First boot: migrations have not run yet, so there is certainly no account.
      answer = "0";
    }
  } catch (error) {
    process.stderr.write(`[kener-railway:users-count] ${error.message}\n`);
  } finally {
    await client.end().catch(() => {});
  }
}

// Written last and without process.exit, so a pipe cannot truncate it.
process.stdout.write(`${answer}\n`);
