# Architecture

This document explains how the three layers of Restaurant Ordering System fit together and what each one is responsible for. The diagrams below render directly on GitHub.

## High-level components

```mermaid
flowchart LR
    browser[Browser / POS terminal]
    next[Next.js 14 frontend<br/>app/ + components/ + lib/]
    fastapi[FastAPI backend<br/>psycopg 3 async pool]
    pg[(PostgreSQL 16<br/>RLS · partitions · MVs)]

    browser -->|JWT over HTTPS| next
    next -->|fetch + Bearer token| fastapi
    fastapi -->|SET LOCAL ROLE<br/>+ app.current_tenant_id| pg
    pg -->|rows filtered by RLS| fastapi
    fastapi -->|JSON| next
    next -->|server-side props / CSR| browser
```

- **Frontend** never talks to PostgreSQL directly. No DB creds ever reach the browser.
- **FastAPI** is stateless. All session state lives in the JWT (HS256, 24h TTL).
- **PostgreSQL** is the source of truth. Business rules (stock checks, totals, audit) live in PL/pgSQL so they can't be bypassed even if the API layer has a bug.

## Authentication and RLS enforcement

```mermaid
sequenceDiagram
    autonumber
    actor Owner as Owner (browser)
    participant FE as Next.js
    participant API as FastAPI
    participant Pool as psycopg pool<br/>(login: app_user)
    participant PG as PostgreSQL

    Owner->>FE: enter email + password
    FE->>API: POST /auth/login (form-urlencoded)
    API->>Pool: checkout connection
    Pool->>PG: SELECT password_hash, role FROM users JOIN user_roles
    PG-->>Pool: row
    Pool-->>API: row
    API->>API: bcrypt.verify(password, hash)
    API->>API: jwt.encode({sub, tenant_id, role})
    API-->>FE: { access_token, tenant_id }
    FE->>FE: localStorage.setItem(ros_token, …)

    Note over Owner,PG: Subsequent request

    Owner->>FE: click /orders
    FE->>API: GET /orders?limit=100 (Authorization: Bearer …)
    API->>API: jwt.decode → CurrentUser
    API->>Pool: checkout connection
    Pool->>PG: SET LOCAL ROLE app_waiter
    Pool->>PG: SELECT set_config('app.current_tenant_id', '11…', true)
    Pool->>PG: SELECT * FROM orders ORDER BY created_at DESC
    Note right of PG: RLS policy adds<br/>WHERE tenant_id = current_setting('app.current_tenant_id')
    PG-->>Pool: rows for this tenant ONLY
    Pool-->>API: rows
    API-->>FE: JSON
    FE-->>Owner: rendered table
```

### Why `SET LOCAL ROLE` matters

The pool logs in as `app_user`, which has **no table grants of its own**. On every request, the backend switches to `app_waiter` / `app_manager` / `app_readonly` (per JWT role) for the duration of the transaction. If that `SET LOCAL ROLE` is ever forgotten, queries fail with `permission denied` — a loud error instead of silent data leakage.

`app_admin` has `BYPASSRLS` and is used only for migrations and the rare cross-tenant report.

## Placing an order — atomicity & locking

```mermaid
sequenceDiagram
    autonumber
    actor W1 as Waiter #1
    actor W2 as Waiter #2
    participant API
    participant PG as PostgreSQL
    participant INV as inventory row
    participant ORD as orders partition

    W1->>API: POST /orders/ (1× plov)
    W2->>API: POST /orders/ (1× plov)
    API->>PG: SELECT fn_place_order(...)  [txn 1]
    API->>PG: SELECT fn_place_order(...)  [txn 2]

    Note over PG,INV: Both txns reach the same<br/>ingredient row (rice, 0.2kg left)

    PG->>INV: SELECT quantity FROM inventory<br/>WHERE ... FOR UPDATE  [txn 1]
    INV-->>PG: 0.2, lock acquired
    PG->>INV: SELECT ... FOR UPDATE  [txn 2]
    Note right of INV: txn 2 WAITS for txn 1 to release

    PG->>INV: UPDATE inventory SET quantity = 0.05 [txn 1]
    PG->>ORD: INSERT INTO orders (routed to 2026-04 partition)
    PG->>PG: COMMIT txn 1
    INV-->>PG: now 0.05, unlocked

    PG->>INV: re-read (txn 2 resumed)
    INV-->>PG: 0.05 < 0.15 required
    PG->>PG: RAISE check_violation  [txn 2]
    API-->>W2: 409 Conflict — insufficient stock
    API-->>W1: 201 Created
```

Key properties demonstrated here:

- **Atomicity**: `fn_place_order` inserts the order + order_items + inventory_movements in one transaction. A `RAISE` at any step rolls everything back — no half-placed orders.
- **Isolation**: `SELECT ... FOR UPDATE` prevents the classic "sell the last portion twice" race. The second writer blocks, re-reads, and correctly fails.
- **Routing via partitioning**: `orders` is `PARTITION BY RANGE (created_at)` monthly. The insert automatically lands in the right partition; queries that filter by `created_at` only scan the relevant month.

## Report path — materialized views

```mermaid
flowchart LR
    orders[(orders partition 2026-04)]
    items[(order_items)]
    mv[mv_daily_revenue_by_branch<br/>REFRESH CONCURRENTLY nightly]
    api[[FastAPI /reports/daily-revenue]]
    dash[Dashboard chart]

    orders --> mv
    items --> mv
    mv -->|indexed by branch_id, date| api
    api --> dash
```

Dashboard queries read a pre-aggregated materialized view, not the raw `orders` table. Response times are constant no matter how many historical rows accumulate. The view has a unique index on `(branch_id, revenue_date)` so `REFRESH MATERIALIZED VIEW CONCURRENTLY` works and doesn't block readers.

## Deployment layout (recommended)

```mermaid
flowchart TB
    subgraph client[Client]
        browser
    end
    subgraph host[docker-compose host]
        frontend(Next.js container :3000)
        backend(FastAPI container :8000)
        pg[(PostgreSQL :5432)]
        pgadmin[pgAdmin :5050]
    end
    subgraph storage[Persistent volumes]
        pgdata[pgdata/]
        backups[db/backup/backups/]
    end

    browser -->|HTTPS via reverse proxy| frontend
    frontend --> backend
    backend --> pg
    pgadmin -.read-only.-> pg
    pg --> pgdata
    pg -->|nightly pg_dump| backups
```

For a real deployment the reverse proxy (nginx / Caddy) terminates TLS, forwards `/` to `frontend:3000` and `/api/*` to `backend:8000`. Secrets live in environment files mounted at container start — never baked into images.
