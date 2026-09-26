# ADR-017: Object Storage After the Removal of the minio/minio Image

**Status:** Proposed
**Date:** 2026-Q3
**Decision maker:** Lead Engineer

## Context

`V3-ARCHITECTURE.md` §5.3 names **MinIO** as the S3-compatible object store, and it holds the
OTA firmware images plus the bucket catalog and lifecycle rules. `infra/docker-compose.yml`
pinned it to `minio/minio:RELEASE.2024-10-13T13-34-11Z`.

That image no longer exists. MinIO announced maintenance mode in 2025-12, then removed the
open-source community edition and deleted their Docker Hub images (~2026-09). Every tag now
returns `pull access denied ... repository does not exist`. `quay.io/minio/minio` returns 401.
`bitnami/minio` was withdrawn at the same time.

The failure mode was worse than a single broken service. `docker compose pull` aborts the whole
batch when one image fails, so this one dead reference silently blocked the other five images
(`timescaledb`, `redis`, `emqx`, `step-ca`, `nginx`). The stack appeared to pull nothing at all
rather than reporting one bad reference.

Local development is currently unblocked by pinning
`bitnamilegacy/minio:2024.10.13-debian-12-r1`. That tag is built from the **same upstream MinIO
release** the stack was already pinned to, verified in-container:

```
minio version DEVELOPMENT.2024-10-13T13-34-11Z (commit-id=d10bb7e1b667c2df72c394ef1fa52ab4a6802d0f)
Runtime: go1.22.8 linux/amd64
```

So there is no version drift. Two adjustments were still required, because Bitnami's image is
not a drop-in for the upstream one:

- Bitnami's `entrypoint.sh` `exec`s its arguments verbatim, so the existing
  `command: server /data --console-address ":9001"` died with `exec: server: not found`
  (exit 127, crash-loop). The service now sets
  `entrypoint: ["/opt/bitnami/minio/bin/minio"]`, which calls the real binary while keeping the
  original arguments and the native `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` / `MINIO_VOLUMES`
  environment variables.
- Bitnami defaults to `User=1001`; the upstream image ran as root. `user: "0"` restores the
  previous behaviour so the root-owned `she-minio-data` volume stays writable.

**`bitnamilegacy` is an archive, not a maintained repository.** It receives no further security
updates. It is acceptable to unblock a developer laptop; it is not acceptable for production.

## Decision

1. **Local development uses `bitnamilegacy/minio:2024.10.13-debian-12-r1`**, pinned by tag and
   scoped to `SPRING_PROFILES_ACTIVE=local`. The pin, the `entrypoint` override, and the
   `user: "0"` rationale are recorded inline in `infra/docker-compose.yml`.

2. **The `bitnamilegacy` archive is explicitly rejected for production.** No staging or
   production environment may run it.

3. **Production object storage is a separate, still-open decision.** This ADR records the
   constraint set for that decision rather than pre-empting it:

   | Constraint | Source |
   |---|---|
   | S3-compatible API (the backend and OTA path speak S3) | `V3-ARCHITECTURE` §5.3 |
   | Fully self-hosted — no third-party cloud storage | ADR-001 |
   | Actively maintained, with a published security-update path | this ADR |
   | Licence acceptable for a commercial product | this ADR |
   | Bucket lifecycle rules supported (OTA image retention) | `V3-ARCHITECTURE` §5.3 |

4. **A follow-up ADR is required before Phase 5 (GA).** Until it exists, the production storage
   component is unresolved and must not be treated as settled by any other document.

## Consequences

- Local development proceeds today with zero drift from the previously pinned MinIO release, so
  OTA upload/download behaviour, bucket naming, and the `mc` client all keep working unchanged.
- The compose file now carries an image that will never receive a CVE fix. This is a **known and
  time-boxed** exposure, not an oversight — it is the reason this ADR exists.
- `V3-ARCHITECTURE` §5.3 still names MinIO as the object store. That is now only accurate for
  local development; the production statement is suspended pending the follow-up ADR.
- Anyone reading `docker-compose.yml` sees the reason inline, so the pin does not look like an
  arbitrary fork to a future maintainer.
- Because compose aborts a `pull` batch on one failure, a future image removal elsewhere in the
  stack will fail the same opaque way. Worth remembering when a stack "pulls nothing".

## Alternatives considered

**(a) Keep `minio/minio:RELEASE.2024-10-13T13-34-11Z`.**
Not possible. The repository was deleted; all tags 404.

**(b) `quay.io/minio/minio` or another MinIO mirror.**
Rejected. `quay.io/minio/minio` returns 401 for the pinned tag, and third-party mirrors of a
withdrawn upstream are exactly the kind of unvetted source this project avoids.

**(c) `chainguard/minio`.**
Rejected for now, though it is the strongest maintained option. Chainguard ships a minimal image
with **no `curl`**, so the compose healthcheck (`curl -f http://localhost:9000/minio/health/live`)
would need replacing, and it runs non-root, so the `she-minio-data` volume would need
re-permissioning. That is a real change to the service contract rather than an image swap, so it
belongs in the production decision — not in a stopgap.

**(d) Build MinIO from source and self-publish an image.**
Rejected. MinIO's withdrawal of the community edition makes the long-term availability of the
source uncertain, so this would trade one supply risk for another while adding a build pipeline
to maintain.

**(e) Replace MinIO with another S3-compatible store now (SeaweedFS, Garage, Ceph RGW).**
Rejected *as part of this change*. It is very likely the right destination, but it is an
architecture change touching bucket lifecycle, the OTA path, and the `mc`-based tooling. Doing it
under time pressure on a laptop would replace a contained, reversible pin with an unreviewed
migration. It belongs in the follow-up ADR.

**(f) Use a managed cloud object store (S3, R2, etc.).**
Rejected. ADR-001 commits the platform to full self-hosting.

## References

- `docs/v3-specs/V3-ARCHITECTURE.md` §5.3 — bucket catalog and lifecycle
- `docs/v3-specs/CANONICAL-DECISIONS.md` — requires a new P-entry pointing at this ADR
- `docs/LOCK-MANIFEST.md` §5 — spec freeze; requirement for a new ADR
- ADR-001 — fully self-hosted device cloud
- ADR-014 — factory flashing, which depends on the OTA image store
- `infra/docker-compose.yml` — the `minio` service, where the pin and its rationale are recorded
