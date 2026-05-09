"""Seed missing tea & cold drinks categories for the demo tenant.

Idempotent: re-running will skip items whose SKU already exists.
"""
import os
import uuid

import psycopg

DSN = os.getenv(
    "DATABASE_URL",
    "postgresql://ros_admin:ros_dev_password@127.0.0.1:5433/restaurant_ordering",
)

TEAS = [
    ("tea-earl-grey",     "Эрл Грей",            "Чёрный чай с бергамотом, чайник 500 мл",   220),
    ("tea-assam",         "Ассам",               "Крепкий индийский чёрный чай, 500 мл",     220),
    ("tea-sencha",        "Сенча",               "Японский зелёный чай, 500 мл",             220),
    ("tea-jasmine",       "Жасминовый",          "Зелёный чай с лепестками жасмина, 500 мл", 230),
    ("tea-mint",          "Марокканский с мятой","Зелёный чай со свежей мятой и мёдом",      260),
    ("tea-sea-buckthorn", "Облепиховый",         "Горячий чай с облепихой и имбирём, 400 мл",290),
    ("tea-ginger-honey",  "Имбирный с мёдом",    "Свежий имбирь, лимон, мёд, 400 мл",        280),
    ("tea-berry",         "Ягодный",             "Малина, смородина, клюква, 400 мл",        290),
    ("tea-masala",        "Масала",              "Чёрный чай со специями и молоком",         310),
    ("tea-uzbek-green",   "Узбекский зелёный",   "Классический кок-чай в чайнике, 700 мл",   240),
]

COLD_DRINKS = [
    ("cold-cola",          "Coca-Cola",          "Газированный напиток, 0.33 л",                230),
    ("cold-sprite",        "Sprite",             "Лимонно-лаймовый газированный напиток, 0.33 л",230),
    ("cold-fanta",         "Fanta",              "Апельсиновый газированный напиток, 0.33 л",   230),
    ("cold-water-still",   "Вода без газа",      "Минеральная вода без газа, 0.5 л",            120),
    ("cold-water-spark",   "Вода с газом",        "Минеральная вода с газом, 0.5 л",             120),
    ("cold-mors-cranberry","Морс клюквенный",    "Домашний морс из клюквы, 300 мл",             180),
    ("cold-mors-currant",  "Морс смородиновый",  "Домашний морс из чёрной смородины, 300 мл",   180),
    ("cold-lemonade-class","Классический лимонад","Лимон, мята, сахарный сироп, 400 мл",        260),
    ("cold-lemonade-tarhun","Лимонад «Тархун»",  "Тархун, лайм, газировка, 400 мл",             280),
    ("cold-lemonade-rasp", "Малиновый лимонад",  "Малина, базилик, лайм, 400 мл",               290),
    ("cold-juice-orange",  "Сок апельсиновый",    "Свежевыжатый, 250 мл",                       290),
    ("cold-juice-apple",   "Сок яблочный",        "Прямого отжима, 250 мл",                     220),
    ("cold-milkshake",     "Молочный коктейль",  "Ванильный пломбир, молоко, 350 мл",           320),
    ("cold-iced-coffee",   "Айс-латте",          "Эспрессо, молоко, лёд, 400 мл",               310),
    ("cold-iced-tea-peach","Айс-ти персиковый",  "Холодный чай с персиком и лимоном, 400 мл",   240),
]


def upsert_category(cur, tenant_id, name, slug, sort_order):
    cur.execute(
        "SELECT category_id FROM categories WHERE tenant_id = %s AND slug = %s",
        (tenant_id, slug),
    )
    row = cur.fetchone()
    if row:
        cur.execute(
            "UPDATE categories SET name = %s, sort_order = %s, is_active = TRUE "
            "WHERE category_id = %s",
            (name, sort_order, row[0]),
        )
        return row[0]
    cat_id = uuid.uuid4()
    cur.execute(
        "INSERT INTO categories (category_id, tenant_id, name, slug, sort_order, is_active) "
        "VALUES (%s, %s, %s, %s, %s, TRUE)",
        (cat_id, tenant_id, name, slug, sort_order),
    )
    return cat_id


def upsert_item(cur, tenant_id, category_id, branch_ids, sku, name, description, price):
    cur.execute(
        "SELECT menu_item_id FROM menu_items WHERE tenant_id = %s AND sku = %s",
        (tenant_id, sku),
    )
    row = cur.fetchone()
    if row:
        item_id = row[0]
        cur.execute(
            "UPDATE menu_items SET category_id = %s, name = %s, description = %s, "
            "base_price = %s, is_active = TRUE WHERE menu_item_id = %s",
            (category_id, name, description, price, item_id),
        )
    else:
        item_id = uuid.uuid4()
        cur.execute(
            "INSERT INTO menu_items "
            "(menu_item_id, tenant_id, category_id, sku, name, description, base_price, is_active) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s, TRUE)",
            (item_id, tenant_id, category_id, sku, name, description, price),
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

    for branch_id in branch_ids:
        cur.execute(
            "INSERT INTO menu_item_branch_availability (menu_item_id, branch_id, is_available) "
            "VALUES (%s, %s, TRUE) "
            "ON CONFLICT (menu_item_id, branch_id) DO UPDATE SET is_available = TRUE",
            (item_id, branch_id),
        )

    return item_id


def main():
    with psycopg.connect(DSN, autocommit=False) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT tenant_id FROM tenants ORDER BY created_at LIMIT 1")
            tenant_id = cur.fetchone()[0]

            cur.execute("SELECT branch_id FROM branches WHERE tenant_id = %s", (tenant_id,))
            branch_ids = [r[0] for r in cur.fetchall()]
            if not branch_ids:
                raise SystemExit("No branches for the demo tenant — run base seed first.")

            tea_id = upsert_category(cur, tenant_id, "Чай", "chai", 90)
            cold_id = upsert_category(cur, tenant_id, "Холодные напитки", "cold-drinks", 91)

            for sku, name, desc, price in TEAS:
                upsert_item(cur, tenant_id, tea_id, branch_ids, sku, name, desc, price)
            for sku, name, desc, price in COLD_DRINKS:
                upsert_item(cur, tenant_id, cold_id, branch_ids, sku, name, desc, price)

        conn.commit()
        print(f"OK: seeded {len(TEAS)} teas + {len(COLD_DRINKS)} cold drinks for tenant {tenant_id}")


if __name__ == "__main__":
    main()
