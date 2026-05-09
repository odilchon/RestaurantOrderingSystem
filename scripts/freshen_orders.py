#!/usr/bin/env python3
"""Generate fresh orders for the last 14 days so the dashboard has data.

Idempotent enough for repeated demo runs: appends ~200 orders, closes 90% of
them, refreshes materialized views.
"""
from __future__ import annotations

import os
import random
import sys
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from uuid import UUID

import psycopg
import psycopg.types.json

DSN = os.environ.get(
    "DATABASE_URL",
    "postgresql://ros_admin:ros_dev_password@127.0.0.1:5433/restaurant_ordering",
)

TENANT_ID = UUID("11111111-1111-1111-1111-111111111111")
BRANCH_ID = UUID("b1000000-0000-0000-0000-000000000001")
WAITER_ID = UUID("a1000000-0000-0000-0000-000000000002")

NUM_ORDERS = 220
DAYS_BACK = 14

random.seed()


def main() -> None:
    with psycopg.connect(DSN, autocommit=False) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT table_id FROM restaurant_tables WHERE branch_id = %s",
            (BRANCH_ID,),
        )
        table_ids = [r[0] for r in cur.fetchall()]
        if not table_ids:
            print("No tables — abort", file=sys.stderr)
            sys.exit(1)

        cur.execute(
            "SELECT menu_item_id FROM menu_items WHERE tenant_id = %s AND is_active",
            (TENANT_ID,),
        )
        menu_ids = [r[0] for r in cur.fetchall()]
        if not menu_ids:
            print("No menu items — abort", file=sys.stderr)
            sys.exit(1)

        cur.execute(
            "SELECT u.user_id FROM users u "
            "WHERE NOT EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = u.user_id "
            "AND ur.tenant_id = %s)",
            (TENANT_ID,),
        )
        customer_ids = [r[0] for r in cur.fetchall()]

        # Top-up inventory so we don't hit stock errors mid-run.
        cur.execute(
            "UPDATE inventory SET quantity = quantity + 5000 WHERE branch_id = %s",
            (BRANCH_ID,),
        )

        now = datetime.now(UTC)
        order_types = ["dine_in", "takeaway", "delivery"]
        placed = 0

        for i in range(NUM_ORDERS):
            offset_days = random.uniform(0, DAYS_BACK)
            peak_hour = random.choice([12, 13, 14, 19, 20, 21])
            created = now - timedelta(days=offset_days)
            created = created.replace(
                hour=peak_hour, minute=random.randint(0, 59), second=0, microsecond=0
            )

            items = [
                {
                    "menu_item_id": str(random.choice(menu_ids)),
                    "quantity": random.randint(1, 3),
                }
                for _ in range(random.randint(1, 4))
            ]

            order_type = random.choices(order_types, weights=[0.7, 0.2, 0.1])[0]
            table_id = random.choice(table_ids) if order_type == "dine_in" else None
            customer_id = (
                random.choice(customer_ids)
                if customer_ids and random.random() > 0.3
                else None
            )

            try:
                cur.execute(
                    """
                        SELECT order_id, order_created_at, total
                          FROM fn_place_order(%s, %s, %s, %s, %s, %s::order_type, %s::jsonb, %s)
                        """,
                    (
                        TENANT_ID,
                        BRANCH_ID,
                        table_id,
                        WAITER_ID,
                        customer_id,
                        order_type,
                        psycopg.types.json.Jsonb(items),
                        f"Demo order #{i}",
                    ),
                )
                order_id, current_created, total = cur.fetchone()
            except psycopg.errors.RaiseException:
                conn.rollback()
                continue

            cur.execute("SELECT ensure_orders_partition(%s::date)", (created.date(),))

            try:
                cur.execute("SET LOCAL session_replication_role = replica")
                cur.execute(
                    "UPDATE order_items SET order_created_at = %s "
                    "WHERE order_id = %s AND order_created_at = %s",
                    (created, order_id, current_created),
                )
                cur.execute(
                    "UPDATE order_status_history SET order_created_at = %s "
                    "WHERE order_id = %s AND order_created_at = %s",
                    (created, order_id, current_created),
                )
                cur.execute(
                    "UPDATE orders SET created_at = %s, updated_at = %s "
                    "WHERE order_id = %s AND created_at = %s",
                    (created, created, order_id, current_created),
                )
                cur.execute("SET LOCAL session_replication_role = DEFAULT")
            except psycopg.errors.Error:
                conn.rollback()
                continue

            # Close ~92% of orders
            if random.random() < 0.92:
                method = random.choice(["cash", "card", "elsom", "mbank"])
                tip = float(total) * random.uniform(0.0, 0.10)
                try:
                    cur.execute(
                        "SELECT fn_close_order(%s, %s, %s::payment_method, "
                        "%s::numeric, %s::numeric, %s)",
                        (
                            order_id,
                            created,
                            method,
                            Decimal(str(total)),
                            Decimal(str(round(tip, 2))),
                            WAITER_ID,
                        ),
                    )
                except psycopg.errors.Error:
                    conn.rollback()
                    continue

            placed += 1
            if placed % 50 == 0:
                conn.commit()
                print(f"  …{placed} placed")

        conn.commit()
        print(f"[ok] Placed {placed} orders over last {DAYS_BACK} days")

        print("[seed] Refreshing materialized views…")
        for mv in (
            "mv_daily_revenue_by_branch",
            "mv_top_menu_items_30d",
        ):
            try:
                cur.execute(f"REFRESH MATERIALIZED VIEW CONCURRENTLY {mv}")
            except psycopg.errors.Error:
                conn.rollback()
                cur.execute(f"REFRESH MATERIALIZED VIEW {mv}")
        conn.commit()
        print("[ok] Materialized views refreshed")


if __name__ == "__main__":
    main()
