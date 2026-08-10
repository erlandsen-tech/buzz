# Buzz Docker Compose deployment

This is the single-node/VPS deployment bundle. It is intentionally separate from
the root `docker-compose.yml`, which remains local development infrastructure.

## Quick start

```bash
cd deploy/compose
./bootstrap.sh --domain buzz.example.com --owner-pubkey <your-64-hex-pubkey>
./run.sh start
curl -fsS https://buzz.example.com/_liveness
```

`bootstrap.sh` generates `.env` from `.env.example` with hex secrets (URL-safe —
they are interpolated into connection URLs like `redis://:<password>@…`), fills
every domain-derived value, and persists `BUZZ_COMPOSE_TLS=true` so `run.sh`
includes the Caddy/Let's Encrypt override in every shell. To configure by hand
instead, copy `.env.example` to `.env` and replace every `CHANGE_ME` value.

## Scaleway

`scripts/provision-scaleway.sh` (from the repo root, needs `scw` + `jq`
authenticated against your project) creates a security group (SSH/80/443), a
small instance with a public IP, and DNS. New instances install Docker CE and
clone this repo to `/opt/buzz-selfhost` via cloud-init on first boot.

```bash
SSH_CIDR=<your-ip>/32 ./scripts/provision-scaleway.sh
ssh root@<public-ip>          # then follow the printed next steps
```

Without `DNS_NAME=<domain-you-control>`, the instance's automatic
`<instance-id>.pub.instances.scw.cloud` name is used — Let's Encrypt issues
for it, so TLS works with zero DNS setup.

## Production notes

- Requires Docker Compose v2.24.4 or newer; the TLS override uses Compose's
  `!reset` tag to remove the direct relay port when Caddy terminates HTTPS.
- Default `BUZZ_IMAGE` tracks `ghcr.io/block/buzz:main` for early testing. Pin it to `ghcr.io/block/buzz:sha-<7>` or a semver release tag for production once available.
- Keep `BUZZ_RELAY_PRIVATE_KEY`, `BUZZ_GIT_HOOK_HMAC_SECRET`, database/Redis,
  and S3 secrets stable across restarts.
- `RELAY_OWNER_PUBKEY` is intentionally not prefixed with `BUZZ_`; it must be a
  64-character hex Nostr pubkey when closed relay mode is enabled.
- `BUZZ_AUTO_MIGRATE` is opt-in. Set `BUZZ_AUTO_MIGRATE=true` or run
  `buzz-admin migrate` before starting the relay when bootstrapping a fresh
  database. Auto-migration requires an image that includes embedded SQLx
  migrations.
- The stack uses Postgres, Redis, MinIO, and a git data volume because
  those are real Buzz dependencies today. Minimal mode can simplify this later.
- The bundled Compose stack fixes the relay endpoint to `http://minio:9000` and
  `BUZZ_S3_ADDRESSING_STYLE=path`: Docker DNS resolves `minio`, not
  `<bucket>.minio`. It is not configurable for an external S3 provider through
  `.env`; use the Helm chart or a custom Compose configuration for providers
  such as new Railway Storage Buckets that require `virtual` addressing.

Run `./run.sh backup-hint` for the backup checklist.

## Validation

Before sharing an install link publicly, verify a fresh install with:

```bash
cd deploy/compose
./bootstrap.sh --domain <domain> --owner-pubkey <hex>
./run.sh config
./run.sh start
./run.sh status
curl -fsS "https://<domain>/_liveness"
# WebSocket upgrade through Caddy must return 101:
curl -s --http1.1 -o /dev/null -w '%{http_code}\n' \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  "https://<domain>/"
```
