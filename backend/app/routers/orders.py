from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from psycopg import errors as pg_errors
from psycopg.types.json import Jsonb
from pydantic import BaseModel

from ..db import tenant_connection
from .auth import CurrentUser, get_current_user

router = APIRouter()


# --------------------------------------------------------------------------
# Schemas
# --------------------------------------------------------------------------


class OrderItemIn(BaseModel):
    menu_item_id: UUID
    quantity: int
    special_requests: str | None = None


class OrderCreateIn(BaseModel):
    branch_id: UUID
    table_id: UUID | None = None
    customer_id: UUID | None = None
    order_type: str = "dine_in"
    items: list[OrderItemIn]
    notes: str | None = None


class OrderCreated(BaseModel):
    order_id: UUID
    created_at: datetime
    total: Decimal


class ClosePaymentIn(BaseModel):
    method: str
    amount: Decimal
    tip: Decimal = Decimal("0")


class CancelIn(BaseModel):
    reason: str


class OrderListRow(BaseModel):
    order_id: UUID
    created_at: datetime
    branch_id: UUID
    branch_name: str | None
    table_id: UUID | None
    table_number: str | None
    waiter_name: str | None
    order_number: str
    status: str
    order_type: str
    items_count: int
    total_amount: Decimal


class OrderItemOut(BaseModel):
    order_item_id: int
    menu_item_id: UUID
    name: str
    quantity: int
    unit_price: Decimal
    line_total: Decimal
    special_requests: str | None


class StatusHistoryOut(BaseModel):
    old_status: str | None
    new_status: str
    changed_at: datetime
    notes: str | None


class PaymentOut(BaseModel):
    payment_id: UUID
    method: str
    status: str
    amount: Decimal
    tip_amount: Decimal
    created_at: datetime


class OrderDetails(BaseModel):
    order_id: UUID
    order_number: str
    created_at: datetime
    status: str
    order_type: str
    branch_id: UUID
    branch_name: str | None
    table_id: UUID | None
    table_number: str | None
    waiter_name: str | None
    customer_name: str | None
    notes: str | None
    subtotal: Decimal
    tax_amount: Decimal
    service_charge: Decimal
    discount_amount: Decimal
    total_amount: Decimal
    amount_paid: Decimal
    items: list[OrderItemOut]
    status_history: list[StatusHistoryOut]
    payments: list[PaymentOut]


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------


async def _resolve_order_created_at(cur, order_id: UUID) -> datetime:
    await cur.execute(
        "SELECT created_at FROM orders WHERE order_id = %s",
        (order_id,),
    )
    row = await cur.fetchone()
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Order not found")
    return row[0]


# --------------------------------------------------------------------------
# Routes
# --------------------------------------------------------------------------


@router.get("/", response_model=list[OrderListRow])
async def list_orders(
    limit: int = Query(default=100, ge=1, le=500),
    status_filter: str | None = Query(default=None, alias="status"),
    order_type: str | None = Query(default=None),
    branch_id: UUID | None = Query(default=None),
    table_id: UUID | None = Query(default=None),
    date_from: date | None = Query(default=None),
    date_to: date | None = Query(default=None),
    q: str | None = Query(default=None, description="search by order_number"),
    current: CurrentUser = Depends(get_current_user),
) -> list[OrderListRow]:
    where: list[str] = []
    params: list = []
    if status_filter:
        where.append("o.status::text = %s")
        params.append(status_filter)
    if order_type:
        where.append("o.order_type::text = %s")
        params.append(order_type)
    if branch_id:
        where.append("o.branch_id = %s")
        params.append(branch_id)
    if table_id:
        where.append("o.table_id = %s")
        params.append(table_id)
    if date_from:
        where.append("o.created_at >= %s")
        params.append(date_from)
    if date_to:
        where.append("o.created_at < (%s::date + INTERVAL '1 day')")
        params.append(date_to)
    if q:
        where.append("o.order_number ILIKE '%%' || %s || '%%'")
        params.append(q)

    where_sql = f"WHERE {' AND '.join(where)}" if where else ""
    sql = f"""
        SELECT o.order_id, o.created_at, o.branch_id, b.name AS branch_name,
               o.table_id, rt.table_number,
               uw.full_name AS waiter_name,
               o.order_number, o.status::text, o.order_type::text,
               (SELECT COUNT(*) FROM order_items oi
                 WHERE oi.order_id = o.order_id
                   AND oi.order_created_at = o.created_at) AS items_count,
               o.total_amount
          FROM orders o
     LEFT JOIN branches b ON b.branch_id = o.branch_id
     LEFT JOIN restaurant_tables rt ON rt.table_id = o.table_id
     LEFT JOIN users uw ON uw.user_id = o.waiter_id
          {where_sql}
      ORDER BY o.created_at DESC
         LIMIT %s
    """
    params.append(limit)

    async with tenant_connection(
        tenant_id=current.tenant_id, user_id=current.user_id, role=current.role
    ) as conn, conn.cursor() as cur:
        await cur.execute(sql, params)
        rows = await cur.fetchall()
    return [
        OrderListRow(
            order_id=r[0],
            created_at=r[1],
            branch_id=r[2],
            branch_name=r[3],
            table_id=r[4],
            table_number=r[5],
            waiter_name=r[6],
            order_number=r[7],
            status=r[8],
            order_type=r[9],
            items_count=r[10],
            total_amount=r[11],
        )
        for r in rows
    ]


@router.get("/{order_id}", response_model=OrderDetails)
async def get_order_details(
    order_id: UUID,
    current: CurrentUser = Depends(get_current_user),
) -> OrderDetails:
    async with tenant_connection(
        tenant_id=current.tenant_id, user_id=current.user_id, role=current.role
    ) as conn, conn.cursor() as cur:
        await cur.execute(
            """
                SELECT o.order_id, o.order_number, o.created_at, o.status::text,
                       o.order_type::text, o.branch_id, b.name, o.table_id,
                       rt.table_number, uw.full_name, uc.full_name, o.notes,
                       o.subtotal, o.tax_amount, o.service_charge,
                       o.discount_amount, o.total_amount,
                       COALESCE((SELECT SUM(p.amount) FROM payments p
                                  WHERE p.order_id = o.order_id
                                    AND p.order_created_at = o.created_at
                                    AND p.status IN ('captured', 'authorized')), 0)
                  FROM orders o
             LEFT JOIN branches b ON b.branch_id = o.branch_id
             LEFT JOIN restaurant_tables rt ON rt.table_id = o.table_id
             LEFT JOIN users uw ON uw.user_id = o.waiter_id
             LEFT JOIN users uc ON uc.user_id = o.customer_id
                 WHERE o.order_id = %s
                """,
            (order_id,),
        )
        head = await cur.fetchone()
        if head is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Order not found")

        order_created_at = head[2]

        await cur.execute(
            """
                SELECT order_item_id, menu_item_id, item_name_snapshot, quantity,
                       unit_price_snapshot, line_total, special_requests
                  FROM order_items
                 WHERE order_id = %s AND order_created_at = %s
                 ORDER BY order_item_id
                """,
            (order_id, order_created_at),
        )
        items = [
            OrderItemOut(
                order_item_id=r[0],
                menu_item_id=r[1],
                name=r[2],
                quantity=r[3],
                unit_price=r[4],
                line_total=r[5],
                special_requests=r[6],
            )
            for r in await cur.fetchall()
        ]

        await cur.execute(
            """
                SELECT old_status::text, new_status::text, changed_at, notes
                  FROM order_status_history
                 WHERE order_id = %s AND order_created_at = %s
                 ORDER BY changed_at
                """,
            (order_id, order_created_at),
        )
        history = [
            StatusHistoryOut(
                old_status=r[0], new_status=r[1], changed_at=r[2], notes=r[3]
            )
            for r in await cur.fetchall()
        ]

        await cur.execute(
            """
                SELECT payment_id, method::text, status::text, amount, tip_amount, created_at
                  FROM payments
                 WHERE order_id = %s AND order_created_at = %s
                 ORDER BY created_at
                """,
            (order_id, order_created_at),
        )
        payments = [
            PaymentOut(
                payment_id=r[0],
                method=r[1],
                status=r[2],
                amount=r[3],
                tip_amount=r[4],
                created_at=r[5],
            )
            for r in await cur.fetchall()
        ]

    return OrderDetails(
        order_id=head[0],
        order_number=head[1],
        created_at=head[2],
        status=head[3],
        order_type=head[4],
        branch_id=head[5],
        branch_name=head[6],
        table_id=head[7],
        table_number=head[8],
        waiter_name=head[9],
        customer_name=head[10],
        notes=head[11],
        subtotal=head[12],
        tax_amount=head[13],
        service_charge=head[14],
        discount_amount=head[15],
        total_amount=head[16],
        amount_paid=head[17],
        items=items,
        status_history=history,
        payments=payments,
    )


@router.post("/", response_model=OrderCreated, status_code=status.HTTP_201_CREATED)
async def create_order(
    payload: OrderCreateIn,
    current: CurrentUser = Depends(get_current_user),
) -> OrderCreated:
    if current.tenant_id is None:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Tenant-scoped auth required")
    if payload.order_type == "dine_in" and payload.table_id is None:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            "dine_in orders require a table_id",
        )
    if not payload.items:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "items must be non-empty")

    items_json = [item.model_dump(mode="json") for item in payload.items]

    async with tenant_connection(
        tenant_id=current.tenant_id, user_id=current.user_id, role=current.role
    ) as conn, conn.cursor() as cur:
        try:
            await cur.execute(
                """
                    SELECT order_id, order_created_at, total
                      FROM fn_place_order(%s, %s, %s, %s, %s, %s::order_type, %s::jsonb, %s)
                    """,
                (
                    current.tenant_id,
                    payload.branch_id,
                    payload.table_id,
                    current.user_id,
                    payload.customer_id,
                    payload.order_type,
                    Jsonb(items_json),
                    payload.notes,
                ),
            )
            row = await cur.fetchone()
        except pg_errors.CheckViolation as exc:
            raise HTTPException(
                status.HTTP_409_CONFLICT, f"Insufficient stock: {exc}"
            ) from exc
        except pg_errors.NoDataFound as exc:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST, f"Menu item not available: {exc}"
            ) from exc
    if row is None:
        raise HTTPException(status.HTTP_500_INTERNAL_SERVER_ERROR, "fn_place_order returned no row")
    return OrderCreated(order_id=row[0], created_at=row[1], total=row[2])


@router.post("/{order_id}/close", response_model=dict)
async def close_order(
    order_id: UUID,
    payment: ClosePaymentIn,
    current: CurrentUser = Depends(get_current_user),
) -> dict:
    async with tenant_connection(
        tenant_id=current.tenant_id, user_id=current.user_id, role=current.role
    ) as conn, conn.cursor() as cur:
        order_created_at = await _resolve_order_created_at(cur, order_id)
        try:
            await cur.execute(
                "SELECT fn_close_order(%s, %s, %s::payment_method, %s, %s, %s)",
                (
                    order_id,
                    order_created_at,
                    payment.method,
                    payment.amount,
                    payment.tip,
                    current.user_id,
                ),
            )
            row = await cur.fetchone()
        except pg_errors.CheckViolation as exc:
            raise HTTPException(status.HTTP_409_CONFLICT, str(exc)) from exc
    return {"payment_id": row[0] if row else None}


@router.post("/{order_id}/cancel", response_model=dict)
async def cancel_order(
    order_id: UUID,
    body: CancelIn,
    current: CurrentUser = Depends(get_current_user),
) -> dict:
    async with tenant_connection(
        tenant_id=current.tenant_id, user_id=current.user_id, role=current.role
    ) as conn, conn.cursor() as cur:
        order_created_at = await _resolve_order_created_at(cur, order_id)
        try:
            await cur.execute(
                "SELECT fn_cancel_order(%s, %s, %s)",
                (order_id, order_created_at, body.reason),
            )
        except pg_errors.CheckViolation as exc:
            raise HTTPException(status.HTTP_409_CONFLICT, str(exc)) from exc
    return {"status": "cancelled"}
