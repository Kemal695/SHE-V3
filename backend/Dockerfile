# =============================================================================
# SHE V3 backend — Dockerfile (multi-stage build)
# =============================================================================
# Builds a slim runtime image with the Spring Boot fat jar.
# Used by GitHub Actions to push to ghcr.io/she-v3/she-backend:sha-<git-sha>
# =============================================================================

# ---------- Stage 1: Build ----------
FROM maven:3.9.9-eclipse-temurin-21 AS builder

WORKDIR /build

# Cache Maven dependencies separately (faster rebuilds)
COPY pom.xml .
RUN mvn dependency:go-offline -B

# Copy source + build
COPY src ./src
RUN mvn clean package -DskipTests -B \
    && mv target/she-backend.jar /build/she-backend.jar

# ---------- Stage 2: Runtime ----------
FROM eclipse-temurin:21-jre-jammy

# Install curl for health probes + ca-certificates for TLS
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd --system she-app \
    && useradd --system --gid she-app --home-dir /opt/she-backend --shell /usr/sbin/nologin she-app

WORKDIR /opt/she-backend

# Copy the built jar
COPY --from=builder /build/she-backend.jar /opt/she-backend/she-backend.jar

# Copy entrypoint script
COPY entrypoint.sh /opt/she-backend/entrypoint.sh
RUN chmod +x /opt/she-backend/entrypoint.sh

# Create writable directories
RUN mkdir -p /var/log/she /var/cache/she /etc/she/certs /etc/she/ca /etc/she/keys \
    && chown -R she-app:she-app /var/log/she /var/cache/she /etc/she /opt/she-backend

USER she-app

EXPOSE 8080 9090

ENTRYPOINT ["/opt/she-backend/entrypoint.sh"]

# Health probe — Spring Boot Actuator
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=12 \
    CMD curl -sf http://localhost:8080/actuator/health | grep -q '"status":"UP"' || exit 1
