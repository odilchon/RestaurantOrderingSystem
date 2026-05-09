"""Meta endpoints — self-describing stats about the DB itself.

Used by the public homepage so the "31 tables / 6 functions / …" numbers
are queried live from pg_catalog instead of being hardcoded copy-paste.
"""
from __future__ import annotations

from fastapi import APIRouter
from pydantic import BaseModel

from ..db import tenant_connection

router = APIRouter()


class SchemaStats(BaseModel):
    base_tables: int
    partitions: int
    views: int
    materialized_views: int
    functions: int
    triggers: int
    indexes: int
    rls_policies: int
    db_roles: int


@router.get("/stats", response_model=SchemaStats)
async def stats() -> SchemaStats:
    sql = """
        SELECT
          (SELECT count(*) FROM pg_class c
             JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'public' AND c.relkind = 'r'
              AND NOT c.relispartition)                                       AS base_tables,
          (SELECT count(*) FROM pg_class c
             JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'public' AND c.relkind = 'r'
              AND c.relispartition)                                           AS partitions,
          (SELECT count(*) FROM pg_views  WHERE schemaname = 'public')        AS views,
          (SELECT count(*) FROM pg_matviews WHERE schemaname = 'public')      AS mviews,
          (SELECT count(*) FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.prokind = 'f')                   AS functions,
          (SELECT count(DISTINCT tgname) FROM pg_trigger
            WHERE NOT tgisinternal)                                           AS triggers,
          (SELECT count(*) FROM pg_indexes WHERE schemaname = 'public')       AS indexes,
          (SELECT count(*) FROM pg_policies WHERE schemaname = 'public')      AS rls_policies,
          (SELECT count(*) FROM pg_roles
            WHERE rolname LIKE 'app\\_%' ESCAPE '\\')                          AS db_roles
    """
    async with tenant_connection() as conn, conn.cursor() as cur:
        await cur.execute(sql)
        row = await cur.fetchone()
    return SchemaStats(
        base_tables=row[0],
        partitions=row[1],
        views=row[2],
        materialized_views=row[3],
        functions=row[4],
        triggers=row[5],
        indexes=row[6],
        rls_policies=row[7],
        db_roles=row[8],
    )
