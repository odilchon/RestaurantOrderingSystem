"""Lookup endpoints for the UI: tenants, branches, tables."""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel

from ..db import tenant_connection
from .auth import CurrentUser, get_current_user

router = APIRouter()


class TenantOut(BaseModel):
    tenant_id: UUID
    slug: str
    name: str


class BranchOut(BaseModel):
    branch_id: UUID
    name: str
    code: str
    address: str | None = None
    city: str | None = None  # derived from address for display
    phone: str | None = None
    is_active: bool = True


class TableOut(BaseModel):
    table_id: UUID
    branch_id: UUID
    table_number: str
    seats: int
    zone_name: str | None = None
    status: str = "available"
    is_occupied: bool = False


@router.get("/tenants", response_model=list[TenantOut])
async def list_tenants(
    current: CurrentUser = Depends(get_current_user),
) -> list[TenantOut]:
    """List tenants visible to the caller. Due to RLS this is usually 1."""
    async with tenant_connection(
        tenant_id=current.tenant_id, user_id=current.user_id, role=current.role
    ) as conn, conn.cursor() as cur:
        await cur.execute(
            "SELECT tenant_id, slug, name FROM tenants ORDER BY name"
        )
        rows = await cur.fetchall()
    return [TenantOut(tenant_id=r[0], slug=r[1], name=r[2]) for r in rows]


@router.get("/branches", response_model=list[BranchOut])
async def list_branches(
    active_only: bool = Query(default=True),
    current: CurrentUser = Depends(get_current_user),
) -> list[BranchOut]:
    sql = """
        SELECT branch_id, name, code, address, phone, is_active
          FROM branches
         {where}
         ORDER BY name
    """.format(where="WHERE is_active = TRUE" if active_only else "")
    async with tenant_connection(
        tenant_id=current.tenant_id, user_id=current.user_id, role=current.role
    ) as conn, conn.cursor() as cur:
        await cur.execute(sql)
        rows = await cur.fetchall()
    return [
        BranchOut(
            branch_id=r[0],
            name=r[1],
            code=r[2],
            address=r[3],
            city=r[3],  # address doubles as city label
            phone=r[4],
            is_active=r[5],
        )
        for r in rows
    ]


@router.get("/branches/{branch_id}/tables", response_model=list[TableOut])
async def list_tables(
    branch_id: UUID,
    current: CurrentUser = Depends(get_current_user),
) -> list[TableOut]:
    """Tables for a branch, enriched with current occupancy (v_table_occupancy)."""
    async with tenant_connection(
        tenant_id=current.tenant_id, user_id=current.user_id, role=current.role
    ) as conn, conn.cursor() as cur:
        await cur.execute(
            """
                SELECT t.table_id,
                       t.branch_id,
                       t.table_number,
                       t.capacity,
                       z.name AS zone_name,
                       t.status::text,
                       COALESCE(occ.active_order_id IS NOT NULL, FALSE) AS is_occupied
                  FROM restaurant_tables t
                  LEFT JOIN zones z ON z.zone_id = t.zone_id
                  LEFT JOIN v_table_occupancy occ ON occ.table_id = t.table_id
                 WHERE t.branch_id = %s
                 ORDER BY t.table_number
                """,
            (branch_id,),
        )
        rows = await cur.fetchall()
    return [
        TableOut(
            table_id=r[0],
            branch_id=r[1],
            table_number=r[2],
            seats=r[3],
            zone_name=r[4],
            status=r[5],
            is_occupied=bool(r[6]),
        )
        for r in rows
    ]
