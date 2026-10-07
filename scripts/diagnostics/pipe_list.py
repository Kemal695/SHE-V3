"""List named pipe names by how many instances each currently has.

Dart's analyzer failed with ERROR_PIPE_BUSY (231), a per-NAME error. With the OS
able to create 4000 fresh uniquely-named pipes, the problem must be that ONE name
is saturated. Dart uses a name derived from client-id + user; find candidates here.
"""
import os
import re
from collections import Counter

c = Counter()
try:
    for entry in os.listdir("\\\\.\\pipe\\"):
        # entries look like "<name> (1)", "<name> (2)" for additional instances
        base = re.sub(r"\s*\(\d+\)$", "", entry)
        c[base] += 1
except OSError as e:
    print("listdir failed:", e)

print("distinct pipe names:", len(c))
print("total pipe instances:", sum(c.values()))
print()
print("--- top 25 names by instance count ---")
for name, n in c.most_common(25):
    print(f"{n:6d}  {name}")
