#!/usr/bin/env bash
# =============================================================================
# SHE V3 — Join emqx-2 and emqx-3 to the emqx-1 cluster
# =============================================================================
# Run AFTER all 3 containers are up. Idempotent — safe to re-run.
# V3-ARCHITECTURE §6 (Ekka Mnesia cluster mesh, 3 nodes quorum tolerates 1 loss)
# =============================================================================
set -euo pipefail

echo "== Joining emqx-2 → emqx-1 =="
docker exec she-emqx-2 /opt/emqx/bin/emqx ctl cluster join emqx@emqx-1 || true

echo "== Joining emqx-3 → emqx-1 =="
docker exec she-emqx-3 /opt/emqx/bin/emqx ctl cluster join emqx@emqx-1 || true

echo "== Cluster status =="
docker exec she-emqx-1 /opt/emqx/bin/emqx ctl cluster status

echo ""
echo "If 'emqx ctl cluster status' shows 3 nodes running, Phase 0 EMQX exit criterion is met."
