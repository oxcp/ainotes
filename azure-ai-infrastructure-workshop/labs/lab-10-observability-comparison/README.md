# Lab 10: Observability and comparison

Collect only measured values. Use `null` for metrics that are not available.

## Platforms to compare

Record one `benchmark-result` entry per platform you exercised, using a consistent `platform` label:

- `aks-kaito` — Lab 02 KAITO inference (Track A)
- `anyscale-ray-serve` — Lab 06 Ray Serve service (Track B)
- `foundry-managed-compute` — Lab 08 Foundry managed compute (Track C)
- `fireworks-on-foundry` — Lab 09 Fireworks AI on Foundry (Track C)

## Dimensions

Compare:

- Deployment experience
- Resource ownership (who operates the compute)
- Billing model (compute core-hours vs per-token vs node uptime)
- Startup/readiness behavior
- CPU/GPU allocation (or "none" for partner MaaS)
- Request success and failure count
- Average and p95 latency when actually measured
- Operational troubleshooting path
- Cleanup behavior

Do not infer tokens-per-second without token counts and measured time. For token-billed platforms (Fireworks on Foundry), latency and cost per token matter more than GPU utilization; for compute-billed platforms (KAITO, Foundry managed compute), record GPU type/count and note idle-cost exposure.
