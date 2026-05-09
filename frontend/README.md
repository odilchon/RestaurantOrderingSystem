# ROS Frontend

Minimal Next.js 14 admin dashboard for the Restaurant Ordering System backend.

## Stack

- Next.js 14 (App Router) + React 18
- TypeScript
- Tailwind CSS (no external UI kit, ~300 lines total)

## Pages

| Path | Purpose | Backend endpoint |
|---|---|---|
| `/` | Landing + stats | — |
| `/login` | JWT sign-in | `POST /auth/login` |
| `/dashboard` | 14-day revenue (KPI cards + table) | `GET /reports/daily-revenue` |
| `/menu` | Menu grouped by category, FTS search | `GET /menu/?search=` |
| `/orders` | Latest 50 orders | `GET /orders/` |
| `/inventory` | Low-stock alerts | `GET /reports/low-stock` |
| `/reports` | Top items + category breakdown + order types | `GET /reports/top-items`, `/reports/category-breakdown`, `/reports/order-types` |

## Run

```bash
cd frontend
npm install
npm run dev          # http://localhost:3000
```

Backend must be running at `http://localhost:8000`. Override with
`NEXT_PUBLIC_API_URL` if different.

Sign in with one of the seeded accounts (see `scripts/seed_faker.py`):

- `owner.alpha@demo.test / demo1234` — tenant Alpha
- `owner.beta@demo.test / demo1234` — tenant Beta

JWT is stored in `localStorage` and attached as `Authorization: Bearer` on every
fetch via `lib/api.ts`.
