import pg8000, json, sys

# Local dev defaults from application.yml (override via env if needed)
HOST = "localhost"
PORT = 5432
DB = "she_v3"
USER = "she_app"
PW = "ChangeMeLocal"

try:
    conn = pg8000.connect(host=HOST, port=PORT, database=DB, user=USER, password=PW)
except Exception as e:
    print("CONNECT_FAIL", repr(e))
    sys.exit(0)

cur = conn.cursor()
print("=== factory_audit_log rows for SHE-AE5328 ===")
cur.execute(
    "SELECT node_id, event_type, created_at, details "
    "FROM factory_audit_log WHERE node_id = %s ORDER BY created_at DESC",
    ("SHE-AE5328",),
)
rows = cur.fetchall()
print("rows:", len(rows))
for r in rows:
    print(" node_id=%s event=%s at=%s details=%s" % (r[0], r[1], r[2], r[3]))

print("=== also search node_id LIKE SHE-AE5328% ===")
cur.execute(
    "SELECT node_id, event_type, details FROM factory_audit_log "
    "WHERE node_id LIKE %s", ("SHE-AE5328%",)
)
for r in cur.fetchall():
    print(" node_id=%s event=%s details=%s" % (r[0], r[1], r[2]))

print("=== nodes table: any pop column? ===")
cur.execute(
    "SELECT column_name FROM information_schema.columns "
    "WHERE table_name='nodes' AND column_name ILIKE '%pop%'"
)
cols = cur.fetchall()
print("nodes pop cols:", cols)

print("=== nodes row for SHE-AE5328 ===")
cur.execute(
    "SELECT node_id, mac_address, sku FROM nodes WHERE node_id = %s", ("SHE-AE5328",)
)
for r in cur.fetchall():
    print(" node:", r)

cur.close()
conn.close()
