"""Verify .flutter-plugins-dependencies plugin paths resolve on this machine."""
import json
import os

P = ".flutter-plugins-dependencies"
d = json.load(open(P, encoding="utf-8"))

ok = miss = 0
seen = set()
for plat, items in d["plugins"].items():
    for it in items:
        path = it.get("path", "")
        if not path or path in seen:
            continue
        seen.add(path)
        # JSON already decoded the escapes, so `path` is a real Windows path.
        if os.path.isdir(path):
            ok += 1
        else:
            miss += 1
            print(f"  MISSING [{plat}] {it['name']}: {path}")

print(f"distinct plugin paths: {len(seen)} | exist: {ok} | missing: {miss}")
