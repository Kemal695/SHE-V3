#!/bin/sh
# SHE V3 backend container entrypoint.
# Sets JVM flags from JAVA_TOOL_OPTIONS env, then launches the Spring Boot jar.
set -e

# Default JVM flags if not overridden
JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:--XX:MaxRAMPercentage=75 -XX:+UseG1GC -XX:+ExitOnOutOfMemoryError -Djava.security.egd=file:/dev/./urandom}"
export JAVA_TOOL_OPTIONS

# Spring profile
SPRING_PROFILES_ACTIVE="${SPRING_PROFILES_ACTIVE:-staging}"
export SPRING_PROFILES_ACTIVE

exec java -jar /opt/she-backend/she-backend.jar
