"""Row-Level Security tests.

Проверяем что:
1. Без app.current_tenant_id выборка из tenant-scoped таблиц пустая.
2. Tenant A видит только свои данные.
3. Tenant B не видит данные tenant A.
4. app_admin (BYPASSRLS) видит всё.

ВАЖНО: эти тесты работают только если:
- используемый user (ros_admin) НЕ имеет BYPASSRLS, либо
- мы явно делаем SET ROLE на app_readonly/app_waiter перед тестом.

ros_admin — суперпользователь, поэтому делаем SET ROLE.
"""
from __future__ import annotations

import psycopg
from _constants import TENANT_A, TENANT_B


def _set_waiter_role(cur: psycopg.Cursor) -> None:
    cur.execute("SET ROLE app_waiter")


def test_no_tenant_no_rows(conn: psycopg.Connection) -> None:
    """Без app.current_tenant_id — видно 0 строк (не ошибка, но пусто)."""
    with conn.cursor() as cur:
        _set_waiter_role(cur)
        # app.current_tenant_id не задан
        cur.execute("SELECT COUNT(*) FROM tenants")
        assert cur.fetchone()[0] == 0


def test_tenant_a_sees_only_own(conn: psycopg.Connection) -> None:
    with conn.cursor() as cur:
        _set_waiter_role(cur)
        cur.execute("SELECT set_config('app.current_tenant_id', %s, true)", (TENANT_A,))
        cur.execute("SELECT tenant_id FROM tenants")
        rows = [r[0] for r in cur.fetchall()]
        assert str(rows[0]) == TENANT_A
        assert all(str(r) == TENANT_A for r in rows)


def test_tenant_b_cannot_see_tenant_a(conn: psycopg.Connection) -> None:
    with conn.cursor() as cur:
        _set_waiter_role(cur)
        cur.execute("SELECT set_config('app.current_tenant_id', %s, true)", (TENANT_B,))
        cur.execute("SELECT COUNT(*) FROM branches WHERE tenant_id = %s", (TENANT_A,))
        assert cur.fetchone()[0] == 0


def test_admin_bypasses_rls(conn: psycopg.Connection) -> None:
    """app_admin имеет BYPASSRLS — видит все tenants без set_config."""
    with conn.cursor() as cur:
        cur.execute("SET ROLE app_admin")
        cur.execute("SELECT COUNT(*) FROM tenants")
        assert cur.fetchone()[0] >= 3


def test_orders_isolation_between_tenants(conn: psycopg.Connection) -> None:
    """orders — главная tenant-scoped таблица. Tenant A видит свои, Tenant B — нет."""
    with conn.cursor() as cur:
        _set_waiter_role(cur)
        cur.execute("SELECT set_config('app.current_tenant_id', %s, true)", (TENANT_B,))
        cur.execute("SELECT COUNT(*) FROM orders")
        tenant_b_count = cur.fetchone()[0]

        cur.execute("SELECT set_config('app.current_tenant_id', %s, true)", (TENANT_A,))
        cur.execute("SELECT COUNT(*) FROM orders")
        tenant_a_count = cur.fetchone()[0]

        assert tenant_a_count > 0
        assert tenant_b_count == 0
        assert tenant_a_count > tenant_b_count
