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

ENV_PATH = r"D:\she-v3\backend\.env"
BACKEND_DIR = r"D:\she-v3\backend"

MAVEN_BOOT = "C:/tools/apache-maven-3.9.16/boot/plexus-classworlds-2.11.0.jar"
MAVEN_CONF = "C:/tools/apache-maven-3.9.16/bin/m2.conf"
MAVEN_HOME = "C:/tools/apache-maven-3.9.16"


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
        "-B", "-o", "spring-boot:run",
    ]
    os.chdir(BACKEND_DIR)
    return subprocess.call(cmd, env=os.environ)


if __name__ == "__main__":
    sys.exit(main())
