#!/usr/bin/env python3
"""Bootstrap TandyrOS tenant: 2 branches, menu, inventory, staff, fresh orders.

Idempotent — re-running won't duplicate data. Run this once after the initial
schema is in place; it's separate from the main seed_faker.py because we want
the second tenant to be a clear demo of multi-tenant isolation.
"""
from __future__ import annotations

import os
import random
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from uuid import UUID

import psycopg
import psycopg.types.json
from passlib.context import CryptContext

DSN = os.environ.get(
    "DATABASE_URL",
    "postgresql://ros_admin:ros_dev_password@127.0.0.1:5433/restaurant_ordering",
)

TENANT_ID = UUID("22222222-2222-2222-2222-222222222222")
OWNER_USER_ID = UUID("a1000000-0000-0000-0000-000000000011")  # owner.beta@demo.test

BRANCH_DOWNTOWN = UUID("b1000000-0000-0000-0000-000000000020")
BRANCH_DJAL = UUID("b1000000-0000-0000-0000-000000000021")

ZONE_DT_HALL = UUID("b2000000-0000-0000-0000-000000000020")
ZONE_DT_TERRACE = UUID("b2000000-0000-0000-0000-000000000021")
ZONE_DJAL_HALL = UUID("b2000000-0000-0000-0000-000000000022")

WAITER_DT_ID = UUID("a1000000-0000-0000-0000-000000000020")
WAITER_DJAL_ID = UUID("a1000000-0000-0000-0000-000000000021")

# Categories
CAT_TANDYR = UUID("c2000000-0000-0000-0000-000000000001")
CAT_KEBAB = UUID("c2000000-0000-0000-0000-000000000002")
CAT_SOUPS = UUID("c2000000-0000-0000-0000-000000000003")
CAT_SALADS = UUID("c2000000-0000-0000-0000-000000000004")
CAT_BREAD = UUID("c2000000-0000-0000-0000-000000000005")
CAT_DRINKS = UUID("c2000000-0000-0000-0000-000000000006")

# Ingredients
ING = {
    "lamb": UUID("d2000000-0000-0000-0000-000000000001"),
    "beef": UUID("d2000000-0000-0000-0000-000000000002"),
    "chicken": UUID("d2000000-0000-0000-0000-000000000003"),
    "flour": UUID("d2000000-0000-0000-0000-000000000004"),
    "onion": UUID("d2000000-0000-0000-0000-000000000005"),
    "tomato": UUID("d2000000-0000-0000-0000-000000000006"),
    "cucumber": UUID("d2000000-0000-0000-0000-000000000007"),
    "potato": UUID("d2000000-0000-0000-0000-000000000008"),
    "yogurt": UUID("d2000000-0000-0000-0000-000000000009"),
    "tea": UUID("d2000000-0000-0000-0000-000000000010"),
}

# Menu items: (uuid, sku, category, name, description, price, recipe[(ing_key, qty)])
MENU = [
    (UUID("e2000000-0000-0000-0000-000000000001"), "TND-001", CAT_TANDYR,
     "Тандыр-самса с бараниной", "Слоёная самса в тандыре, начинка из рубленой баранины", 220,
     [("lamb", 0.12), ("flour", 0.10), ("onion", 0.04)]),
    (UUID("e2000000-0000-0000-0000-000000000002"), "TND-002", CAT_TANDYR,
     "Тандыр-курица", "Целая курочка маринованная и запечённая в тандыре", 1450,
     [("chicken", 1.0), ("yogurt", 0.10)]),
    (UUID("e2000000-0000-0000-0000-000000000003"), "KBB-001", CAT_KEBAB,
     "Шашлык из баранины", "Сочный шашлык из мякоти баранины, 250 г", 590,
     [("lamb", 0.25), ("onion", 0.05)]),
    (UUID("e2000000-0000-0000-0000-000000000004"), "KBB-002", CAT_KEBAB,
     "Куриный люля", "Люля-кебаб из куриного фарша со специями, 200 г", 420,
     [("chicken", 0.20), ("onion", 0.04)]),
    (UUID("e2000000-0000-0000-0000-000000000005"), "KBB-003", CAT_KEBAB,
     "Говяжий шашлык", "Шашлык из говяжьей вырезки, 250 г", 650,
     [("beef", 0.25), ("onion", 0.05)]),
    (UUID("e2000000-0000-0000-0000-000000000006"), "SUP-001", CAT_SOUPS,
     "Шурпа", "Наваристая шурпа из баранины с овощами", 380,
     [("lamb", 0.15), ("potato", 0.10), ("onion", 0.03), ("tomato", 0.05)]),
    (UUID("e2000000-0000-0000-0000-000000000007"), "SUP-002", CAT_SOUPS,
     "Лагман по-узбекски", "Тушёное мясо с овощами и тянутой лапшой", 350,
     [("beef", 0.12), ("flour", 0.08), ("onion", 0.03), ("tomato", 0.05)]),
    (UUID("e2000000-0000-0000-0000-000000000008"), "SAL-001", CAT_SALADS,
     "Ачичук", "Узбекский салат: томаты, огурцы, лук", 220,
     [("tomato", 0.15), ("cucumber", 0.10), ("onion", 0.03)]),
    (UUID("e2000000-0000-0000-0000-000000000009"), "BRD-001", CAT_BREAD,
     "Тандыр-нон", "Свежая лепёшка из тандыра", 80,
     [("flour", 0.20)]),
    (UUID("e2000000-0000-0000-0000-000000000010"), "BRD-002", CAT_BREAD,
     "Лепёшка с кунжутом", "Тандыр-нон с кунжутом", 100,
     [("flour", 0.20)]),
    (UUID("e2000000-0000-0000-0000-000000000011"), "DRK-001", CAT_DRINKS,
     "Чай чёрный", "Чайник чёрного чая 700 мл", 180,
     [("tea", 0.005)]),
    (UUID("e2000000-0000-0000-0000-000000000012"), "DRK-002", CAT_DRINKS,
     "Айран", "Кисломолочный напиток, 300 мл", 140,
     [("yogurt", 0.30)]),
]


def upsert_branches(cur):
    cur.execute(
        """
        INSERT INTO branches (branch_id, tenant_id, code, name, address, phone, operating_hours)
        VALUES
          (%s, %s, 'TND-DT', 'TandyrOS Downtown', 'пр. Чуй 145, Бишкек', '+996700112233',
           '{"mon-sun": "10:00-23:00"}'),
          (%s, %s, 'TND-DJAL', 'TandyrOS Джал-29',  'мкр. Джал-29, 14, Бишкек', '+996700445566',
           '{"mon-sun": "11:00-23:30"}')
        ON CONFLICT (branch_id) DO NOTHING
        """,
        (BRANCH_DOWNTOWN, TENANT_ID, BRANCH_DJAL, TENANT_ID),
    )

    cur.execute(
        """
        INSERT INTO zones (zone_id, branch_id, name) VALUES
          (%s, %s, 'Основной зал'),
          (%s, %s, 'Летняя терраса'),
          (%s, %s, 'Основной зал')
        ON CONFLICT DO NOTHING
        """,
        (
            ZONE_DT_HALL, BRANCH_DOWNTOWN,
            ZONE_DT_TERRACE, BRANCH_DOWNTOWN,
            ZONE_DJAL_HALL, BRANCH_DJAL,
        ),
    )

    # Tables — 8 in Downtown (4 hall + 4 terrace), 6 in Djal
    table_specs = []
    for i in range(1, 5):
        table_specs.append((BRANCH_DOWNTOWN, ZONE_DT_HALL, f"D-{i:02d}", 4 if i % 2 else 2))
    for i in range(5, 9):
        table_specs.append((BRANCH_DOWNTOWN, ZONE_DT_TERRACE, f"D-{i:02d}", 6 if i % 2 else 4))
    for i in range(1, 7):
        table_specs.append((BRANCH_DJAL, ZONE_DJAL_HALL, f"J-{i:02d}", 4))

    for branch_id, zone_id, num, cap in table_specs:
        cur.execute(
            """
            INSERT INTO restaurant_tables (branch_id, zone_id, table_number, capacity, status)
            VALUES (%s, %s, %s, %s, 'available')
            ON CONFLICT DO NOTHING
            """,
            (branch_id, zone_id, num, cap),
        )


def upsert_categories(cur):
    cats = [
        (CAT_TANDYR, "Тандыр", "tandyr", 1),
        (CAT_KEBAB,  "Шашлык и кебаб", "kebab", 2),
        (CAT_SOUPS,  "Супы", "tnd-soups", 3),
        (CAT_SALADS, "Салаты", "tnd-salads", 4),
        (CAT_BREAD,  "Лепёшки", "bread", 5),
        (CAT_DRINKS, "Напитки", "tnd-drinks", 6),
    ]
    for cat_id, name, slug, sort_order in cats:
        cur.execute(
            """
            INSERT INTO categories (category_id, tenant_id, name, slug, sort_order)
            VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (category_id) DO NOTHING
            """,
            (cat_id, TENANT_ID, name, slug, sort_order),
        )


def upsert_ingredients(cur):
    rows = [
        (ING["lamb"],    "Баранина",    "kg",  ["meat"], 8),
        (ING["beef"],    "Говядина",    "kg",  ["meat"], 8),
        (ING["chicken"], "Курица",      "kg",  ["meat"], 10),
        (ING["flour"],   "Мука",        "kg",  ["gluten"], 15),
        (ING["onion"],   "Лук репчатый","kg",  [], 5),
        (ING["tomato"],  "Помидоры",    "kg",  [], 5),
        (ING["cucumber"],"Огурцы",      "kg",  [], 5),
        (ING["potato"],  "Картофель",   "kg",  [], 8),
        (ING["yogurt"],  "Йогурт/айран","l",   ["dairy"], 5),
        (ING["tea"],     "Чай листовой","kg",  [], 1),
    ]
    for ing_id, name, unit, allergens, reorder in rows:
        cur.execute(
            """
            INSERT INTO ingredients (ingredient_id, tenant_id, name, unit, allergens, reorder_level)
            VALUES (%s, %s, %s, %s, %s, %s)
            ON CONFLICT (ingredient_id) DO NOTHING
            """,
            (ing_id, TENANT_ID, name, unit, allergens, reorder),
        )

    # Inventory: 200 units each per branch
    for branch_id in (BRANCH_DOWNTOWN, BRANCH_DJAL):
        cur.execute(
            """
            INSERT INTO inventory (branch_id, ingredient_id, quantity)
            SELECT %s, ingredient_id, 200
              FROM ingredients
             WHERE tenant_id = %s
            ON CONFLICT (branch_id, ingredient_id) DO UPDATE
              SET quantity = GREATEST(inventory.quantity, 200)
            """,
            (branch_id, TENANT_ID),
        )


def upsert_menu(cur):
    for item_id, sku, cat_id, name, desc, price, recipe in MENU:
        cur.execute(
            """
            INSERT INTO menu_items (menu_item_id, tenant_id, category_id, sku, name,
                                    description, base_price, preparation_minutes, is_active)
            VALUES (%s, %s, %s, %s, %s, %s, %s, 20, TRUE)
            ON CONFLICT (menu_item_id) DO UPDATE SET
              category_id = EXCLUDED.category_id,
              name = EXCLUDED.name,
              description = EXCLUDED.description,
              base_price = EXCLUDED.base_price,
              is_active = TRUE
            """,
            (item_id, TENANT_ID, cat_id, sku, name, desc, price),
        )

        cur.execute(
            "SELECT 1 FROM menu_item_prices WHERE menu_item_id = %s AND valid_to IS NULL "
            "AND price = %s",
            (item_id, price),
        )
        if not cur.fetchone():
            cur.execute(
                "UPDATE menu_item_prices SET valid_to = now() "
                "WHERE menu_item_id = %s AND valid_to IS NULL",
                (item_id,),
            )
            cur.execute(
                "INSERT INTO menu_item_prices (menu_item_id, price) VALUES (%s, %s)",
                (item_id, price),
            )

        for ing_key, qty in recipe:
            cur.execute(
                """
                INSERT INTO menu_item_ingredients (menu_item_id, ingredient_id, quantity)
                VALUES (%s, %s, %s)
                ON CONFLICT (menu_item_id, ingredient_id) DO UPDATE SET quantity = EXCLUDED.quantity
                """,
                (item_id, ING[ing_key], qty),
            )

        for branch_id in (BRANCH_DOWNTOWN, BRANCH_DJAL):
            cur.execute(
                """
                INSERT INTO menu_item_branch_availability (menu_item_id, branch_id, is_available)
                VALUES (%s, %s, TRUE)
                ON CONFLICT (menu_item_id, branch_id) DO UPDATE SET is_available = TRUE
                """,
                (item_id, branch_id),
            )


def upsert_staff(cur):
    pwd_ctx = CryptContext(schemes=["bcrypt"], deprecated="auto")
    pwd_hash = pwd_ctx.hash("demo1234")

    cur.execute(
        """
        INSERT INTO users (user_id, email, password_hash, full_name, locale, is_active)
        VALUES
          (%s, 'waiter.tandyros.dt@demo.test', %s, 'Азамат (Downtown)', 'ru', TRUE),
          (%s, 'waiter.tandyros.djal@demo.test', %s, 'Эльдар (Джал)', 'ru', TRUE)
        ON CONFLICT (user_id) DO NOTHING
        """,
        (WAITER_DT_ID, pwd_hash, WAITER_DJAL_ID, pwd_hash),
    )

    cur.execute(
        """
        INSERT INTO user_roles (user_id, tenant_id, branch_id, role) VALUES
          (%s, %s, %s, 'waiter'),
          (%s, %s, %s, 'waiter')
        ON CONFLICT DO NOTHING
        """,
        (
            WAITER_DT_ID, TENANT_ID, BRANCH_DOWNTOWN,
            WAITER_DJAL_ID, TENANT_ID, BRANCH_DJAL,
        ),
    )


def seed_orders(cur, branch_id, waiter_id, count, days_back=14):
    cur.execute(
        "SELECT table_id FROM restaurant_tables WHERE branch_id = %s",
        (branch_id,),
    )
    table_ids = [r[0] for r in cur.fetchall()]
    if not table_ids:
        return 0

    menu_ids = [item[0] for item in MENU]

    now = datetime.now(UTC)
    order_types = ["dine_in", "takeaway", "delivery"]
    placed = 0

    for i in range(count):
        offset_days = random.uniform(0, days_back)
        peak_hour = random.choice([12, 13, 14, 18, 19, 20, 21])
        created = now - timedelta(days=offset_days)
        created = created.replace(hour=peak_hour, minute=random.randint(0, 59),
                                  second=0, microsecond=0)

        items = [
            {
                "menu_item_id": str(random.choice(menu_ids)),
                "quantity": random.randint(1, 3),
            }
            for _ in range(random.randint(1, 4))
        ]

        order_type = random.choices(order_types, weights=[0.65, 0.25, 0.10])[0]
        table_id = random.choice(table_ids) if order_type == "dine_in" else None

        try:
            cur.execute(
                """
                SELECT order_id, order_created_at, total
                  FROM fn_place_order(%s, %s, %s, %s, %s, %s::order_type, %s::jsonb, %s)
                """,
                (
                    TENANT_ID,
                    branch_id,
                    table_id,
                    waiter_id,
                    None,
                    order_type,
                    psycopg.types.json.Jsonb(items),
                    f"TandyrOS demo #{i}",
                ),
            )
            order_id, current_created, total = cur.fetchone()
        except psycopg.errors.RaiseException:
            cur.connection.rollback()
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
            cur.connection.rollback()
            continue

        # Close 90% of orders
        if random.random() < 0.90:
            method = random.choice(["cash", "card", "elsom", "mbank"])
            tip = float(total) * random.uniform(0.0, 0.08)
            try:
                cur.execute(
                    "SELECT fn_close_order(%s, %s, %s::payment_method, %s::numeric, "
                    "%s::numeric, %s)",
                    (
                        order_id, created, method,
                        Decimal(str(total)),
                        Decimal(str(round(tip, 2))),
                        waiter_id,
                    ),
                )
            except psycopg.errors.Error:
                cur.connection.rollback()
                continue

        placed += 1
        if placed % 30 == 0:
            cur.connection.commit()

    cur.connection.commit()
    return placed


def main():
    random.seed()
    with psycopg.connect(DSN, autocommit=False) as conn, conn.cursor() as cur:
        print("[1/5] Branches, zones, tables…")
        upsert_branches(cur)

        print("[2/5] Categories + ingredients + inventory…")
        upsert_categories(cur)
        upsert_ingredients(cur)

        print("[3/5] Menu items + recipes + availability…")
        upsert_menu(cur)

        print("[4/5] Waiters…")
        upsert_staff(cur)

        conn.commit()

        print("[5/5] Generating fresh orders for last 14 days…")
        n1 = seed_orders(cur, BRANCH_DOWNTOWN, WAITER_DT_ID, 130)
        print(f"      Downtown: {n1} orders")
        n2 = seed_orders(cur, BRANCH_DJAL, WAITER_DJAL_ID, 100)
        print(f"      Джал-29:  {n2} orders")

        print("Refreshing materialized views…")
        for mv in ("mv_daily_revenue_by_branch", "mv_top_menu_items_30d"):
            try:
                cur.execute(f"REFRESH MATERIALIZED VIEW CONCURRENTLY {mv}")
            except psycopg.errors.Error:
                conn.rollback()
                cur.execute(f"REFRESH MATERIALIZED VIEW {mv}")
        conn.commit()

    print("\n[ok] TandyrOS bootstrapped. Login as owner.beta@demo.test / demo1234")


if __name__ == "__main__":
    main()
