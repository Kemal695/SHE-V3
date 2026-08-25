# V3 — Energy Monitoring

**Status:** Locked
**Last updated:** 2025-Q1
**Owner:** Backend Engineer + Firmware Contractor

---

## 0. Scope

Per-device energy monitoring using PZEM-004T v3 sensors on SHE-R8 and SHE-R16. SHE-R4 omits the sensor for cost (V3-HARDWARE.md §3.4). Users see real-time power consumption, historical trends, and monthly cost in ETB (Ethiopian Birr). B2B tenants get aggregate energy reports.

> **Update from original V3-ENERGY-MONITORING.md (Proposed):**
> - Energy data is now mapped to the RainMaker hierarchy (V3-DEVICE-MODEL.md) as Parameters on the Diagnostics Service. Previously it was a separate top-level concept.
> - ETB block tariff corrected to current Ethiopian Electric Utility (EEU) rates (Block 2 = 1.04, not 1.55; Block 3 = 1.30, not 2.20).
> - TimescaleDB compression policy documented (cross-ref V3-DATABASE-DESIGN.md §6).

---

## 1. Hardware

| Spec | Value |
|---|---|
| Sensor | PZEM-004T v3.0 |
| Measurement | Voltage (V), current (A), power (W), energy (kWh, cumulative), frequency (Hz), power factor |
| Interface | Modbus RTU over UART (TX/RX at 5 V, level-shifted to 3.3 V) |
| Accuracy | ±1% voltage, ±1% current |
| Max current | 100 A (with external CT — SCT-013-100A) |
| Max voltage | 80-260 VAC |
| Cost | ~$8 per sensor (SHE-R8/R16 only) |
| Sampling rate | Every 5 s (firmware poll) |

PZEM-004T connects to ESP32 UART1 on SHE-R8 / UART1 on SHE-R16 (V3-HARDWARE.md §4.3). Firmware reads every 5 seconds and publishes via MQTT.

**SHE-R4 omits the PZEM sensor** for cost reasons (target: entry-level consumer). R4 users do not see the Energy Dashboard in the app — instead, the dashboard tile shows "Energy monitoring not available on this device. Upgrade to SHE-R8."

---

## 2. RainMaker hierarchy mapping

Energy is modeled as Parameters on the **Diagnostics Service** (`esp.service.diag`) per V3-DEVICE-MODEL.md §2.1:

```
Node: SHE-R8 (MAC: 24:6F:28:AA:BB:CC)
├── Device: "Relay 1" through "Relay 8"  (esp.device.switch)
│   └── Parameter: Power (bool)
├── Service: OTA         (esp.service.ota)
│   └── ...
└── Service: Diagnostics (esp.service.diag)
    ├── Parameter: Uptime          (int, read)         [all SKUs]
    ├── Parameter: RSSI            (int, read)         [all SKUs]
    ├── Parameter: Free Heap       (int, read)         [R8/R16]
    ├── Parameter: Reset Reason    (string, read)      [R8/R16]
    ├── Parameter: Power Consumption (float, read, time_series)  [R8/R16 — PZEM]
    ├── Parameter: Voltage           (float, read, time_series)  [R8/R16 — PZEM]
    ├── Parameter: Current           (float, read, time_series)  [R8/R16 — PZEM]
    └── Parameter: Energy Cumulative (float, read, time_series)  [R8/R16 — PZEM, kWh]
```

Parameter type URIs (V3-DEVICE-MODEL.md §2.2):
- `esp.param.power_consumption` (float, watts)
- `esp.param.voltage` (float, volts)
- `esp.param.current` (float, amps)
- `esp.param.energy` (float, kWh cumulative — non-standard, but follows RainMaker convention)

The `time_series` property (V3-DEVICE-MODEL.md §4) on these parameters tells the cloud to log every change to TimescaleDB, not just cache the latest value.

---

## 3. Data flow

```
PZEM-004T v3 (Modbus RTU, every 5 s)
    │
    ▼
ESP32 firmware reads voltage, current, power, energy_cumulative
    │
    ▼
MQTT publish on: she/{tenant_id}/{home_id}/{room_id}/{node_mac}/params/local
   Payload:
   {
     "Diagnostics": {
       "Voltage": 220.5,
       "Current": 1.20,
       "Power_Consumption": 264.6,
       "Energy_Cumulative": 12345.6,
       "Uptime": 86400,
       "RSSI": -52
     }
   }
    │
    ▼
EMQX routes to Spring Boot (shared subscription: $share/she-backend/she/+/+/+/+/params/local)
    │
    ▼
Spring Boot EnergyService:
   1. INSERT into TimescaleDB hypertable device_energy_readings
   2. Calculate cost_etb (Ethiopian block tariff — see §4)
   3. WebSocket push: "energy.update" event to subscribed clients
   4. Anomaly detection: if power_consumption > 3× 7-day baseline → push "energy.anomaly" notification
    │
    ▼
Flutter app:
   - Real-time gauge updates (Power_Consumption in W)
   - Today's cost in ETB updates
   - 7/14/30-day historical chart refreshes
```

---

## 4. ETB tariff structure (Ethiopian Electric Utility)

### 4.1 Residential block tariff (current)

| Block | Consumption (kWh/month) | Price (ETB/kWh) |
|---|---|---|
| 1 | 0-50 | 0.78 |
| 2 | 51-100 | 1.04 |
| 3 | 101-200 | 1.30 |
| 4 | 201-300 | 1.89 |
| 5 | 301-400 | 2.67 |
| 6 | 400+ | 4.50 |

### 4.2 Commercial tariff

Flat 1.20 ETB/kWh for commercial customers (small business). Configurable per tenant (B2B tenants may negotiate custom tariffs with EEU).

### 4.3 Cost calculation

The cost calculation runs **server-side** in Spring Boot (not on the device — tariff changes don't require firmware updates):

```java
public BigDecimal calculateCostEtb(double kWh, TariffBlock[] blocks) {
    BigDecimal cost = BigDecimal.ZERO;
    double remaining = kWh;
    double blockStart = 0;
    
    for (TariffBlock block : blocks) {
        double blockEnd = block.upperLimit() == null ? Double.MAX_VALUE : block.upperLimit();
        double blockWidth = blockEnd - blockStart;
        double consumedInBlock = Math.min(remaining, blockWidth);
        cost = cost.add(BigDecimal.valueOf(consumedInBlock * block.pricePerKwh()));
        remaining -= consumedInBlock;
        blockStart = blockEnd;
        if (remaining <= 0) break;
    }
    return cost.setScale(2, RoundingMode.HALF_UP);
}
```

Example: 250 kWh/month
- 50 kWh @ 0.78 = 39.00 ETB
- 50 kWh @ 1.04 = 52.00 ETB
- 100 kWh @ 1.30 = 130.00 ETB
- 50 kWh @ 1.89 = 94.50 ETB
- **Total = 315.50 ETB/month**

### 4.4 Tariff configurability

Tariff is stored in `tenants.branding_config` JSONB:

```json
{
  "energy_tariff": {
    "type": "residential",
    "currency": "ETB",
    "blocks": [
      {"upper_limit": 50,  "price_per_kwh": 0.78},
      {"upper_limit": 100, "price_per_kwh": 1.04},
      {"upper_limit": 200, "price_per_kwh": 1.30},
      {"upper_limit": 300, "price_per_kwh": 1.89},
      {"upper_limit": 400, "price_per_kwh": 2.67},
      {"upper_limit": null, "price_per_kwh": 4.50}
    ]
  }
}
```

B2C users get the default residential tariff. B2B tenants can override with commercial or custom tariffs. If EEU changes tariffs (annual review), update via admin web `/tenants/{id}` → branding → energy_tariff (no code deploy needed).

---

## 5. Database schema

### 5.1 Hypertable

```sql
-- V23 migration
CREATE TABLE device_energy_readings (
    time         TIMESTAMPTZ NOT NULL,
    tenant_id    UUID NOT NULL REFERENCES tenants(id),
    node_id      UUID NOT NULL REFERENCES nodes(id),
    voltage      DOUBLE PRECISION,
    current      DOUBLE PRECISION,
    power_w      DOUBLE PRECISION,
    energy_wh    DOUBLE PRECISION,           -- cumulative Wh from PZEM
    cost_etb     DOUBLE PRECISION,           -- calculated at ingest
    tariff_block INT                         -- which block this kWh fell into (1-6)
);
SELECT create_hypertable('device_energy_readings', 'time');
CREATE INDEX idx_energy_node_time ON device_energy_readings (node_id, time DESC);
CREATE INDEX idx_energy_tenant_time ON device_energy_readings (tenant_id, time DESC);

-- RLS policy (ADR-003)
ALTER TABLE device_energy_readings ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON device_energy_readings
    USING (tenant_id = current_setting('app.tenant_id')::uuid);
```

### 5.2 Continuous aggregates (V24, V25 migrations)

```sql
-- V24: energy_hourly
CREATE MATERIALIZED VIEW energy_hourly
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 hour', time) AS bucket,
    tenant_id, node_id,
    AVG(voltage) AS avg_voltage,
    AVG(current) AS avg_current,
    AVG(power_w) AS avg_power_w,
    MAX(energy_wh) - MIN(energy_wh) AS kwh_consumed,
    MAX(cost_etb) - MIN(cost_etb) AS cost_etb
FROM device_energy_readings
GROUP BY bucket, tenant_id, node_id;

-- V25: energy_daily (built on energy_hourly)
CREATE MATERIALIZED VIEW energy_daily
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 day', bucket) AS day,
    tenant_id, node_id,
    AVG(avg_voltage) AS avg_voltage,
    SUM(kwh_consumed) AS kwh_consumed,
    SUM(cost_etb) AS cost_etb
FROM energy_hourly
GROUP BY day, tenant_id, node_id;
```

### 5.3 Compression policy

Per V3-DATABASE-DESIGN.md §6:

```sql
-- Compress data older than 7 days (live data stays uncompressed for fast queries)
ALTER TABLE device_energy_readings SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'tenant_id, node_id',
    timescaledb.compress_orderby = 'time DESC'
);
SELECT add_compression_policy('device_energy_readings', INTERVAL '7 days');

-- Drop raw chunks older than 365 days (continuous aggregates survive)
SELECT add_retention_policy('device_energy_readings', INTERVAL '365 days');

-- Continuous aggregates retained 7 years (Ethiopian tax law)
SELECT add_retention_policy('energy_daily', INTERVAL '7 years');
```

Compression ratio observed: ~14:1 (1 GB raw → ~70 MB compressed). At 1,000 telemetry-ingesting devices × 17,280 readings/day (5s interval) × 100 bytes/reading = ~1.7 GB/day uncompressed → ~120 MB/day compressed → ~44 GB/year compressed.

---

## 6. Anomaly detection

Spring Boot scheduled job (every 5 min) checks each energy-reporting node:

```java
@Scheduled(fixedRate = 5 * 60 * 1000)
public void detectAnomalies() {
    for (UUID nodeId : energyService.getActiveEnergyNodes()) {
        double currentPower = energyService.getLatestPower(nodeId);
        double baseline = energyService.get7DayAveragePower(nodeId);
        
        if (currentPower > baseline * 3.0 && currentPower > 100) {
            // 3x spike above 7-day average, and absolute > 100W (filters noise on low-draw devices)
            notificationService.pushEnergyAnomaly(nodeId, currentPower, baseline);
            auditLogService.log("energy.anomaly_detected", nodeId, currentPower, baseline);
        }
    }
}
```

**Thresholds:**
- 3× power spike above 7-day rolling average (configurable per tenant)
- Absolute threshold of 100 W (avoids false positives on low-draw devices)
- Debounced: max 1 anomaly notification per node per hour

**Notification:** Push notification via FCM/APNs + entry in `notification_log` + entry in `audit_log` (`event_type = energy.anomaly_detected`).

---

## 7. Mobile app — Energy Dashboard

Per V3-MOBILE-APP.md §7:

- **Real-time gauge:** Animated circular gauge showing current `power_consumption` (W) — updates via WebSocket `energy.update` event
- **Today's summary:** Total kWh + cost in ETB (queried from `energy_daily` continuous aggregate)
- **Historical chart:** Bar chart (7/14/30-day view) with kWh + ETB dual axis (fl_chart)
- **Per-device breakdown:** List of devices with their consumption + cost (sorted descending by kWh)
- **Anomaly alerts:** Push notification when consumption 3× above 7-day baseline (see §6)
- **Monthly projection:** "At current rate, you'll use X kWh / Y ETB this month" — projection based on daily average × days in month

**SHE-R4 note:** If user has only R4 devices (no PZEM), the Energy Dashboard shows an empty state: "Energy monitoring is available on SHE-R8 and SHE-R16. Your SHE-R4 device does not have a power sensor."

---

## 8. B2B aggregate reports

B2B tenants (B2B-1000 and B2B-UNLIMITED plans) get aggregate reports across all their devices:

### 8.1 Standard reports

| Report | Granularity | Format |
|---|---|---|
| Per-property energy summary | Daily / weekly / monthly | JSON + PDF |
| Top 10 devices by consumption | Monthly | JSON + CSV |
| Cost breakdown by home/property/region | Monthly | JSON + CSV |
| Anomaly history | Date range | JSON + CSV |

### 8.2 API

```
GET /api/v3/tenant/energy?from=2024-12-01&to=2024-12-31&group_by=home
   Authorization: Bearer <api_key>

Response:
{
  "period": {"from": "2024-12-01", "to": "2024-12-31"},
  "tenant_id": "ethiotelecom-uuid",
  "total_kwh": 15432.5,
  "total_cost_etb": 28145.67,
  "groups": [
    {"home_id": "uuid-1", "home_name": "Bole Property A", "kwh": 4521.2, "cost_etb": 8234.10},
    {"home_id": "uuid-2", "home_name": "Cazanchis Property B", "kwh": 3210.8, "cost_etb": 5843.20},
    ...
  ]
}

GET /api/v3/tenant/energy/export?from=2024-12-01&to=2024-12-31&format=csv
   → Returns CSV (max 100k rows)
```

### 8.3 Scheduled reports

Tenant admins can configure weekly/monthly email reports via `/tenants/{id}` → Energy tab:
- "Send me a weekly energy summary every Monday at 09:00"
- "Send me a monthly PDF on the 1st"
- Reports are generated by Spring Boot `@Scheduled` task + emailed via SMTP (Mailtrap in dev, Ethio Telecom SMTP relay in prod)

---

## 9. Calibration + accuracy

### 9.1 Factory calibration

Every SHE-R8/R16 unit is calibrated at factory (V3-HARDWARE.md §7.3 step 6):
1. Apply known 220 VAC test load (resistive, 100 W bulb)
2. Read PZEM voltage + current + power
3. Verify voltage within ±1% of calibrated meter (220 ± 2.2 V)
4. Verify power within ±1% (100 ± 1 W)
5. If out of spec, RMA the unit

### 9.2 Field recalibration

PZEM-004T v3 does not support software calibration (it's calibrated at the factory by the sensor vendor). If a user reports drift > 5% vs their utility meter:
1. Verify wiring (CT orientation — must clip around L conductor only, not L+N)
2. If wiring correct, RMA the unit (V3-SUPPORT-RMA.md)
3. Do not attempt software calibration — would mask a hardware fault

### 9.3 Accuracy expectations

| Metric | PZEM-004T v3 spec | Field expectation |
|---|---|---|
| Voltage | ±1% | ±2% (after wiring losses) |
| Current | ±1% | ±2% (CT clipping variation) |
| Power | ±1% | ±3% (voltage × current error compounds) |
| Energy (kWh) | ±1% | ±5% vs utility meter (acceptable — utility meter is revenue-grade) |

If field accuracy drifts > 10% vs utility meter, treat as a fault and RMA.

---

## 10. References

- V3-HARDWARE.md §3.4 — PZEM-004T v3 sensor spec
- V3-HARDWARE.md §4.3 — PZEM wiring schematic
- V3-HARDWARE.md §7.3 step 6 — factory calibration
- V3-DEVICE-MODEL.md §2.1 — Diagnostics Service definition
- V3-DEVICE-MODEL.md §2.2 — `esp.param.power_consumption`, `esp.param.voltage`, `esp.param.current` parameter types
- V3-DEVICE-MODEL.md §4 — `time_series` parameter property
- V3-DATABASE-DESIGN.md §2 (V22-V25) — TimescaleDB migrations
- V3-DATABASE-DESIGN.md §6 — compression policy
- V3-MOBILE-APP.md §7 — Energy Dashboard UI
- V3-API-SPECIFICATION.md — `/api/v3/nodes/{nodeId}/telemetry` endpoint
- V3-PAYMENTS.md — ETB currency formatting (ብር symbol)
- V3-I18N.md §5.4 — currency formatting rules
- V3-SUPPORT-RMA.md — RMA procedure for accuracy drift
