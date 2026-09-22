#!/usr/bin/env python3
"""SHE V3 — infrastructure control tuned for a 2-core laptop.

WHY THIS EXISTS
---------------
`docker compose up` starts every service in infra/docker-compose.yml, which
includes THREE separate EMQX nodes. Each EMQX is an Erlang VM. On this dev
machine (Intel i5-6200U, 2 physical cores / 4 threads, 2015) starting all of
them spikes every core at once — and this laptop has hard-crashed four times
(Windows Event 41, no clean shutdown) under exactly that kind of all-core load
while on battery.

The three-node EMQX cluster is only needed when you are actually testing
clustering or cross-node revocation. For ordinary firmware / backend / app work
you need ONE broker.

USAGE
    python scripts/infra.py lite     # postgres, redis, emqx-1, step-ca, minio  (5)
    python scripts/infra.py full     # everything, including emqx-2/3 + crl-server (8)
    python scripts/infra.py status   # what is up, and what it is costing
    python scripts/infra.py down     # stop the stack

NOT INCLUDED IN 'lite'
    emqx-2, emqx-3  — cluster mesh members. Only for cluster/revocation testing.
    crl-server      — CRL distribution point. Only for revocation testing.

BEFORE RUNNING
    Keep the machine on mains. All four recorded crashes happened while
    discharging; the battery cannot supply the startup current spike.
"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
COMPOSE_FILE = REPO / "infra" / "docker-compose.yml"

# Minimal set for day-to-day work: one broker, not three.
LITE = ["postgres", "redis", "emqx-1", "step-ca", "minio"]

# Full stack — cluster + CRL distribution. Heavy; expect all cores to spike.
FULL = LITE + ["emqx-2", "emqx-3", "crl-server"]


def run(cmd, check=True):
    """Run a command, streaming output. Returns (ok, combined_output)."""
    proc = subprocess.run(
        cmd, cwd=str(REPO), capture_output=True, text=True, shell=False
    )
    out = (proc.stdout or "") + (proc.stderr or "")
    if check and proc.returncode != 0:
        print(out, file=sys.stderr)
        sys.exit(proc.returncode)
    return proc.returncode == 0, out


def need_docker():
    if shutil.which("docker") is None:
        sys.exit("docker not found on PATH — is Docker Desktop installed?")
    ok, _ = run(["docker", "info"], check=False)
    if not ok:
        sys.exit(
            "Docker daemon not reachable.\n"
            "Start Docker Desktop first, then wait for it to report 'running'."
        )


def warn_power():
    """The four recorded crashes all happened while discharging."""
    ok, out = run(
        [
            "powershell", "-NoProfile", "-Command",
            "(Get-CimInstance Win32_Battery).BatteryStatus",
        ],
        check=False,
    )
    status = out.strip().splitlines()[-1].strip() if out.strip() else ""
    if status == "1":
        print()
        print("  *** WARNING: this laptop is on BATTERY (discharging). ***")
        print("  All four recorded hard crashes happened while discharging.")
        print("  Plug in the charger before starting the stack.")
        print()


def cmd_up(services, label):
    need_docker()
    warn_power()
    print(f"  starting {label}: {' '.join(services)}")
    # Start one at a time, with a pause. A cold simultaneous start is what
    # spikes every core; staggering it keeps the machine responsive.
    for svc in services:
        print(f"    -> {svc}")
        run(["docker", "compose", "-f", str(COMPOSE_FILE), "up", "-d", svc])
    print()
    cmd_status()


def cmd_down():
    need_docker()
    print("  stopping stack (volumes are kept)")
    run(["docker", "compose", "-f", str(COMPOSE_FILE), "down"])


def cmd_status():
    need_docker()
    ok, out = run(["docker", "ps", "--format", "{{.Names}}\t{{.Status}}"], check=False)
    rows = [r for r in out.strip().splitlines() if r.strip()]
    print(f"  containers running: {len(rows)}")
    for r in rows:
        parts = r.split("\t")
        print(f"    {parts[0]:<22} {parts[1] if len(parts) > 1 else ''}")

    # WSL limits actually in force. Without a .wslconfig, WSL2 takes all cores.
    cfg = Path.home() / ".wslconfig"
    if cfg.exists():
        txt = cfg.read_text(encoding="utf-8", errors="replace")
        procs = next((l.split("=")[1].strip() for l in txt.splitlines()
                      if l.strip().startswith("processors")), "?")
        mem = next((l.split("=")[1].strip() for l in txt.splitlines()
                    if l.strip().startswith("memory")), "?")
        print(f"  WSL2 caps: processors={procs}  memory={mem}")
    else:
        print("  WSL2 caps: NONE — Docker can take all 4 threads and ~8 GB.")
        print("             Create ~/.wslconfig, then run: wsl --shutdown")

    if len(rows) > 5:
        print()
        print("  NOTE: >5 containers on a 2-core laptop. If you are not testing")
        print("  clustering or revocation, use 'lite' instead of 'full'.")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("action", choices=["lite", "full", "down", "status"])
    args = ap.parse_args()

    if args.action == "lite":
        cmd_up(LITE, "lite stack")
    elif args.action == "full":
        print("  full stack includes 3 EMQX VMs — expect all cores to spike")
        cmd_up(FULL, "full stack")
    elif args.action == "down":
        cmd_down()
    else:
        cmd_status()


if __name__ == "__main__":
    main()
