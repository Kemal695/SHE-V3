package et.she.v3.mqtt;

import et.she.v3.config.SheProperties;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.annotation.PostConstruct;
import org.eclipse.paho.client.mqttv3.*;
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.Map;
import java.util.UUID;

/**
 * MQTT publish service — Spring Boot → device commands.
 *
 * V3-MQTT-STANDARDS §3 — publishes to:
 *   - she/{tenant}/{home}/{room}/{mac}/command      (QoS 1, not retained)
 *   - she/{tenant}/{home}/{room}/{mac}/params/remote (QoS 1, not retained — DB-backed shadow)
 *   - she/{tenant}/{home}/{room}/{mac}/ota/url       (QoS 1, not retained)
 *
 * P1-10: backend uses client cert + explicit ACL — publishes to these topics
 * are allowed by EMQX's file-based ACL rules (she/+/+/+/+/command etc.)
 */
@Service
public class MqttPublishService {

    private static final Logger log = LoggerFactory.getLogger(MqttPublishService.class);

    private final SheProperties props;
    private final ObjectMapper objectMapper;
    private IMqttAsyncClient publishClient;

    public MqttPublishService(SheProperties props, ObjectMapper objectMapper) {
        this.props = props;
        this.objectMapper = objectMapper;
    }

    @PostConstruct
    public void init() {
        // Lazy connect — publishClient is created on first publish to avoid blocking startup
        // if MQTT broker isn't ready yet (MqttSubscriberService handles reconnect for subscription).
    }

    /**
     * Publish a parameter command to a device.
     *
     * V3-MQTT-STANDARDS §3.4 — params/remote payload:
     *   {"Relay 1":{"Power":true}, "seq":12345, "ts":"2024-10-22T14:23:11Z"}
     */
    public void publishParamsRemote(String tenantShort, String homeShort, String roomShort,
                                    String normalizedMac, Map<String, ?> deviceParams,
                                    long seq) throws Exception {
        String topic = String.format("she/%s/%s/%s/%s/params/remote",
                tenantShort, homeShort, roomShort, normalizedMac);

        Map<String, Object> payload = new java.util.LinkedHashMap<>(deviceParams);
        payload.put("seq", seq);
        payload.put("ts", java.time.Instant.now().toString());

        publish(topic, 1, false, objectMapper.writeValueAsBytes(payload));
        log.info("Published params/remote: mac={} params={} seq={}", normalizedMac, deviceParams.keySet(), seq);
    }

    /**
     * Publish a command (reboot / factory_reset / sync_time / ping).
     *
     * V3-MQTT-STANDARDS §3.2 — command payload:
     *   {"cmd":"reboot","reason":"user_initiated","seq":8392,"ts":"2024-10-22T14:23:11Z"}
     */
    public void publishCommand(String tenantShort, String homeShort, String roomShort,
                               String normalizedMac, String cmd, String reason, long seq) throws Exception {
        publishCommand(tenantShort, homeShort, roomShort, normalizedMac, cmd, reason, seq, null);
    }

    /**
     * @param extra optional additional fields merged into the payload (e.g. hour/minute/
     *              days_mask for `schedule_add`). Null or empty is fine.
     *
     * Uses a mutable HashMap, NOT Map.of — Map.of throws NPE on a null value, which
     * would take down a command publish over a missing optional field.
     */
    public void publishCommand(String tenantShort, String homeShort, String roomShort,
                               String normalizedMac, String cmd, String reason, long seq,
                               Map<String, Object> extra) throws Exception {
        String topic = String.format("she/%s/%s/%s/%s/command",
                tenantShort, homeShort, roomShort, normalizedMac);

        Map<String, Object> payload = new java.util.HashMap<>();
        payload.put("cmd", cmd);
        payload.put("reason", reason);
        payload.put("seq", seq);
        payload.put("ts", java.time.Instant.now().toString());
        if (extra != null) {
            for (Map.Entry<String, Object> e : extra.entrySet()) {
                if (e.getValue() != null) payload.put(e.getKey(), e.getValue());
            }
        }

        publish(topic, 1, false, objectMapper.writeValueAsBytes(payload));
        log.info("Published command: mac={} cmd={} seq={} extra={}",
                normalizedMac, cmd, seq, extra == null ? "-" : extra.keySet());
    }

    /**
     * Publish OTA trigger to a device.
     *
     * V3-MQTT-STANDARDS §3.8 — ota/url payload:
     *   {"version":"1.5.0","secure_version":15,"url":"https://minio.she.et/...",
     *    "sig":"base64-ed25519-sig","size":1245184,"min_hw_rev":"rev-b",
     *    "seq":8393,"ts":"2024-10-22T14:23:11Z"}
     */
    public void publishOtaUrl(String tenantShort, String homeShort, String roomShort,
                              String normalizedMac, Map<String, Object> otaPayload, long seq) throws Exception {
        String topic = String.format("she/%s/%s/%s/%s/ota/url",
                tenantShort, homeShort, roomShort, normalizedMac);

        Map<String, Object> payload = new java.util.LinkedHashMap<>(otaPayload);
        payload.put("seq", seq);
        payload.put("ts", java.time.Instant.now().toString());

        publish(topic, 1, false, objectMapper.writeValueAsBytes(payload));
        log.info("Published ota/url: mac={} version={}", normalizedMac, otaPayload.get("version"));
    }

    // =========================================================================
    // Internals
    // =========================================================================

    /**
     * Reuse the connected client (H9 fix). The old code tore down + rebuilt
     * the mTLS connection on EVERY publish (slow, and a leak on failure paths).
     * Now: return fast when connected; otherwise close the stale client first
     * so no orphaned connections accumulate.
     */
    private synchronized void ensureConnected() throws Exception {
        if (publishClient != null && publishClient.isConnected()) {
            return;
        }
        if (publishClient != null) {
            try {
                publishClient.close();
            } catch (Exception ignored) {}
            publishClient = null;
        }

        String brokerUrl = props.mqtt().brokerUrl();
        String clientId = props.mqtt().clientIdPrefix() + "-pub-" + UUID.randomUUID().toString().substring(0, 8);

        MqttConnectOptions opts = new MqttConnectOptions();
        opts.setCleanSession(true);
        opts.setConnectionTimeout(10);
        opts.setKeepAliveInterval(30);

        // mTLS (same cert as subscriber)
        SSLOptions sslOpts = buildSslOptions();
        opts.setSocketFactory(sslOpts.sslContext().getSocketFactory());

        publishClient = new MqttAsyncClient(brokerUrl, clientId, new MemoryPersistence());
        publishClient.connect(opts).waitForCompletion(15000);
        log.info("MQTT publish client connected: {}", brokerUrl);
    }

    private void publish(String topic, int qos, boolean retained, byte[] payload) throws Exception {
        ensureConnected();
        MqttMessage message = new MqttMessage(payload);
        message.setQos(qos);
        message.setRetained(retained);
        publishClient.publish(topic, message).waitForCompletion(5000);
    }

    private SSLOptions buildSslOptions() throws Exception {
        CertificateFactory cf = CertificateFactory.getInstance("X.509");
        KeyStore trustStore = KeyStore.getInstance(KeyStore.getDefaultType());
        trustStore.load(null, null);
        byte[] caBundleBytes = Files.readAllBytes(Path.of(props.mqtt().caBundlePath()));
        var certs = cf.generateCertificates(new java.io.ByteArrayInputStream(caBundleBytes));
        int i = 0;
        for (var cert : certs) {
            trustStore.setCertificateEntry("ca-" + i, (X509Certificate) cert);
            i++;
        }
        TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        tmf.init(trustStore);

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
}
