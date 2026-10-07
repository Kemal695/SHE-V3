import { check, sleep } from 'k6';
import mqtt from 'k6/x/mqtt';

export const options = {
  scenarios: {
    telemetry: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 1000 },
        { duration: '5m', target: 5000 },
        { duration: '10m', target: 10000 },
        { duration: '15m', target: 10000 },
        { duration: '2m', target: 0 },
      ],
    },
  },
  thresholds: {
    'mqtt_publish_time': ['p(95)<500'],
    'mqtt_errors': ['rate<0.001'],
  },
};

const BROKER = 'tls://she.et:8883';
const DEVICE_CERT = __ENV.DEVICE_CERT;
const DEVICE_KEY = __ENV.DEVICE_KEY;
const CA_CERT = __ENV.CA_CERT;

export default function () {
  // C-4 FIX: clientid MUST equal the topic's MAC segment + cert CN
  // Use a fixed normalized MAC per VU (no __ITER in the name)
  const normalizedMac = `load${String(__VU).padStart(10, '0')}`;
  const client = new mqtt.Client(
    BROKER,
    normalizedMac,  // clientid = normalized MAC (matches topic + cert CN)
    DEVICE_CERT, DEVICE_KEY, CA_CERT
  );

  const topic = `she/loadtest-tenant/loadtest-home/loadtest-room/${normalizedMac}/params/local`;
  const payload = JSON.stringify({
    'Relay 1': { Power: __ITER % 2 === 0 },
    'Diagnostics': {
      Uptime: __ITER * 5,
      RSSI: -55 - (__ITER % 10),
      Free_Heap: 142336 - (__ITER * 100),
      Reset_Reason: 'POWER_ON',
    },
  });

  client.publish(topic, payload, 0, false);
  client.close();
  sleep(5);
}
