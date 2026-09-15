# Kener on Railway

A thin wrapper around the published [`rajnandan1/kener`](https://hub.docker.com/r/rajnandan1/kener)
image that makes [Kener](https://github.com/rajnandan1/kener) — an open-source status page and uptime
monitor — deployable on Railway with no manual first-run steps.

The application itself is unmodified. This repo adds one entrypoint and three small scripts.

## What the wrapper does

| Gap in the published image | What happens here |
|---|---|
| Kener ships no signup page: the first account is claimed through the `signup` form action on `/account/signin`, which succeeds while the users table is empty. On a public URL that is an open admin seat. | The entrypoint starts Kener on `127.0.0.1`, claims the owner account from `KENER_ADMIN_EMAIL`/`KENER_ADMIN_PASSWORD`, stops it, and only then binds the public port. Skipped in one database query when an account already exists. |
| The stored `siteURL` setting is seeded as `http://localhost:3000` and is only reachable from the admin UI, so RSS links, embed snippets and notification e-mails all point at localhost. | A one-shot background job rewrites the row from `ORIGIN`, guarded on it still holding the shipped default so an operator's own value is never reverted. |
| `/usr/bin/ping` carries the `cap_net_raw` file capability. Railway drops `CAP_NET_RAW`, and the kernel then refuses to `execve` the binary at all — every ping monitor fails with a bare `EPERM`. | The capability is removed in a build layer, so `iputils` falls back to an ICMP datagram socket, which needs no capability. |
| The `node:24-slim` base ends with `apt-get purge --auto-remove`, which takes `ca-certificates` with it — `/etc/ssl/certs` does not exist. Node carries its own root store, so only non-Node processes (the image's own `curl` healthcheck) break. | `ca-certificates` is reinstalled and `SSL_CERT_FILE` is pinned to the bundle. |

## Environment variables

| Variable | Required | Notes |
|---|---|---|
| `KENER_SECRET_KEY` | yes | Signs session tokens and API keys. Must stay stable — changing it invalidates every session. |
| `ORIGIN` | yes | Public base URL, no trailing slash. Defaults to `https://$RAILWAY_PUBLIC_DOMAIN` when unset. |
| `REDIS_URL` | yes | Kener runs its monitor scheduler on BullMQ. |
| `DATABASE_URL` | recommended | `postgresql://…`. Without it Kener uses SQLite under `/app/database`, which is container-local and lost on every deploy. |
| `KENER_ADMIN_EMAIL` | recommended | Owner account seeded at first boot. |
| `KENER_ADMIN_PASSWORD` | recommended | 8+ characters with an upper case letter, a lower case letter and a digit. |
| `KENER_ADMIN_NAME` | no | Display name for the owner, default `Admin`. |
| `PORT` | no | Default `3000`. |
| `KENER_BOOTSTRAP_PORT` | no | Loopback port used only during the owner bootstrap, default `3999`. |

Everything else Kener documents (`SMTP_*`, `RESEND_*`, `KENER_BASE_PATH`, `BODY_SIZE_LIMIT`,
`DATABASE_POOL_MAX`, `HTTPS_PROXY`, …) is passed straight through.

## Health check

`GET /healthcheck` returns `{"status":"ok","db":true,"redis":true}`. It answers 200 even when a
dependency is down, so that a restarter cannot bounce the app over a dead database; add `?strict=1`
for a 503 in that case.

## Licence

Kener is MIT-licensed by [Rajnandan Sharma](https://github.com/rajnandan1). This wrapper adds no
application code and carries the same licence.
