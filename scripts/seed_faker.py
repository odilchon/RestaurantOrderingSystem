#!/usr/bin/env python3
"""seed_faker.py — генерация реалистичных данных через Faker.

Наполняет БД уже применённой схемой (db/01..12 загружены). Создаёт:
- ~40 клиентов;
- ~60 дополнительных menu_item_prices (история цен);
- ~1200 заказов за последние 90 дней (через fn_place_order);
- платежи и loyalty транзакции (через fn_close_order);
- inventory pre-fill чтобы хватило на все заказы.

Запуск:
    POSTGRES_PASSWORD=... python scripts/seed_faker.py
"""
from __future__ import annotations

import os
import random
import sys
from datetime import UTC, datetime, timedelta
from uuid import UUID

try:
    import psycopg
    from faker import Faker
except ImportError:
    print("Run: pip install 'psycopg[binary]' faker", file=sys.stderr)
    sys.exit(1)


DSN = (
    f"host={os.environ.get('POSTGRES_HOST', 'localhost')} "
    f"port={os.environ.get('POSTGRES_PORT', '5432')} "
    f"user={os.environ.get('POSTGRES_USER', 'ros_admin')} "
    f"password={os.environ.get('POSTGRES_PASSWORD', '')} "
    f"dbname={os.environ.get('POSTGRES_DB', 'restaurant_ordering')}"
)

TENANT_ID = UUID("11111111-1111-1111-1111-111111111111")
BRANCH_ID = UUID("b1000000-0000-0000-0000-000000000001")
TABLE_IDS = [
    UUID("b3000000-0000-0000-0000-000000000001"),
    UUID("b3000000-0000-0000-0000-000000000002"),
]
WAITER_ID = UUID("a1000000-0000-0000-0000-000000000002")

NUM_CUSTOMERS = 40
NUM_ORDERS = 1200
DAYS_BACK = 90

fake = Faker(["ru_RU"])
random.seed(42)
Faker.seed(42)


def seed_customers(cur) -> list[UUID]:
    print(f"[seed] Creating {NUM_CUSTOMERS} customers...")
    ids: list[UUID] = []
    for _ in range(NUM_CUSTOMERS):
        full_name = fake.name()
        email = fake.unique.email()
        phone = f"+996{random.randint(500000000, 799999999)}"
        cur.execute(
            """
            INSERT INTO users (email, phone, password_hash, full_name, locale)
            VALUES (%s, %s, %s, %s, 'ru')
            ON CONFLICT (email) DO NOTHING
            RETURNING user_id
            """,
            (email, phone, "$2b$12$dummyhashdummyhashdummyhashdummyhashdummy", full_name),
        )
        row = cur.fetchone()
        if row:
            ids.append(row[0])
            cur.execute(
                "INSERT INTO user_roles (user_id, role) VALUES (%s, 'customer') ON CONFLICT DO NOTHING",
                (row[0],),
            )
    return ids


def top_up_inventory(cur) -> None:
    print("[seed] Topping up inventory to support 1200 orders...")
    cur.execute(
        """
        UPDATE inventory SET quantity = 100000, updated_at = NOW()
         WHERE branch_id = %s
        """,
        (BRANCH_ID,),
    )


def seed_price_history(cur) -> None:
    print("[seed] Creating menu_item_prices history entries...")
    cur.execute(
        "SELECT menu_item_id, base_price FROM menu_items WHERE tenant_id = %s",
        (TENANT_ID,),
    )
    for menu_item_id, base_price in cur.fetchall():
        for months_ago in (6, 3):
            old_price = float(base_price) * random.uniform(0.85, 0.98)
            valid_from = datetime.now(UTC) - timedelta(days=30 * months_ago)
            valid_to = valid_from + timedelta(days=30)
            cur.execute(
                """
                INSERT INTO menu_item_prices (menu_item_id, price, valid_from, valid_to)
                VALUES (%s, %s, %s, %s)
                """,
                (menu_item_id, round(old_price, 2), valid_from, valid_to),
            )
        cur.execute(
            """
            INSERT INTO menu_item_prices (menu_item_id, price, valid_from, valid_to)
            VALUES (%s, %s, NOW() - INTERVAL '30 days', NULL)
            """,
            (menu_item_id, base_price),
        )


def seed_orders(cur, customer_ids: list[UUID]) -> None:
    print(f"[seed] Placing {NUM_ORDERS} orders over last {DAYS_BACK} days...")

    cur.execute(
        "SELECT menu_item_id FROM menu_items WHERE tenant_id = %s AND is_active",
        (TENANT_ID,),
    )
    menu_ids = [row[0] for row in cur.fetchall()]
    if not menu_ids:
        print("[seed] No menu items — abort", file=sys.stderr)
        return

    now = datetime.now(UTC)
    order_types = ["dine_in", "takeaway", "delivery"]
    placed = 0

    for i in range(NUM_ORDERS):
        offset_days = random.uniform(0, DAYS_BACK)
        peak_hour = random.choice([12, 13, 14, 19, 20, 21])
        created = now - timedelta(days=offset_days, hours=random.randint(-1, 1))
        created = created.replace(hour=peak_hour, minute=random.randint(0, 59))

        # items: 1-4 позиции случайно
        items_count = random.randint(1, 4)
        items = [
            {
                "menu_item_id": str(random.choice(menu_ids)),
                "quantity": random.randint(1, 3),
            }
            for _ in range(items_count)
        ]

        order_type = random.choices(order_types, weights=[0.7, 0.2, 0.1])[0]
        table_id = random.choice(TABLE_IDS) if order_type == "dine_in" else None
        customer_id = random.choice(customer_ids) if random.random() > 0.3 else None

        # Используем fn_place_order но с подменой created_at через временное
        # UPDATE после создания (fn всегда ставит NOW()).
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
                f"Seeded order #{i}",
            ),
        )
        order_row = cur.fetchone()
        if order_row is None:
            continue
        order_id, current_created, total = order_row

        # Переносим заказ в прошлое: партиция на месяц created уже создана
        # в 04_partitions.sql. Если нет — создаём.
        cur.execute("SELECT ensure_orders_partition(%s::date)", (created.date(),))

        try:
            # FK из order_items.(order_id, order_created_at) → orders.(order_id, created_at)
            # блокирует синхронный UPDATE. Временно отключаем FK-триггеры
            # через session_replication_role = replica (superuser only).
            cur.execute("SET LOCAL session_replication_role = replica")
            cur.execute(
                "UPDATE order_items SET order_created_at = %s WHERE order_id = %s AND order_created_at = %s",
                (created, order_id, current_created),
            )
            cur.execute(
                "UPDATE order_status_history SET order_created_at = %s WHERE order_id = %s AND order_created_at = %s",
                (created, order_id, current_created),
            )
            cur.execute(
                """
                UPDATE orders
                   SET created_at = %s, updated_at = %s
                 WHERE order_id = %s AND created_at = %s
                """,
                (created, created, order_id, current_created),
            )
            cur.execute("SET LOCAL session_replication_role = DEFAULT")
        except psycopg.errors.Error:
            # Некоторые партиционированные UPDATE-перемещения запрещены,
            # пропускаем — заказ остаётся с current_created.
            cur.connection.rollback()
            continue

        # Закрываем ~85% заказов; остальные оставляем в разных статусах
        roll = random.random()
        if roll < 0.85:
            method = random.choice(["cash", "card", "elsom", "mbank"])
            tip = float(total) * random.uniform(0.0, 0.10)
            from decimal import Decimal
            cur.execute(
                "SELECT fn_close_order(%s, %s, %s::payment_method, %s::numeric, %s::numeric, %s)",
                (order_id, created, method, Decimal(str(total)), Decimal(str(round(tip, 2))), WAITER_ID),
            )
        elif roll < 0.92:
            cur.execute(
                "UPDATE orders SET status = 'cancelled' WHERE order_id = %s AND created_at = %s",
                (order_id, created),
            )

        placed += 1
        if placed % 100 == 0:
            print(f"[seed]   ...{placed} orders placed")
            cur.connection.commit()

    cur.connection.commit()
    print(f"[seed] Done: {placed} orders persisted.")


def refresh_mvs(cur) -> None:
    print("[seed] Refreshing materialized views (first-time, no CONCURRENTLY)...")
    cur.execute("SELECT refresh_all_materialized_views(FALSE)")


def main() -> None:
    print(f"[seed] Connecting: {DSN.replace('password=', 'password=***')}")
    with psycopg.connect(DSN, autocommit=False) as conn, conn.cursor() as cur:
        # Обходим RLS для seed-операций
        cur.execute("SET session_replication_role = 'replica'")
        try:
            top_up_inventory(cur)
            seed_price_history(cur)
            customer_ids = seed_customers(cur)
            if not customer_ids:
                cur.execute("SELECT user_id FROM users WHERE email LIKE '%@example%' LIMIT 40")
                customer_ids = [row[0] for row in cur.fetchall()]
            conn.commit()

            cur.execute("SET session_replication_role = 'origin'")
            seed_orders(cur, customer_ids)

            cur.execute("SET session_replication_role = 'replica'")
            refresh_mvs(cur)
            conn.commit()
        except Exception:
            conn.rollback()
            raise
    print("[seed] All done.")


if __name__ == "__main__":
    main()
