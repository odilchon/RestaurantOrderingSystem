"""Integration tests for fn_place_order, fn_close_order, fn_cancel_order.

Хитрость: каждый тест крутится внутри одной транзакции и всегда заканчивается
ROLLBACK (см. conftest.conn). Это позволяет писать тесты, которые создают
реальные заказы и проверяют side-effects, не захламляя БД.
"""
from __future__ import annotations

from decimal import Decimal

import psycopg
import pytest
from _constants import BRANCH_A, PLOV_ID, TABLE_A, TENANT_A, WAITER_A
from psycopg.types.json import Jsonb

# ----------------------------------------------------------------------
# fn_place_order
# ----------------------------------------------------------------------


def test_place_order_happy_path(conn: psycopg.Connection) -> None:
    """Один плов успешно создаётся, total = цена + налог + сервис."""
    with conn.cursor() as cur:
        cur.execute("SELECT set_config('app.current_tenant_id', %s, false)", (TENANT_A,))
        cur.execute(
            """
            SELECT order_id, order_created_at, total
              FROM fn_place_order(%s, %s, %s, %s, %s, %s::order_type, %s::jsonb, %s)
            """,
            (
                TENANT_A,
                BRANCH_A,
                TABLE_A,
                WAITER_A,
                None,
                "dine_in",
                Jsonb([{"menu_item_id": PLOV_ID, "quantity": 1}]),
                None,
            ),
        )
        order_id, created_at, total = cur.fetchone()
        assert order_id is not None
        # Ферганский плов 450 сом * 1.12 tax * 1.10 service = 549
        assert Decimal(total) > Decimal("500")
        assert Decimal(total) < Decimal("600")

        # Side-effect: order_items создан
        cur.execute(
            "SELECT COUNT(*) FROM order_items WHERE order_id = %s AND order_created_at = %s",
            (order_id, created_at),
        )
        assert cur.fetchone()[0] == 1


def test_place_order_multi_item_totals(conn: psycopg.Connection) -> None:
    """Два плова — total в 2 раза больше."""
    with conn.cursor() as cur:
        cur.execute("SELECT set_config('app.current_tenant_id', %s, false)", (TENANT_A,))

        def place(qty: int) -> Decimal:
            cur.execute(
                "SELECT total FROM fn_place_order(%s, %s, %s, %s, %s, %s::order_type, %s::jsonb, %s)",
                (
                    TENANT_A,
                    BRANCH_A,
                    TABLE_A,
                    WAITER_A,
                    None,
                    "dine_in",
                    Jsonb([{"menu_item_id": PLOV_ID, "quantity": qty}]),
                    None,
                ),
            )
            return Decimal(cur.fetchone()[0])

        one = place(1)
        two = place(2)
        assert abs(two - one * 2) < Decimal("0.01"), f"{two=} expected {one*2=}"


def test_place_order_insufficient_stock_raises_and_rolls_back(
    conn: psycopg.Connection,
) -> None:
    """Если риса не хватает — RAISE, и склад не трогается."""
    with conn.cursor() as cur:
        cur.execute("SELECT set_config('app.current_tenant_id', %s, false)", (TENANT_A,))

        cur.execute(
            """
            SELECT ingredient_id, quantity
              FROM inventory
             WHERE branch_id = %s
               AND ingredient_id = (SELECT ingredient_id FROM ingredients WHERE name = 'Рис девзира' LIMIT 1)
            """,
            (BRANCH_A,),
        )
        ingredient_id, _qty_before = cur.fetchone()

        cur.execute(
            "UPDATE inventory SET quantity = 0.1 WHERE branch_id = %s AND ingredient_id = %s",
            (BRANCH_A, ingredient_id),
        )

        cur.execute("SAVEPOINT before_place")
        with pytest.raises(psycopg.errors.CheckViolation):
            cur.execute(
                "SELECT fn_place_order(%s, %s, %s, %s, %s, %s::order_type, %s::jsonb, %s)",
                (
                    TENANT_A,
                    BRANCH_A,
                    TABLE_A,
                    WAITER_A,
                    None,
                    "dine_in",
                    Jsonb([{"menu_item_id": PLOV_ID, "quantity": 5}]),
                    None,
                ),
            )
        cur.execute("ROLLBACK TO SAVEPOINT before_place")

        # Склад на 0.1 как мы и ставили — 5 порций не списались
        cur.execute(
            "SELECT quantity FROM inventory WHERE branch_id = %s AND ingredient_id = %s",
            (BRANCH_A, ingredient_id),
        )
        assert cur.fetchone()[0] == Decimal("0.100")


# ----------------------------------------------------------------------
# fn_cancel_order — компенсирующая транзакция
# ----------------------------------------------------------------------


def test_cancel_order_restores_stock(conn: psycopg.Connection) -> None:
    """После fn_cancel_order остаток возвращается обратно на склад."""
    with conn.cursor() as cur:
        cur.execute("SELECT set_config('app.current_tenant_id', %s, false)", (TENANT_A,))

        cur.execute(
            """
            SELECT quantity FROM inventory
             WHERE branch_id = %s
               AND ingredient_id = (SELECT ingredient_id FROM ingredients WHERE name = 'Рис девзира' LIMIT 1)
            """,
            (BRANCH_A,),
        )
        rice_before = cur.fetchone()[0]

        cur.execute(
            "SELECT order_id, order_created_at FROM fn_place_order(%s, %s, %s, %s, %s, %s::order_type, %s::jsonb, %s)",
            (
                TENANT_A,
                BRANCH_A,
                TABLE_A,
                WAITER_A,
                None,
                "dine_in",
                Jsonb([{"menu_item_id": PLOV_ID, "quantity": 2}]),
                None,
            ),
        )
        order_id, order_created_at = cur.fetchone()

        cur.execute(
            "SELECT quantity FROM inventory WHERE branch_id = %s AND ingredient_id = (SELECT ingredient_id FROM ingredients WHERE name = 'Рис девзира' LIMIT 1)",
            (BRANCH_A,),
        )
        rice_after_place = cur.fetchone()[0]
        assert rice_after_place < rice_before

        cur.execute(
            "SELECT fn_cancel_order(%s, %s, %s)",
            (order_id, order_created_at, "Test cancellation"),
        )

        cur.execute(
            "SELECT quantity FROM inventory WHERE branch_id = %s AND ingredient_id = (SELECT ingredient_id FROM ingredients WHERE name = 'Рис девзира' LIMIT 1)",
            (BRANCH_A,),
        )
        rice_after_cancel = cur.fetchone()[0]
        assert rice_after_cancel == rice_before
