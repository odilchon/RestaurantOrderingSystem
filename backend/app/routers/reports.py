from datetime import UTC, date
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel

from ..db import tenant_connection
from .auth import CurrentUser, get_current_user

router = APIRouter()


# --------------------------------------------------------------------------
# Schemas
# --------------------------------------------------------------------------


class DailyRevenueRow(BaseModel):
    branch_id: UUID
    branch_name: str | None
    revenue_date: date
    orders_count: int
    revenue_total: float
    avg_check: float


class TopItemRow(BaseModel):
    menu_item_id: UUID
    branch_id: UUID
    menu_item_name: str
    category_name: str | None
    units_sold: float
    revenue: float
    revenue_rank: int


class LowStockRow(BaseModel):
    branch_id: UUID
    branch_name: str
    ingredient_id: UUID
    ingredient_name: str
    unit: str
    quantity: float
    reorder_level: float
    shortfall: float


class OrderTypeSplitRow(BaseModel):
    order_type: str
    orders_count: int
    revenue: float


class CategoryBreakdownRow(BaseModel):
    category_id: UUID
    category_name: str
    units_sold: float
    revenue: float


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------


def _days_window(days: int) -> tuple[date, date]:
    from datetime import datetime, timedelta

    today = datetime.now(UTC).date()
    return today - timedelta(days=days), today


# --------------------------------------------------------------------------
# Endpoints
# --------------------------------------------------------------------------


@router.get("/daily-revenue", response_model=list[DailyRevenueRow])
async def daily_revenue(
    days: int = Query(default=30, ge=1, le=365),
    branch_id: UUID | None = Query(default=None),
    current: CurrentUser = Depends(get_current_user),
) -> list[DailyRevenueRow]:
    where = ["mv.revenue_date >= CURRENT_DATE - %s::int"]
    params: list = [days]
    if branch_id is not None:
        where.append("mv.branch_id = %s")
        params.append(branch_id)

    async with tenant_connection(
        tenant_id=current.tenant_id, user_id=current.user_id, role=current.role
    ) as conn, conn.cursor() as cur:
        await cur.execute(
            f"""
                SELECT mv.branch_id, b.name AS branch_name, mv.revenue_date,
                       mv.orders_count, mv.revenue_total, mv.avg_check
                  FROM mv_daily_revenue_by_branch mv
             LEFT JOIN branches b ON b.branch_id = mv.branch_id
                 WHERE {' AND '.join(where)}
              ORDER BY mv.revenue_date DESC, branch_name
                """,
            params,
        )
        rows = await cur.fetchall()
    return [
        DailyRevenueRow(
            branch_id=r[0],
            branch_name=r[1],
            revenue_date=r[2],
            orders_count=r[3],
            revenue_total=float(r[4]),
            avg_check=float(r[5]),
        )
        for r in rows
    ]


@router.get("/top-items", response_model=list[TopItemRow])
async def top_items(
    days: int = Query(default=30, ge=1, le=365),
    branch_id: UUID | None = Query(default=None),
    category_id: UUID | None = Query(default=None),
    metric: str = Query(default="revenue", pattern="^(revenue|units)$"),
    limit: int = Query(default=50, ge=1, le=200),
    current: CurrentUser = Depends(get_current_user),
) -> list[TopItemRow]:
    where = ["o.created_at >= NOW() - (%s || ' days')::INTERVAL"]
    params: list = [days]
    if branch_id is not None:
        where.append("o.branch_id = %s")
        params.append(branch_id)
    if category_id is not None:
        where.append("mi.category_id = %s")
        params.append(category_id)

    metric_sql = "SUM(oi.line_total)" if metric == "revenue" else "SUM(oi.quantity)"

    async with tenant_connection(
        tenant_id=current.tenant_id, user_id=current.user_id, role=current.role
    ) as conn, conn.cursor() as cur:
        await cur.execute(
            f"""
                SELECT oi.menu_item_id,
                       o.branch_id,
                       MAX(oi.item_name_snapshot) AS name,
                       MAX(c.name)                AS category_name,
                       SUM(oi.quantity)           AS units_sold,
                       SUM(oi.line_total)         AS revenue,
                       DENSE_RANK() OVER (
                           PARTITION BY o.branch_id ORDER BY {metric_sql} DESC
                       ) AS revenue_rank
                  FROM order_items oi
                  JOIN orders o
                    ON o.order_id = oi.order_id
                   AND o.created_at = oi.order_created_at
                  JOIN menu_items mi ON mi.menu_item_id = oi.menu_item_id
             LEFT JOIN categories c ON c.category_id = mi.category_id
                 WHERE o.status NOT IN ('cancelled','draft')
                   AND {' AND '.join(where)}
              GROUP BY oi.menu_item_id, o.branch_id
              ORDER BY revenue DESC
                 LIMIT %s
                """,
            [*params, limit],
        )
        rows = await cur.fetchall()
    return [
        TopItemRow(
            menu_item_id=r[0],
            branch_id=r[1],
            menu_item_name=r[2],
            category_name=r[3],
            units_sold=float(r[4]),
            revenue=float(r[5]),
            revenue_rank=r[6],
        )
        for r in rows
    ]


@router.get("/low-stock", response_model=list[LowStockRow])
async def low_stock(
    branch_id: UUID | None = Query(default=None),
    current: CurrentUser = Depends(get_current_user),
) -> list[LowStockRow]:
    where = ["1 = 1"]
    params: list = []
    if branch_id is not None:
        where.append("branch_id = %s")
        params.append(branch_id)
    async with tenant_connection(
        tenant_id=current.tenant_id, user_id=current.user_id, role=current.role
    ) as conn, conn.cursor() as cur:
        await cur.execute(
            f"""
                SELECT branch_id, branch_name, ingredient_id, ingredient_name,
                       unit, quantity, reorder_level, shortfall
                  FROM v_low_stock
                 WHERE {' AND '.join(where)}
                 ORDER BY branch_name, ingredient_name
                """,
            params,
        )
        rows = await cur.fetchall()
    return [
        LowStockRow(
            branch_id=r[0],
            branch_name=r[1],
            ingredient_id=r[2],
            ingredient_name=r[3],
            unit=r[4],
            quantity=float(r[5]),
            reorder_level=float(r[6]),
            shortfall=float(r[7]),
        )
        for r in rows
    ]


@router.get("/order-types", response_model=list[OrderTypeSplitRow])
async def order_types(
    days: int = Query(default=30, ge=1, le=365),
    branch_id: UUID | None = Query(default=None),
    current: CurrentUser = Depends(get_current_user),
) -> list[OrderTypeSplitRow]:
    where = [
        "created_at >= NOW() - (%s || ' days')::INTERVAL",
        "status NOT IN ('cancelled','draft')",
    ]
    params: list = [days]
    if branch_id is not None:
        where.append("branch_id = %s")
        params.append(branch_id)
    async with tenant_connection(
        tenant_id=current.tenant_id, user_id=current.user_id, role=current.role
    ) as conn, conn.cursor() as cur:
        await cur.execute(
            f"""
                SELECT order_type::text, COUNT(*), COALESCE(SUM(total_amount),0)
                  FROM orders
                 WHERE {' AND '.join(where)}
              GROUP BY order_type
              ORDER BY 3 DESC
                """,
            params,
        )
        rows = await cur.fetchall()
    return [
        OrderTypeSplitRow(order_type=r[0], orders_count=r[1], revenue=float(r[2]))
        for r in rows
    ]


@router.get("/category-breakdown", response_model=list[CategoryBreakdownRow])
async def category_breakdown(
    days: int = Query(default=30, ge=1, le=365),
    branch_id: UUID | None = Query(default=None),
    current: CurrentUser = Depends(get_current_user),
) -> list[CategoryBreakdownRow]:
    where = [
        "o.created_at >= NOW() - (%s || ' days')::INTERVAL",
        "o.status NOT IN ('cancelled','draft')",
    ]
    params: list = [days]
    if branch_id is not None:
        where.append("o.branch_id = %s")
        params.append(branch_id)
    async with tenant_connection(
        tenant_id=current.tenant_id, user_id=current.user_id, role=current.role
    ) as conn, conn.cursor() as cur:
        await cur.execute(
            f"""
                SELECT c.category_id, c.name,
                       SUM(oi.quantity)   AS units_sold,
                       SUM(oi.line_total) AS revenue
                  FROM order_items oi
                  JOIN orders o
                    ON o.order_id = oi.order_id AND o.created_at = oi.order_created_at
                  JOIN menu_items mi ON mi.menu_item_id = oi.menu_item_id
                  JOIN categories c  ON c.category_id = mi.category_id
                 WHERE {' AND '.join(where)}
              GROUP BY c.category_id, c.name
              ORDER BY revenue DESC
                """,
            params,
        )
        rows = await cur.fetchall()
    return [
        CategoryBreakdownRow(
            category_id=r[0],
            category_name=r[1],
            units_sold=float(r[2]),
            revenue=float(r[3]),
        )
        for r in rows
    ]
