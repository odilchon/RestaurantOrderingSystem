from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel

from ..db import tenant_connection
from .auth import CurrentUser, get_current_user

router = APIRouter()


class CategoryOut(BaseModel):
    category_id: UUID
    name: str
    slug: str
    sort_order: int
    items_count: int


class MenuItemOut(BaseModel):
    menu_item_id: UUID
    category_id: UUID
    category_name: str
    name: str
    description: str | None
    current_price: float
    preparation_minutes: int | None
    calories: int | None
    photo_url: str | None = None


@router.get("/categories", response_model=list[CategoryOut])
async def list_categories(
    current: CurrentUser = Depends(get_current_user),
) -> list[CategoryOut]:
    async with tenant_connection(
        tenant_id=current.tenant_id, user_id=current.user_id, role=current.role
    ) as conn, conn.cursor() as cur:
        await cur.execute(
            """
                SELECT c.category_id, c.name, c.slug, c.sort_order,
                       COUNT(mi.menu_item_id) FILTER (WHERE mi.is_active) AS items_count
                  FROM categories c
             LEFT JOIN menu_items mi ON mi.category_id = c.category_id
                 WHERE c.is_active = TRUE
              GROUP BY c.category_id, c.name, c.slug, c.sort_order
              ORDER BY c.sort_order, c.name
                """
        )
        rows = await cur.fetchall()
    return [
        CategoryOut(
            category_id=r[0], name=r[1], slug=r[2], sort_order=r[3], items_count=r[4]
        )
        for r in rows
    ]


@router.get("/", response_model=list[MenuItemOut])
async def list_menu(
    search: str | None = Query(default=None),
    category_id: UUID | None = Query(default=None),
    branch_id: UUID | None = Query(default=None),
    sort: str = Query(default="category", pattern="^(category|name_asc|name_desc|price_asc|price_desc)$"),
    limit: int = Query(default=200, ge=1, le=500),
    current: CurrentUser = Depends(get_current_user),
) -> list[MenuItemOut]:
    order_map = {
        "category": "m.category_name, m.name",
        "name_asc": "m.name ASC",
        "name_desc": "m.name DESC",
        "price_asc": "effective_price ASC",
        "price_desc": "effective_price DESC",
    }
    order_by = order_map[sort]

    where = ["TRUE"]
    params: list = []
    if category_id is not None:
        where.append("m.category_id = %s")
        params.append(category_id)
    if branch_id is not None:
        where.append(
            "(mba.branch_id IS NULL OR (mba.branch_id = %s AND mba.is_available))"
        )
        params.append(branch_id)
    if search:
        where.append(
            "(mi.search_vector @@ plainto_tsquery('simple', %s) "
            " OR mi.name ILIKE '%%' || %s || '%%')"
        )
        params.append(search)
        params.append(search)

    sql = f"""
        SELECT m.menu_item_id, m.category_id, m.category_name, m.name, m.description,
               COALESCE(mba.price_override, m.current_price) AS effective_price,
               m.preparation_minutes, m.calories, m.photo_url
          FROM v_active_menu m
          JOIN menu_items mi ON mi.menu_item_id = m.menu_item_id
     LEFT JOIN menu_item_branch_availability mba
            ON mba.menu_item_id = m.menu_item_id
           AND mba.branch_id = %s
         WHERE {' AND '.join(where)}
      ORDER BY {order_by}
         LIMIT %s
    """
    # branch_id is injected into the LEFT JOIN (positional) even if None;
    # psycopg handles NULL.
    full_params = [branch_id, *params, limit]

    async with tenant_connection(
        tenant_id=current.tenant_id, user_id=current.user_id, role=current.role
    ) as conn, conn.cursor() as cur:
        await cur.execute(sql, full_params)
        rows = await cur.fetchall()
    return [
        MenuItemOut(
            menu_item_id=r[0],
            category_id=r[1],
            category_name=r[2],
            name=r[3],
            description=r[4],
            current_price=float(r[5]),
            preparation_minutes=r[6],
            calories=r[7],
            photo_url=r[8],
        )
        for r in rows
    ]
