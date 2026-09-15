# Kener on Railway
#
# Upstream publishes a ready-to-run image. Four things it cannot do on its own
# are what make this a repo rather than a plain image deployment:
#
#   1. Kener has no signup page — the first account is claimed through the
#      `signup` form action on /account/signin, which succeeds while the users
#      table is empty. On a public URL that is a claim window open to whoever
#      loads the page first. The entrypoint seeds that account over loopback,
#      before the public listener ever binds.
#   2. The shipped `siteURL` setting is seeded as http://localhost:3000 and is
#      only reachable through the admin UI, so every RSS link, embed snippet and
#      notification e-mail points at localhost behind a green deployment. The
#      entrypoint repairs the row from ORIGIN, guarded on it still holding the
#      shipped default so an operator's own value is never reverted.
#   3. The image grants /usr/bin/ping the CAP_NET_RAW file capability. Railway
#      drops CAP_NET_RAW, and execve of a file-capability binary then fails
#      outright, so Node's spawn throws EPERM inside the monitor worker.
#      Removing the capability lets ping run and fail cleanly instead. It cannot
#      actually send: Railway also leaves net.ipv4.ping_group_range at the kernel
#      default "1 0", so the unprivileged ICMP datagram socket is unavailable
#      too — the entrypoint measures this at boot and says so in the log.
#   4. Its node:24-slim base ends with `apt-get purge --auto-remove`, which takes
#      ca-certificates with it: /etc/ssl/certs does not exist. Node carries its
#      own root store so the app looks fine, but curl — the image's own
#      HEALTHCHECK, and anything else non-Node — cannot make an HTTPS call.
FROM rajnandan1/kener:latest

# RUN/COPY inherit the base image's USER (node). Everything below needs root;
# the image's own USER is restored at the end.
USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && test -s /etc/ssl/certs/ca-certificates.crt

# Railway containers drop CAP_NET_RAW, and the kernel refuses to execve a binary
# carrying a file capability the container cannot hold. Removing it lets iputils
# fall back to an ICMP datagram socket, which needs no capability at all.
RUN setcap -r /usr/bin/ping \
 && ! getcap /usr/bin/ping | grep -q cap_net_raw

COPY entrypoint.sh /usr/local/bin/kener-railway-entrypoint.sh
COPY seed-admin.mjs /usr/local/lib/kener-railway/seed-admin.mjs
COPY users-count.mjs /usr/local/lib/kener-railway/users-count.mjs
COPY repair-site-url.mjs /usr/local/lib/kener-railway/repair-site-url.mjs

RUN chmod 0755 /usr/local/bin/kener-railway-entrypoint.sh \
 && bash -n /usr/local/bin/kener-railway-entrypoint.sh \
 && node --check /usr/local/lib/kener-railway/seed-admin.mjs \
 && node --check /usr/local/lib/kener-railway/users-count.mjs \
 && node --check /usr/local/lib/kener-railway/repair-site-url.mjs \
 && test -f /app/build/main.js \
 && test -x /app/docker-entrypoint.sh \
 && node -e "require.resolve('pg', { paths: ['/app/node_modules'] })"

ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

USER node
WORKDIR /app

# The base image's ENTRYPOINT (BODY_SIZE_LIMIT default + docs indexing) is kept:
# this entrypoint execs it. Declaring an ENTRYPOINT here would empty the
# inherited CMD, so both are restated.
ENTRYPOINT ["/usr/local/bin/kener-railway-entrypoint.sh"]
CMD ["node", "build/main.js"]
