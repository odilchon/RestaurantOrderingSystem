# Observability

What's in place today, what's intentionally omitted, and what would come next.

## What's in place

### PostgreSQL layer

- **`pg_stat_statements`** is preloaded (`docker-compose.yml` → `shared_preload_libraries=pg_stat_statements`) and can be queried from `db/queries/08_maintenance.sql` for per-query latency, calls, and total time. This is the authoritative source for "which query is slow" questions.
- **Slow-query log**: `log_min_duration_statement=200` — any statement over 200 ms is logged. Combined with `pg_stat_statements` this gives both a rolling histogram and a recent-slow-query tail.
- **`audit_log`**: every UPDATE / DELETE on 13 tenant-scoped tables is captured by a generic PL/pgSQL trigger into `audit_log` with JSONB snapshots of `OLD` and `NEW`. This is a business-level audit trail, not a metrics system, but it answers "who changed what and when" for free.
- **`v_low_stock`** and **`mv_daily_revenue_by_branch`** are the built-in dashboards' data source — latency-free reads because the expensive work is pre-computed.

### Application layer

- **Structured-enough logs**: `uvicorn` access logs stream to `.run/backend.log`. Each line has method, path, status, duration. Good for local dev and defense demos.
- **`/health`** is a trivial liveness probe (`200 {status: ok}`) wired for k8s / docker-compose health checks.
- **`/meta/stats`** reads `pg_catalog` live to report table/index/view counts — used by the homepage and `test_api.py::test_meta_stats_live` as a canary that the schema hasn't regressed.

### CI

GitHub Actions runs the whole test matrix (schema apply → seed → pytest SQL + HTTP → disaster-recovery drill) on every PR. A failed migration, broken RLS, or broken `fn_place_order` fails CI before merge.

## What's intentionally omitted

A full observability stack would be over-engineered for this setup. The following are left off with awareness, not by accident:

- **No Prometheus / OpenTelemetry exporter.** A single FastAPI process doesn't need it. For a real deployment the first thing to add is `prometheus-fastapi-instrumentator` → `/metrics`, scraped by Prometheus, visualised in Grafana.
- **No request-id correlation middleware.** Useful when logs span multiple services; here there's only one service, so access logs already tell the full story.
- **No Sentry / Rollbar.** Exceptions land in `.run/backend.log`. Worth wiring for any real user base.
- **No RED / USE dashboards pre-built.** The seeded data is static, so a "p95 latency over time" chart would be flat by construction.

## What to add next

In priority order, for a hypothetical post-course deployment:

1. **`/metrics`** via Prometheus instrumentation. Golden signals: request rate, error rate, latency histogram, and connection-pool saturation.
2. **Grafana dashboard**, two panels: (a) API golden signals, (b) PostgreSQL golden signals (`pg_stat_database`, replication lag, checkpointer, bloat).
3. **Sentry** for uncaught exceptions — essentially free to wire, high ROI for the first real bug report.
4. **Structured JSON logging** via `python-json-logger`. Makes log aggregation (Loki / ELK) trivially searchable.
5. **Request IDs** stamped in every log line and returned as `X-Request-ID` response header so a user can paste it in a support ticket.
6. **Continuous archiving / PITR**: `archive_command` + `pg_basebackup` gives point-in-time recovery on top of the nightly `pg_dump`. The disaster-recovery drill in this repo is a smoke test; PITR is the real production story.
7. **Alerting rules**: error-rate > 1% for 5 min, p95 latency > 500 ms for 10 min, replication lag > 30 s. Alertmanager → PagerDuty / Slack.

## Trade-offs, stated bluntly

| Decision                                 | Why                                                              | What we lose                                                                     |
| ---------------------------------------- | ---------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| No distributed tracing                   | Single-service topology                                          | Can't chain causally related log lines across processes                          |
| localStorage for JWT on the frontend     | Dead simple, no HttpOnly cookie infrastructure                   | Susceptible to XSS. For real use: HttpOnly + SameSite=Lax cookie + CSRF token    |
| Pool logs in as a non-superuser          | Forces `SET LOCAL ROLE` and prevents accidental RLS bypass       | One extra round-trip per request to switch role                                  |
| No read replica                          | Load is zero                                                     | Reports and writes contend for the same buffer cache; fine until ~100 req/s     |
| MV refreshed on schedule                 | Query latency is constant                                        | Dashboards lag freshness by the refresh interval                                |
| `audit_log` captures JSONB snapshots     | Generic trigger, zero extra code per table                       | Growing table; needs partitioning or periodic archival past ~1 GB               |
