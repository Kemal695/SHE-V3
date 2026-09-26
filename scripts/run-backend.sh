#!/usr/bin/env bash
# Restart the SHE V3 backend the same way run-backend.cmd does, but from bash.
#
# The repo's mvn launcher is broken in this shell (the wrapper cannot find
# org.codehaus.plexus.classworlds.launcher.Launcher because M2_HOME is unset),
# so we invoke Maven's launcher class directly with Windows-style paths.
#
# .env is parsed rather than `source`d so that CRLF endings and base64 values
# containing '=' are handled correctly.

set -u

# Derive the repo root from this script's own location. This used to be a
# hardcoded `cd /d/she-v3/backend`, which broke the moment the checkout moved
# (it now lives at "D:/project X/she-v3/she-v3").
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKEND_DIR="$REPO_ROOT/backend"

cd "$BACKEND_DIR" || exit 1

# Maven is installed per-machine; override with MAVEN_HOME or M2_HOME.
M2="${MAVEN_HOME:-${M2_HOME:-C:/tools/apache-maven-3.9.16}}"

set -a
while IFS='=' read -r k v; do
  k="${k%$'\r'}"; v="${v%$'\r'}"
  # trim leading/trailing whitespace
  k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  case "$k" in ''|'#'*) continue ;; esac
  export "$k=$v"
done < .env
set +a

export SPRING_PROFILES_ACTIVE=local

exec java -classpath "$M2/boot/plexus-classworlds-2.11.0.jar" \
  "-Dclassworlds.conf=$M2/bin/m2.conf" \
  "-Dmaven.home=$M2" \
  "-Dmaven.multiModuleProjectDirectory=$BACKEND_DIR" \
  org.codehaus.plexus.classworlds.launcher.Launcher -o spring-boot:run
