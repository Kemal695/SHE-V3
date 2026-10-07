# Postmortem Template (V3-OPS-RUNBOOK §5.5)

Required within 48 hours for every SEV-1 / SEV-2 incident.

---

## Incident: <short title>

- **Date:** YYYY-MM-DD
- **Duration:** X min
- **Severity:** SEV-N
- **Impact:** <users/tenants affected, feature broken>
- **Detected by:** <alert name / user report / on-call>

## Timeline

| Time (T+X) | Action |
|---|---|
| T+0 | Alert fired (<alert name>) |
| T+2 | On-call acknowledged |
| T+5 | Investigation began (<what was checked>) |
| T+15 | Root cause identified (<what was the cause>) |
| T+25 | Fix applied (<what was done>) |
| T+30 | Confirmed resolved (<how confirmed>) |

## Root cause

<2-3 sentences — the actual technical cause, not "human error">

## Contributing factors

- <factor 1>
- <factor 2>

## What went well

- <thing 1>
- <thing 2>

## What went poorly

- <thing 1>
- <thing 2>

## Action items

- [ ] <action> — owner: <name> — due: <date>
- [ ] <action> — owner: <name> — due: <date>

## Metrics

| Metric | Value |
|---|---|
| Users affected | X |
| Devices affected | X |
| API downtime | X min |
| MQTT downtime | X min |
| Data loss | None / X records |

---
Filed by: <on-call engineer>
Reviewed by: <Lead Engineer>
