"""Launch the SHE V3 backend with backend/.env loaded literally.

Why not `source .env` in bash: values such as JWT_SIGNING_PUBLIC_KEYS contain
JSON ({"kid":"2025q1","public_key_pem":"-----BEGIN PUBLIC KEY-----\\n..."}).
Bash performs brace expansion and strips the double quotes, turning valid JSON
into `[{kid:2025q1,...}` -> Jackson fails with
"Unexpected character ('k'): was expecting double-quote to start field name"
and the whole Spring context fails to start.

This loader splits on the FIRST '=' only and performs no shell interpretation.
"""
import os
import subprocess
import sys
from pathlib import Path

# Derive the repo location from this file rather than hardcoding it. These were
# absolute (D:\she-v3\...), which broke silently every time the checkout moved —
# and it did move, to "D:\project X\she-v3\she-v3".
REPO_ROOT = Path(__file__).resolve().parent.parent
BACKEND_DIR = REPO_ROOT / "backend"
ENV_PATH = BACKEND_DIR / ".env"

# Maven is installed per-machine, so keep its location overridable instead of
# hardcoded. MAVEN_HOME/M2_HOME win; the path below is only a fallback.
MAVEN_HOME = (
    os.environ.get("MAVEN_HOME")
    or os.environ.get("M2_HOME")
    or r"C:\tools\apache-maven-3.9.16"
)
MAVEN_BOOT = str(Path(MAVEN_HOME) / "boot" / "plexus-classworlds-2.11.0.jar")
MAVEN_CONF = str(Path(MAVEN_HOME) / "bin" / "m2.conf")

# Maven's offline flag (-o) is OPT-IN via SHE_MAVEN_OFFLINE=1.
#
# It used to be hardcoded, which is fatal on any machine whose ~/.m2 is empty or
# only partly populated: every resolution then fails instantly with "Cannot
# access central in offline mode", which reads like a broken build rather than a
# missing cache. A "is the repo non-empty?" heuristic is not good enough either,
# because a partially-filled cache passes it and then fails on the first missing
# artifact. Online mode still reads the local cache first and only reaches the
# network for what is genuinely absent, so it is strictly the safer default.
MAVEN_REPO = Path(
    os.environ.get("MAVEN_REPO_LOCAL") or (Path.home() / ".m2" / "repository")
)
OFFLINE = str(os.environ.get("SHE_MAVEN_OFFLINE", "0")).strip().lower() in (
    "1", "true", "yes", "on",
)


def load_env(path):
    loaded = 0
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\r\n")
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, value = line.split("=", 1)          # split on FIRST '=' only
            key = key.strip()
            value = value.strip()
            # Only unwrap if the whole value is quoted (never for JSON like [{".."}])
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            os.environ[key] = value
            loaded += 1
    return loaded


def main():
    # Fail with a readable message instead of a cryptic Maven/Java stack trace.
    if not ENV_PATH.exists():
        print(f"[launcher] ERROR: {ENV_PATH} not found.", file=sys.stderr)
        print("[launcher] Copy backend/.env.example to backend/.env and fill it in.",
              file=sys.stderr)
        return 1
    if not Path(MAVEN_BOOT).exists():
        print(f"[launcher] ERROR: Maven not found at {MAVEN_HOME}", file=sys.stderr)
        print("[launcher] Install Maven 3.9.x, or set MAVEN_HOME to it.",
              file=sys.stderr)
        return 1

    n = load_env(ENV_PATH)
    print(f"[launcher] loaded {n} vars from .env", flush=True)
    os.environ["SPRING_PROFILES_ACTIVE"] = "local"

    cmd = [
        "java",
        "-classpath", MAVEN_BOOT,
        f"-Dclassworlds.conf={MAVEN_CONF}",
        f"-Dmaven.home={MAVEN_HOME}",
        f"-Dmaven.multiModuleProjectDirectory={BACKEND_DIR}",
        "org.codehaus.plexus.classworlds.launcher.Launcher",
        "-B",
    ]
    if OFFLINE:
        cmd.append("-o")
    cmd.append("spring-boot:run")
    os.chdir(BACKEND_DIR)
    return subprocess.call(cmd, env=os.environ)


if __name__ == "__main__":
    sys.exit(main())
