package et.she.v3.mqtt;

import et.she.v3.config.SheProperties;
import et.she.v3.energy.EnergyService;
import et.she.v3.entity.Node;
import et.she.v3.entity.NodeDevice;
import et.she.v3.entity.NodeParam;
import et.she.v3.repository.NodeDeviceRepository;
import et.she.v3.repository.NodeParamRepository;
import et.she.v3.repository.NodeRepository;
import et.she.v3.security.TenantContextInterceptor;
import et.she.v3.websocket.WsEventBus;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import org.eclipse.paho.client.mqttv3.*;
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;
import java.io.FileInputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/**
 * MQTT subscriber service — Spring Boot's link to the device fleet.
 *
 * V3-ARCHITECTURE §7.2 — shared subscription distributes messages across Spring Boot instances.
 * V3-MQTT-STANDARDS §7 — shared sub group `she-backend`.
 *
 * Subscribes to (shared), one subscription per device->cloud direction:
 *   $share/she-backend/she/+/+/+/+/telemetry
 *   $share/she-backend/she/+/+/+/+/status
 *   $share/she-backend/she/+/+/+/+/params/local
 *   $share/she-backend/she/+/+/+/+/energy
 *   $share/she-backend/she/+/+/+/+/ota/status
 *   $share/she-backend/she/+/+/+/+/ota/progress
 *
 * NOTE: MQTT topic filters support only `+` and `#` — there is NO regex alternation.
 * A combined filter such as `.../+/(telemetry|status|...)` is treated as a literal
 * 8-level topic, so it matches nothing AND is rejected by the broker ACL. That is why
 * each direction is subscribed separately (see DEVICE_PUBLISH_DIRECTIONS).
 *
 * V3-SECURITY-MODEL §4.4 — P1-10: backend uses client cert + explicit ACL, NO superuser.
 *
 * Message handlers (per direction):
 *   - config        → upsert node_devices + node_params (full self-description on connect)
 *   - params/local  → update node_params.last_value + push WebSocket node.state
 *   - telemetry     → INSERT into device_telemetry hypertable (via TelemetryService)
 *   - status        → update nodes.is_online + push WebSocket node.presence (P1-13: JSON payload)
 *   - energy        → INSERT into device_energy_readings + calculate cost_etb + push WebSocket energy.update
 *   - ota/status    → update ota_approvals + push WebSocket ota.progress
 *   - ota/progress  → update ota_approvals.progress + push WebSocket ota.progress
 */
@Service
public class MqttSubscriberService implements MqttCallbackExtended {

    private static final Logger log = LoggerFactory.getLogger(MqttSubscriberService.class);

    /**
     * Directions a device publishes to the cloud (V3-MQTT-STANDARDS §3).
     * Subscribed individually because MQTT topic filters have no regex support —
     * a single `(a|b|c)` alternation filter matches nothing and is ACL-denied.
     */
    private static final List<String> DEVICE_PUBLISH_DIRECTIONS = List.of(
            "telemetry", "status", "params/local", "energy", "ota/status", "ota/progress");

    private final SheProperties props;
    private final ObjectMapper objectMapper;
    private final NodeRepository nodeRepository;
    private final NodeDeviceRepository nodeDeviceRepository;
    private final NodeParamRepository nodeParamRepository;
    private final EnergyService energyService;
    private final TenantContextInterceptor tenantContextInterceptor;
    private final WsEventBus wsEventBus;
    private final org.springframework.jdbc.core.JdbcTemplate jdbcTemplate;

    /**
     * Opens a real transaction around MQTT ingest.
     *
     * <p>{@code processMessageWithRls} is called from {@code messageArrived} in this
     * same class, so a {@code @Transactional} annotation on it never takes effect —
     * Spring's proxy is bypassed on self-invocation. With no transaction, the
     * {@code SET LOCAL app.is_platform_admin} issued below is discarded by Postgres
     * ("SET LOCAL can only be used in transaction blocks"), the RLS GUCs are never
     * applied, and every ingest path fails to resolve its device: the log fills with
     * "telemetry from unknown MAC" and no telemetry/energy is ever stored.</p>
     *
     * <p>Driving the transaction programmatically keeps the GUC, the JdbcTemplate and
     * the JPA repositories bound to one connection for the whole dispatch.</p>
     */
    private final org.springframework.transaction.support.TransactionTemplate txTemplate;

    private IMqttAsyncClient mqttClient;
    private final ScheduledExecutorService reconnectExecutor = Executors.newSingleThreadScheduledExecutor();

    public MqttSubscriberService(SheProperties props,
                                 ObjectMapper objectMapper,
                                 NodeRepository nodeRepository,
                                 NodeDeviceRepository nodeDeviceRepository,
                                 NodeParamRepository nodeParamRepository,
                                 EnergyService energyService,
                                 TenantContextInterceptor tenantContextInterceptor,
                                 WsEventBus wsEventBus,
                                 org.springframework.jdbc.core.JdbcTemplate jdbcTemplate,
                                 org.springframework.transaction.PlatformTransactionManager txManager) {
        this.props = props;
        this.objectMapper = objectMapper;
        this.nodeRepository = nodeRepository;
        this.nodeDeviceRepository = nodeDeviceRepository;
        this.nodeParamRepository = nodeParamRepository;
        this.energyService = energyService;
        this.tenantContextInterceptor = tenantContextInterceptor;
        this.wsEventBus = wsEventBus;
        this.jdbcTemplate = jdbcTemplate;
        this.txTemplate = new org.springframework.transaction.support.TransactionTemplate(txManager);
    }

    @PostConstruct
    public void start() {
        try {
            connect();
        } catch (Exception e) {
            log.error("MQTT initial connect failed — will retry every 10s", e);
        }
        // Always-on watchdog: a single one-shot retry is not enough — a broker
        // restart (or a failed retry while the broker is still starting) used
        // to leave the subscriber disconnected forever with zero clients.
        reconnectExecutor.scheduleWithFixedDelay(this::safeReconnect, 10, 10, TimeUnit.SECONDS);
    }

    @PreDestroy
    public void stop() {
        try {
            if (mqttClient != null && mqttClient.isConnected()) {
                mqttClient.disconnect().waitForCompletion(5000);
            }
            if (mqttClient != null) {
                mqttClient.close();
            }
            reconnectExecutor.shutdownNow();
        } catch (Exception e) {
            log.warn("MQTT shutdown error: {}", e.getMessage());
        }
    }

    // =========================================================================
    // CONNECT
    // =========================================================================

    private void connect() throws Exception {
        String brokerUrl = props.mqtt().brokerUrl();
        String clientId = props.mqtt().clientIdPrefix() + "-" + UUID.randomUUID().toString().substring(0, 8);

        log.info("MQTT connecting: broker={} clientId={}", brokerUrl, clientId);

        MqttConnectOptions opts = new MqttConnectOptions();
        opts.setCleanSession(true);             // stateless — shared sub rebalances on reconnect
        opts.setAutomaticReconnect(false);      // we handle reconnect ourselves
        opts.setConnectionTimeout(10);
        opts.setKeepAliveInterval(30);
        opts.setMaxInflight(1000);

        // mTLS — P1-10: client cert + explicit ACL, NO superuser
        SSLOptions sslOpts = buildSslOptions();
        opts.setSocketFactory(sslOpts.sslContext().getSocketFactory());

        mqttClient = new MqttAsyncClient(brokerUrl, clientId, new MemoryPersistence());
        mqttClient.setCallback(this);

        // Connect + subscribe
        IMqttToken token = mqttClient.connect(opts);
        token.waitForCompletion(15000);
        log.info("MQTT connected");

        // Shared subscription — V3-ARCHITECTURE §7.2
        // One subscription per direction: MQTT has no regex topic filters, so the old
        // `.../+/(telemetry|status|...)` filter matched nothing and was ACL-denied.
        for (String direction : DEVICE_PUBLISH_DIRECTIONS) {
            String sharedTopic = "$share/" + props.mqtt().sharedSubscriptionGroup() +
                    "/she/+/+/+/+/" + direction;
            mqttClient.subscribe(sharedTopic, 1).waitForCompletion();
            log.info("MQTT subscribed to: {}", sharedTopic);
        }

        // Also subscribe to `config` NON-shared (full self-description on connect — don't miss during instance restart)
        String configTopic = "she/+/+/+/+/config";
        mqttClient.subscribe(configTopic, 1).waitForCompletion();
        log.info("MQTT subscribed to: {}", configTopic);
    }

    private void safeReconnect() {
        try {
            if (mqttClient == null || !mqttClient.isConnected()) {
                log.info("MQTT reconnecting...");
                connect();
            }
        } catch (Exception e) {
            log.warn("MQTT reconnect failed: {} (cause: {})", e.getMessage(),
                    e.getCause() != null ? e.getCause().toString() : "none", e);
        }
    }

    private SSLOptions buildSslOptions() throws Exception {
        // Load CA bundle (root + intermediate) for server cert verification
        CertificateFactory cf = CertificateFactory.getInstance("X.509");
        KeyStore trustStore = KeyStore.getInstance(KeyStore.getDefaultType());
        trustStore.load(null, null);
        byte[] caBundleBytes = Files.readAllBytes(Path.of(props.mqtt().caBundlePath()));
        // Parse all certs in the bundle
        var certs = cf.generateCertificates(new java.io.ByteArrayInputStream(caBundleBytes));
        int i = 0;
        for (var cert : certs) {
            trustStore.setCertificateEntry("ca-" + i, (X509Certificate) cert);
            i++;
        }

        TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        tmf.init(trustStore);

        // Load backend client cert + key into a KeyStore (PKCS12 from PEM)
        // For simplicity in dev, we load PEM files. In prod, use PKCS12/HSM.
        KeyStore keyStore = PemToKeyStore.convert(
                props.mqtt().backendCertPath(),
                props.mqtt().backendKeyPath()
        );

        KeyManagerFactory kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        kmf.init(keyStore, new char[0]);

        SSLContext sslContext = SSLContext.getInstance("TLSv1.3");
        sslContext.init(kmf.getKeyManagers(), tmf.getTrustManagers(), null);
        return new SSLOptions(sslContext);
    }

    private record SSLOptions(SSLContext sslContext) {}

    // =========================================================================
    // MqttCallbackExtended
    // =========================================================================

    @Override
    public void connectComplete(boolean reconnect, String serverURI) {
        if (reconnect) {
            log.info("MQTT reconnected to {}", serverURI);
            try {
                for (String direction : DEVICE_PUBLISH_DIRECTIONS) {
                    String sharedTopic = "$share/" + props.mqtt().sharedSubscriptionGroup() +
                            "/she/+/+/+/+/" + direction;
                    mqttClient.subscribe(sharedTopic, 1).waitForCompletion();
                }
                mqttClient.subscribe("she/+/+/+/+/config", 1).waitForCompletion();
            } catch (Exception e) {
                log.error("MQTT re-subscribe failed", e);
            }
        }
    }

    @Override
    public void connectionLost(Throwable cause) {
        log.warn("MQTT connection lost: {}", cause.getMessage());
        reconnectExecutor.schedule(this::safeReconnect, 5, TimeUnit.SECONDS);
    }

    @Override
    public void messageArrived(String topic, MqttMessage message) {
        try {
            String payload = new String(message.getPayload());
            log.debug("MQTT msg: topic={} payloadLen={}", topic, payload.length());

            // Parse topic: she/{tenant}/{home}/{room}/{mac}/{direction}[/{sub}]
            String[] parts = topic.split("/");
            if (parts.length < 6 || !"she".equals(parts[0])) {
                log.warn("Ignoring malformed topic: {}", topic);
                return;
            }
            String tenantShort = parts[1];
            String homeShort = parts[2];
            String roomShort = parts[3];
            String mac = parts[4];
            // Reconstruct full direction (handles multi-segment like "params/local", "ota/status")
            String direction = parts[5];
            if (parts.length > 6) direction += "/" + parts[6];

            processMessageWithRls(direction, mac, payload, topic);
        } catch (Exception e) {
            log.error("Error processing MQTT message on topic {}: {}", topic, e.getMessage(), e);
        }
    }

    /**
     * Dispatch one device message inside a transaction whose RLS context is
     * "platform admin" — device traffic is not tied to a tenant, and resolving
     * the device already requires reading across tenants.
     *
     * <p>Note: deliberately NOT annotated {@code @Transactional}. This method is
     * called from {@code messageArrived} in the same class, so the annotation would
     * be silently ignored (self-invocation bypasses the Spring proxy) and the
     * {@code SET LOCAL} would be discarded. {@link #txTemplate} opens the
     * transaction explicitly instead.</p>
     */
    public void processMessageWithRls(String direction, String mac, String payload, String topic) throws Exception {
        txTemplate.execute(status -> {
            if (jdbcTemplate != null) {
                jdbcTemplate.execute("SET LOCAL app.is_platform_admin = 'true'");
            }
            // Dispatch by direction
            try {
                switch (direction) {
                    case "config"           -> handleConfigMessage(mac, payload);
                    case "params/local"     -> handleParamsLocal(mac, payload);
                    case "telemetry"        -> handleTelemetry(mac, payload);
                    case "status"           -> handleStatus(mac, payload);
                    case "energy"           -> handleEnergy(mac, payload);
                    case "ota/status"       -> handleOtaStatus(mac, payload);
                    case "ota/progress"     -> handleOtaProgress(mac, payload);
                    default -> log.warn("Unknown direction '{}' on topic {}", direction, topic);
                }
            } catch (Exception e) {
                // Roll the transaction back and surface the cause to the caller's
                // existing catch block.
                throw new IllegalStateException(e);
            }
            return null;
        });
    }

    @Override
    public void deliveryComplete(IMqttDeliveryToken token) {
        // No-op — we're a subscriber, not a publisher (MqttPublishService handles publishes)
    }

    // =========================================================================
    // HANDLERS
    // =========================================================================

    /**
     * config — device publishes full self-description on connect.
     * Upsert nodes + node_devices + node_params from RainMaker hierarchy.
     */
    private void handleConfigMessage(String mac, String payload) throws Exception {
        JsonNode root = objectMapper.readTree(payload);
        String nodeId = root.path("node_id").asText();
        String sku = root.path("model").asText();
        String firmwareVersion = root.path("firmware").path("version").asText();
        String hwRev = root.path("hw_rev").asText();

        // Find node by normalized_mac
        var nodeOpt = nodeRepository.findByNormalizedMac(mac);
        if (nodeOpt.isEmpty()) {
            log.warn("Config from unknown MAC {} — ignoring (not registered in device_certs)", mac);
            return;
        }
        Node node = nodeOpt.get();

        // Update firmware_version + hardware_revision
        node.setFirmwareVersion(firmwareVersion);
        node.setHardwareRevision(hwRev);
        node.setOnline(true);
        node.setLastSeenAt(Instant.now());
        nodeRepository.save(node);

        // Upsert node_devices + node_params from the "devices" array
        JsonNode devicesNode = root.path("devices");
        for (JsonNode devNode : devicesNode) {
            String deviceName = devNode.path("name").asText();
            String deviceType = devNode.path("type").asText();

            NodeDevice device = nodeDeviceRepository.findByNodeAndName(node.getId(), deviceName)
                    .orElseGet(() -> {
                        NodeDevice d = new NodeDevice();
                        d.setTenantId(node.getTenantId());
                        d.setNodeId(node.getId());
                        d.setDeviceName(deviceName);
                        return d;
                    });
            device.setDeviceType(deviceType);
            if (devNode.has("attributes")) {
                device.setAttributes(objectMapper.convertValue(devNode.path("attributes"), Map.class));
            }
            if (devNode.has("channel")) {
                device.setChannelIndex((short) devNode.path("channel").asInt());
            }
            nodeDeviceRepository.save(device);

            // Upsert params
            JsonNode paramsNode = devNode.path("params");
            for (JsonNode paramNode : paramsNode) {
                String paramName = paramNode.path("name").asText();
                String paramType = paramNode.path("type").asText();
                String dataType = paramNode.path("data_type").asText();

                NodeParam param = nodeParamRepository.findByDeviceAndName(device.getId(), paramName)
                        .orElseGet(() -> {
                            NodeParam p = new NodeParam();
                            p.setTenantId(node.getTenantId());
                            p.setNodeId(node.getId());
                            p.setNodeDeviceId(device.getId());
                            p.setParamName(paramName);
                            p.setParamType(paramType);
                            p.setDataType(dataType);
                            return p;
                        });
                if (paramNode.has("properties")) {
                    param.setProperties(objectMapper.convertValue(paramNode.path("properties"), List.class));
                }
                if (paramNode.has("value")) {
                    param.setLastValue(paramNode.path("value"));
                    param.setLastReportedAt(Instant.now());
                }
                nodeParamRepository.save(param);
            }
        }

        // Upsert services (same table, is_service=true via trigger)
        JsonNode servicesNode = root.path("services");
        for (JsonNode svcNode : servicesNode) {
            String svcName = svcNode.path("name").asText();
            String svcType = svcNode.path("type").asText();

            NodeDevice svc = nodeDeviceRepository.findByNodeAndName(node.getId(), svcName)
                    .orElseGet(() -> {
                        NodeDevice d = new NodeDevice();
                        d.setTenantId(node.getTenantId());
                        d.setNodeId(node.getId());
                        d.setDeviceName(svcName);
                        return d;
                    });
            svc.setDeviceType(svcType);
            nodeDeviceRepository.save(svc);

            JsonNode svcParams = svcNode.path("params");
            for (JsonNode paramNode : svcParams) {
                String paramName = paramNode.path("name").asText();
                String paramType = paramNode.path("type").asText();
                String dataType = paramNode.path("data_type").asText();

                NodeParam param = nodeParamRepository.findByDeviceAndName(svc.getId(), paramName)
                        .orElseGet(() -> {
                            NodeParam p = new NodeParam();
                            p.setTenantId(node.getTenantId());
                            p.setNodeId(node.getId());
                            p.setNodeDeviceId(svc.getId());
                            p.setParamName(paramName);
                            p.setParamType(paramType);
                            p.setDataType(dataType);
                            return p;
                        });
                if (paramNode.has("properties")) {
                    param.setProperties(objectMapper.convertValue(paramNode.path("properties"), List.class));
                }
                nodeParamRepository.save(param);
            }
        }

        log.info("Config upserted for node {} (mac={}, {} devices, {} services)",
                node.getNodeId(), mac, devicesNode.size(), servicesNode.size());

        // Push WebSocket node.presence (online)
        wsEventBus.publishNodePresence(node.getTenantId(), node.getHomeId(), node.getId(), true, node.getLastSeenAt());
    }

    /**
     * params/local — device reports current param values (every 5s).
     * Update node_params.last_value + push WebSocket node.state.
     */
    private void handleParamsLocal(String mac, String payload) throws Exception {
        JsonNode root = objectMapper.readTree(payload);
        var nodeOpt = nodeRepository.findByNormalizedMac(mac);
        if (nodeOpt.isEmpty()) {
            log.warn("params/local from unknown MAC {}", mac);
            return;
        }
        Node node = nodeOpt.get();

        // Mark online + last_seen
        nodeRepository.updatePresence(node.getId(), true, Instant.now());

        // Iterate devices in payload
        root.fields().forEachRemaining(entry -> {
            String deviceName = entry.getKey();
            JsonNode deviceParams = entry.getValue();
            nodeDeviceRepository.findByNodeAndName(node.getId(), deviceName).ifPresent(device -> {
                deviceParams.fields().forEachRemaining(paramEntry -> {
                    String paramName = paramEntry.getKey();
                    JsonNode valueNode = paramEntry.getValue();
                    nodeParamRepository.findByDeviceAndName(device.getId(), paramName).ifPresent(param -> {
                        // Update last_value (JSONB cache)
                        Object value = objectMapper.convertValue(valueNode, Object.class);
                        nodeParamRepository.updateLastValue(param.getId(), value, Instant.now());

                        // Push WebSocket node.state
                        wsEventBus.publishNodeState(node.getTenantId(), node.getHomeId(), node.getId(),
                                device.getId(), deviceName, paramName, valueNode);
                    });
                });
            });
        });
    }

    /**
     * telemetry — device diagnostics (RSSI, heap, uptime). Every 30s.
     * INSERT into device_telemetry hypertable.
     */
    private void handleTelemetry(String mac, String payload) throws Exception {
        JsonNode root = objectMapper.readTree(payload);
        var nodeOpt = nodeRepository.findByNormalizedMac(mac);
        if (nodeOpt.isEmpty()) {
            log.warn("telemetry from unknown MAC {}", mac);
            return;
        }
        Node node = nodeOpt.get();

        // Find the Diagnostics service device
        var devices = nodeDeviceRepository.findAllByNodeId(node.getId());
        var diagOpt = devices.stream()
                .filter(d -> "esp.service.diag".equals(d.getDeviceType()))
                .findFirst();
        if (diagOpt.isEmpty()) return;
        NodeDevice diag = diagOpt.get();

        // Insert each telemetry field as a row in device_telemetry
        Instant now = Instant.now();
        insertTelemetryRow(now, node, diag.getId(), "Uptime", root.path("uptime_s").asDouble(), "s");
        insertTelemetryRow(now, node, diag.getId(), "RSSI", root.path("rssi_dbm").asDouble(), "dBm");
        insertTelemetryRow(now, node, diag.getId(), "Free_Heap", root.path("free_heap_bytes").asDouble(), "bytes");
        insertTelemetryRow(now, node, diag.getId(), "Min_Free_Heap", root.path("min_free_heap_bytes").asDouble(), "bytes");
        insertTelemetryRow(now, node, diag.getId(), "WiFi_Disconnects", root.path("wifi_disconnects").asDouble(), "count");
        insertTelemetryRow(now, node, diag.getId(), "MQTT_Reconnects", root.path("mqtt_reconnects").asDouble(), "count");

        // Push WebSocket node.telemetry
        wsEventBus.publishNodeTelemetry(node.getTenantId(), node.getHomeId(), node.getId(), root);
    }

    private void insertTelemetryRow(Instant time, Node node, UUID deviceId,
                                    String paramName, double value, String unit) {
        if (value == 0 && "count".equals(unit)) return;   // skip zero counts
        try {
            energyService.insertTelemetry(time, node.getTenantId(), node.getId(), deviceId, paramName, value, unit);
        } catch (Exception e) {
            log.debug("Telemetry insert failed for {}: {}", paramName, e.getMessage());
        }
    }

    /**
     * status — device presence (online/offline). P1-13: JSON payload.
     * Update nodes.is_online + push WebSocket node.presence.
     */
    private void handleStatus(String mac, String payload) throws Exception {
        JsonNode root = objectMapper.readTree(payload);
        String status = root.path("status").asText();
        var nodeOpt = nodeRepository.findByNormalizedMac(mac);
        if (nodeOpt.isEmpty()) {
            log.warn("status from unknown MAC {}", mac);
            return;
        }
        Node node = nodeOpt.get();

        boolean online = "online".equals(status);
        nodeRepository.updatePresence(node.getId(), online, Instant.now());
        log.info("Node {} status={}", node.getNodeId(), status);

        wsEventBus.publishNodePresence(node.getTenantId(), node.getHomeId(), node.getId(), online, Instant.now());
    }

    /**
     * energy — PZEM-004T reading (every 5s). Short-form keys per V3-MQTT-STANDARDS §8.7.
     * INSERT into device_energy_readings + calculate cost_etb + push WebSocket energy.update.
     */
    private void handleEnergy(String mac, String payload) throws Exception {
        JsonNode root = objectMapper.readTree(payload);
        var nodeOpt = nodeRepository.findByNormalizedMac(mac);
        if (nodeOpt.isEmpty()) {
            log.warn("energy from unknown MAC {}", mac);
            return;
        }
        Node node = nodeOpt.get();

        double voltage = root.path("v").asDouble();
        double current = root.path("i").asDouble();
        double powerW = root.path("p").asDouble();
        double energyWh = root.path("wh").asDouble();
        double pf = root.path("pf").asDouble();
        double freq = root.path("freq").asDouble();

        // Ingest + calculate cost
        energyService.ingestEnergyReading(
                Instant.now(), node.getTenantId(), node.getId(),
                voltage, current, powerW, energyWh, pf, freq
        );

        // Push WebSocket energy.update + node.telemetry
        wsEventBus.publishEnergyUpdate(node.getTenantId(), node.getHomeId(), node.getId(), powerW, energyWh);
    }

    /**
     * ota/status — device reports OTA lifecycle (downloading/flashing/complete/failed).
     * Update ota_approvals + push WebSocket ota.progress.
     */
    private void handleOtaStatus(String mac, String payload) throws Exception {
        JsonNode root = objectMapper.readTree(payload);
        String status = root.path("status").asText();
        String version = root.path("version").asText();
        String error = root.path("error").asText(null);

        log.info("OTA status: mac={} status={} version={}", mac, status, version);
        var nodeOpt = nodeRepository.findByNormalizedMac(mac);
        UUID tenantId = nodeOpt.map(Node::getTenantId).orElse(null);

        wsEventBus.publishOtaProgress(tenantId, mac, status, null, version);
    }

    /**
     * ota/progress — device reports OTA download/flash percentage.
     */
    private void handleOtaProgress(String mac, String payload) throws Exception {
        JsonNode root = objectMapper.readTree(payload);
        int percent = root.path("percent").asInt();
        long bytesDone = root.path("bytes_done").asLong();
        long bytesTotal = root.path("bytes_total").asLong();

        log.debug("OTA progress: mac={} {}% ({}/{})", mac, percent, bytesDone, bytesTotal);
        var nodeOpt = nodeRepository.findByNormalizedMac(mac);
        UUID tenantId = nodeOpt.map(Node::getTenantId).orElse(null);

        wsEventBus.publishOtaProgress(tenantId, mac, "IN_PROGRESS", percent, null);
    }
}
