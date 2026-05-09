from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from uuid import UUID

from psycopg_pool import AsyncConnectionPool

from .config import get_settings

_pool: AsyncConnectionPool | None = None

# Map application roles → PostgreSQL DB roles (from 11_roles_grants.sql)
_ROLE_MAP: dict[str, str] = {
    "super_admin": "app_admin",
    "tenant_owner": "app_manager",
    "manager": "app_manager",
    "waiter": "app_waiter",
    "chef": "app_waiter",
    "cashier": "app_waiter",
    "customer": "app_readonly",
}


async def init_pool() -> AsyncConnectionPool:
    global _pool
    if _pool is None:
        settings = get_settings()
        _pool = AsyncConnectionPool(
            conninfo=settings.dsn,
            min_size=settings.pool_min_size,
            max_size=settings.pool_max_size,
            open=False,
        )
        await _pool.open()
    return _pool


async def close_pool() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None


@asynccontextmanager
async def tenant_connection(
    tenant_id: UUID | None = None,
    user_id: UUID | None = None,
    role: str | None = None,
) -> AsyncIterator:
    """Checked out connection with RLS GUCs set for the request's tenant/user.

    Sets SET LOCAL ROLE so that RLS policies are actually enforced, even though
    the pool connects as the superuser ros_admin. Without this, ros_admin bypasses
    all RLS policies and tenant isolation is not effective.
    """
    pool = await init_pool()
    async with pool.connection() as conn:
        async with conn.cursor() as cur:
            # Map app role to database role for RLS enforcement
            db_role = _ROLE_MAP.get(role or "", "app_waiter")
            await cur.execute(f"SET LOCAL ROLE {db_role}")
            if tenant_id is not None:
                await cur.execute(
                    "SELECT set_config('app.current_tenant_id', %s, true)",
                    (str(tenant_id),),
                )
            if user_id is not None:
                await cur.execute(
                    "SELECT set_config('app.current_user_id', %s, true)",
                    (str(user_id),),
                )
        yield conn
