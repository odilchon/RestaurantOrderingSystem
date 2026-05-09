# 🍽️ Restaurant Ordering System (ROS)

A multi-tenant SaaS platform for managing restaurant chains. A single PostgreSQL instance securely serves multiple restaurant brands (tenants), giving each branch a Point-of-Sale UI, inventory management, and live analytics — with hardware-level data isolation through Row-Level Security.

🇷🇺 Russian version: **[README_RU.md](README_RU.md)**

📺 **[Watch the demo video](https://drive.google.com/file/d/1gIIhR5-smdk4KU7u1wavRLBfORp4vp5D/view?usp=sharing)**  ·  📝 **[Faculty feedback](https://docs.google.com/presentation/d/13mfplDHew13VJOsT-ZJ5-7R0tWPaB3ib52Cf2cEfbjY/edit?usp=drive_link)**  ·  🎯 **[Pitch presentation](presentation/Restaurant%20Ordering%20System%20%28ROS%29%20-%20Pitch%20Presentation.pdf)**  ·  🎓 **[Oracle Academy DB certificate](certificate_stepik/stepik-certificate-191774-27f405e.pdf)**

---

## 📋 Table of Contents

- [Quick Start](#-quick-start)
- [Architecture](#-architecture)
- [Demo Tenants & Logins](#-demo-tenants--logins)
- [What's Inside](#-whats-inside)
- [Working with the Database](#-working-with-the-database)
- [SQL Queries for the Demo](#-sql-queries-for-the-demo)
- [Backup & Disaster Recovery](#-backup--disaster-recovery)
- [Documentation](#-documentation)
- [Deliverables Checklist](#-deliverables-checklist)

---

## 🚀 Quick Start

```bash
git clone https://github.com/odilchon/Restaurant-Ordering-System.git
cd Restaurant-Ordering-System

cp .env.example .env       # local secrets (rotate JWT secret if needed)
./run.sh                   # one-shot: Postgres + schema + seed + backend + frontend
```

When the launch banner says **"Restaurant Ordering System — up"** open:

| URL | What it is |
|---|---|
| http://localhost:3000 | **Frontend (Next.js dashboard)** |
| http://localhost:8000/docs | **Swagger API browser** |
| http://localhost:5050 | pgAdmin (admin@ros.local / admin) |

To stop everything: `./run.sh stop`.

> **Need Docker?** All services live in `docker-compose.yml` and `./run.sh` orchestrates them. Make sure Docker Desktop is running before launch.

---

## 🏗️ Architecture

```
┌───────────────────┐    ┌──────────────────────┐    ┌────────────────────────────┐
│  Next.js 14       │──▶ │  FastAPI             │──▶ │  PostgreSQL 16             │
│  Tailwind + Recharts│  │  async psycopg 3 +   │    │  RLS, partitioning, MVs,   │
│  light UI         │    │  psycopg_pool, JWT   │    │  pgcrypto, btree_gist, GIN │
└───────────────────┘    └──────────────────────┘    └────────────────────────────┘
```

**Tech stack:**
- **PostgreSQL 16** + extensions: `pgcrypto`, `btree_gist`, `pg_trgm`, `pg_stat_statements`, `citext`
- **FastAPI** (async) + **psycopg 3** + connection pool
- **Next.js 14** + Tailwind + Recharts (light theme, coral accent)
- **JWT** auth (24h tokens) + bcrypt
- **Docker Compose** for local stack
- **GitHub Actions** CI: `sqlfluff` → schema apply → `pytest` → backup/restore drill

### ER Diagram

The full schema as rendered by pgAdmin's ERD tool — 31 base tables grouped by tenancy, restaurant structure, menu, inventory, orders, customer experience, and audit. Source DBML in [docs/erd.dbml](docs/erd.dbml); a Mermaid version is at [docs/erd.md](docs/erd.md).

![ER Diagram](docs/screenshots/erd.png)

---

## 👥 Demo Tenants & Logins

Two complete restaurant chains pre-seeded so you can demonstrate **multi-tenant isolation**:

| Owner login | Password | Tenant | Branches | Menu theme |
|---|---|---|---|---|
| `owner.alpha@demo.test` | `demo1234` | **PlovPOS Chain** | 1 (PlovPOS Bishkek Central) | Plov, manty, lagman |
| `owner.beta@demo.test` | `demo1234` | **TandyrOS** | 2 (Downtown + Джал-29) | Tandyr-samsa, kebab, lepyoshki |

**Sign in as `owner.alpha`** → you see only PlovPOS data.
**Sign out, sign in as `owner.beta`** → you see only TandyrOS data.
PostgreSQL itself enforces this through Row-Level Security policies in [db/10_rls_policies.sql](db/10_rls_policies.sql).

---

## 📦 What's Inside

### Domain model — 31 tables in 3NF

| Area | Key tables |
|---|---|
| Tenancy & auth | `tenants`, `users`, `user_roles` |
| Restaurant structure | `branches`, `zones`, `restaurant_tables` |
| Menu & inventory | `categories`, `menu_items`, `menu_item_prices`, `menu_item_translations`, `menu_item_ingredients`, `ingredients`, `inventory`, `inventory_movements`, `suppliers`, `purchase_orders` |
| Orders & payments | `orders` (partitioned by month), `order_items`, `order_status_history`, `payments`, `refunds` |
| Customer experience | `reservations` (`EXCLUDE USING gist`), `loyalty_accounts`, `loyalty_transactions`, `reviews` |
| Operations & audit | `shifts`, `audit_log`, `notifications` |

### Highlighted technical decisions

| Decision | What it means |
|---|---|
| **Row-Level Security (RLS)** | 18 tenant-scoped tables protected by policies. One restaurant cannot see another's data even if backend code has a bug. |
| **`orders` partitioning** | Monthly RANGE partitions on `created_at`. Queries about last week never scan three years of data. `ensure_orders_partition(date)` lazily creates new partitions. |
| **Materialized views** | `mv_daily_revenue_by_branch`, `mv_top_menu_items_30d` — pre-computed analytics with `UNIQUE` indexes, refreshed via `REFRESH … CONCURRENTLY` (no reader blocking). |
| **`fn_place_order`** | Single PL/pgSQL function: locks inventory `FOR UPDATE`, checks stock, creates order + items, decrements inventory, raises on shortage → whole transaction rolls back. ACID by construction. |
| **`EXCLUDE USING gist`** | Reservations table physically rejects overlapping bookings on the same table — at the database level, not in app code. |
| **Generic audit trigger** | One PL/pgSQL function (`fn_audit_row_change`) attached to 13 critical tables via `TG_TABLE_NAME` + `row_to_json(OLD/NEW)` into `audit_log`. |
| **Index strategy** | B-tree + partial (`WHERE status IN (…)`) + expression (`LOWER(email)`) + GIN (JSONB, tsvector) + GiST (tsrange) + BRIN on append-only `audit_log.changed_at`. Each index has a `COMMENT`. |
| **Full-text search** | `menu_items.search_vector` weighted A (name) > B (category) > C (description), maintained by trigger. |
| **4 database roles** | `app_readonly` → `app_waiter` → `app_manager` → `app_admin` with inheritance and `BYPASSRLS` only on admin. |

---

## 🗃️ Working with the Database

### Connect via `psql`

```bash
PGPASSWORD=ros_dev_password psql -h localhost -p 5433 -U ros_admin -d restaurant_ordering
```

Useful psql commands:

| Command | What it does |
|---|---|
| `\dt` | List all tables |
| `\d table_name` | Show table structure (columns, types, indexes, constraints) |
| `\di+` | List all indexes with sizes |
| `\df` | List functions |
| `\dv` / `\dm` | List views / materialized views |
| `\x on` | Vertical display (great for wide rows) |
| `\q` | Quit |

### Connect via pgAdmin 4

Open http://localhost:5050 (login `admin@ros.local` / `admin`), then register server:

- **Host:** `postgres` (inside Docker network) or `host.docker.internal`
- **Port:** `5432` from inside container, **`5433` from host**
- **Database:** `restaurant_ordering`
- **Username:** `ros_admin`
- **Password:** `ros_dev_password`

In pgAdmin you can right-click `public` schema → **ERD Tool** to get a visual schema diagram.

---

## 📊 SQL Queries for the Demo

> Run in `psql` connected as `ros_admin` (it bypasses RLS, so you see all tenants). For tenant-scoped queries the backend sets `app.current_tenant_id` automatically.

### System-wide statistics

```sql
SELECT
    (SELECT count(*) FROM tenants)    AS restaurant_chains,
    (SELECT count(*) FROM branches)   AS branches,
    (SELECT count(*) FROM menu_items) AS dishes,
    (SELECT count(*) FROM orders)     AS total_orders,
    (SELECT round(sum(total_amount))) AS lifetime_revenue_kgs
FROM tenants LIMIT 1;
```

### Revenue per tenant per day (last 14 days)

```sql
SELECT
    t.name AS tenant,
    o.created_at::date AS day,
    count(*) AS orders,
    round(sum(o.total_amount)) AS revenue
FROM orders o
JOIN tenants t ON t.tenant_id = o.tenant_id
WHERE o.created_at >= now() - INTERVAL '14 days'
GROUP BY t.name, o.created_at::date
ORDER BY t.name, day DESC;
```

### Top dishes via window function

```sql
SELECT branch_id, menu_item_name, revenue, revenue_rank
FROM mv_top_menu_items_30d
WHERE revenue_rank <= 5
ORDER BY branch_id, revenue_rank;
```

### Inventory low-stock alerts (live VIEW)

```sql
SELECT * FROM v_low_stock ORDER BY shortfall DESC;
```

### Full-text search showing GIN index in action

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT name FROM menu_items
WHERE search_vector @@ to_tsquery('russian', 'плов | шашлык');
```

More queries are organised by skill level in [db/queries/](db/queries/).

---

## 💾 Backup & Disaster Recovery

```bash
bash db/backup/backup.sh                       # nightly pg_dump (custom format, 7-day retention)
bash db/backup/restore.sh latest               # restore named dump or latest
bash db/backup/disaster-recovery-drill.sh      # backup → DROP DATABASE → CREATE → pg_restore → row-count diff
```

The drill is what runs in CI on every push. Details: [docs/backup-strategy.md](docs/backup-strategy.md).

---

## 📁 Project File Structure

```
restaurant_ordering_system/
├── backend/                       # FastAPI + psycopg 3
│   ├── app/
│   │   ├── main.py                # Entry point, CORS, router registration
│   │   ├── config.py              # Settings (reads .env)
│   │   ├── db.py                  # Connection pool, tenant_connection context manager
│   │   ├── auth.py                # JWT + bcrypt
│   │   └── routers/
│   │       ├── auth.py            # /auth/login, /auth/me
│   │       ├── menu.py            # /menu, /menu/categories
│   │       ├── orders.py          # /orders CRUD (calls fn_place_order)
│   │       ├── reports.py         # /reports/daily-revenue, /top-items, /category-breakdown, /order-types, /low-stock
│   │       ├── places.py          # /places/branches, /places/branches/{id}/tables
│   │       └── meta.py            # /meta/stats live from pg_catalog
│   ├── tests/
│   └── Dockerfile
├── frontend/                      # Next.js 14 + Tailwind + Recharts (light theme)
│   ├── app/                       # Pages: dashboard, menu, orders, inventory, reports
│   ├── components/                # Panel, Button, Chip, RoleBadge, StatusBadge…
│   ├── lib/                       # api.ts, context.tsx, hooks, format, period
│   └── Dockerfile
├── db/                            # SQL applied in numeric order
│   ├── 01_extensions.sql          # PostgreSQL extensions
│   ├── 02_enums.sql               # status / role / type enums
│   ├── 03_schema.sql              # 31 tables in 3NF
│   ├── 04_partitions.sql          # Monthly partitions on orders.created_at
│   ├── 05_indexes.sql             # B-tree + GIN + GiST + BRIN + partial + expression
│   ├── 06_views.sql               # v_active_menu, v_low_stock, v_table_occupancy, …
│   ├── 07_materialized_views.sql  # mv_daily_revenue_by_branch, mv_top_menu_items_30d
│   ├── 08_functions.sql           # fn_place_order, fn_close_order, fn_cancel_order, …
│   ├── 09_triggers.sql            # audit, FTS, status history, overlap, timestamps
│   ├── 10_rls_policies.sql        # 18 RLS policies on tenant-scoped tables
│   ├── 11_roles_grants.sql        # 4 roles + grants
│   ├── 12_seed.sql                # Initial demo data (PlovPOS)
│   ├── backup/                    # backup.sh, restore.sh, disaster-recovery-drill.sh
│   └── queries/                   # 8 SQL files: basic → joins → aggregates → CTE → analytical → transactions → maintenance
├── scripts/
│   ├── seed_faker.py              # ~1,200 historical orders for PlovPOS
│   ├── freshen_orders.py          # 220 fresh PlovPOS orders for the last 14 days
│   ├── seed_tandyros.py           # Bootstraps the second tenant: 2 branches, menu, staff, 230 fresh orders
│   └── seed_drinks.py             # Adds tea + cold drinks categories to PlovPOS menu
├── docs/
│   ├── architecture.md            # Mermaid sequence diagrams
│   ├── erd.md                     # ER diagram (Mermaid)
│   ├── erd.dbml                   # ER source for dbdiagram.io
│   ├── normalization.md           # 1NF → 2NF → 3NF derivation
│   ├── schema-description.md      # Table-by-table description
│   ├── indexing-report.md         # EXPLAIN ANALYZE before/after indexes
│   ├── transactions-demo.md       # ACID demonstrations
│   ├── backup-strategy.md         # Backup & recovery
│   ├── security.md                # RLS, roles, JWT
│   ├── observability.md           # What's instrumented, what's omitted, trade-offs
│   └── screenshots/               # ER diagram + UI screenshots
├── presentation/                  # Pitch presentation (PDF)
├── certificate_stepik/            # Oracle Academy DB course certificate
├── docker-compose.yml             # Postgres + pgAdmin + backend + frontend
├── run.sh                         # One-command launcher
├── Makefile                       # make up / make down / make logs
├── .env.example
├── README.md                      # ← this file
└── README_RU.md                   # Russian version
```

---

## 📚 Documentation

| File | Contents |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Architecture & sequence diagrams (Mermaid) |
| [docs/erd.md](docs/erd.md) | ER diagram (Mermaid — renders directly on GitHub) |
| [docs/erd.dbml](docs/erd.dbml) | ER diagram source (dbdiagram.io / DBML) |
| [docs/normalization.md](docs/normalization.md) | 1NF → 2NF → 3NF derivation |
| [docs/schema-description.md](docs/schema-description.md) | Table-by-table description |
| [docs/transactions-demo.md](docs/transactions-demo.md) | ACID transaction demonstrations |
| [docs/indexing-report.md](docs/indexing-report.md) | EXPLAIN ANALYZE before/after indexes |
| [docs/backup-strategy.md](docs/backup-strategy.md) | Backup & recovery strategy |
| [docs/security.md](docs/security.md) | Security, RLS, database roles, JWT |
| [docs/observability.md](docs/observability.md) | What's instrumented, trade-offs, what's next |
| [presentation/](presentation/) | Pitch presentation (PDF) |

---

## ✅ Deliverables Checklist

- [x] ER diagram ([docs/screenshots/erd.png](docs/screenshots/erd.png), source [docs/erd.dbml](docs/erd.dbml))
- [x] Normalized schema (3NF) — [db/03_schema.sql](db/03_schema.sql)
- [x] DDL: tables, views, materialized views, functions, triggers
- [x] SQL queries at all skill levels ([db/queries/](db/queries/))
- [x] ACID transaction demonstration ([docs/transactions-demo.md](docs/transactions-demo.md))
- [x] Index report with EXPLAIN ANALYZE ([docs/indexing-report.md](docs/indexing-report.md))
- [x] Backup, restore, and disaster recovery drill scripts ([db/backup/](db/backup/))
- [x] Multi-tenant data isolation via RLS ([db/10_rls_policies.sql](db/10_rls_policies.sql))
- [x] Working frontend integrated with backend (Next.js + FastAPI)
- [x] Pitch slides ([presentation/](presentation/))
- [x] **Demo video** → [Watch demo](https://drive.google.com/file/d/1gIIhR5-smdk4KU7u1wavRLBfORp4vp5D/view?usp=sharing)
- [x] **Faculty feedback** → [View feedback](https://drive.google.com/file/d/15rMY1EZlYLhy9hNRW5zRtz6AvK0CiMPo/view?usp=sharing)
- [x] **Oracle Academy Database Course certificate** ([certificate_stepik/](certificate_stepik/))

---

> **License:** MIT (see [LICENSE](LICENSE))
