#!/usr/bin/env python
"""Run Maven for the SHE V3 backend.

Why this exists: `mvn` is a .cmd launcher, and on this machine neither
`cmd //c "...\\mvn.cmd ..."` from Git Bash nor the PowerShell tool returns any
output (cmd prints only its banner, so a failing or succeeding build looks
identical and every "compile OK" reported that way is meaningless).

This invokes Maven's classworlds Launcher directly with `java`, exactly the way
the backend launcher (scripts/run-backend.py) does, which does produce output.

Usage:
    python scripts/run-maven.py test
    python scripts/run-maven.py -DskipTests package
    python scripts/run-maven.py clean test
"""
import os
import subprocess
import sys

BACKEND_DIR = r"D:\she-v3\backend"
MAVEN_BOOT = "C:/tools/apache-maven-3.9.16/boot/plexus-classworlds-2.11.0.jar"
MAVEN_CONF = "C:/tools/apache-maven-3.9.16/bin/m2.conf"
MAVEN_HOME = "C:/tools/apache-maven-3.9.16"


def main() -> int:
    goals = sys.argv[1:]
    if not goals:
        print(__doc__)
        return 2

    cmd = [
        "java",
        "-classpath", MAVEN_BOOT,
        f"-Dclassworlds.conf={MAVEN_CONF}",
        f"-Dmaven.home={MAVEN_HOME}",
        f"-Dmaven.multiModuleProjectDirectory={BACKEND_DIR}",
        "org.codehaus.plexus.classworlds.launcher.Launcher",
        "-B",
    ] + goals

    os.chdir(BACKEND_DIR)
    return subprocess.call(cmd, env=os.environ)


if __name__ == "__main__":
    raise SystemExit(main())
