from __future__ import annotations

from datetime import UTC, datetime, timedelta
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from jose import JWTError, jwt
from passlib.context import CryptContext
from pydantic import BaseModel

from ..config import get_settings
from ..db import tenant_connection

router = APIRouter()
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/auth/login")


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user_id: UUID
    tenant_id: UUID | None


class CurrentUser(BaseModel):
    user_id: UUID
    tenant_id: UUID | None
    role: str


class MeResponse(BaseModel):
    user_id: UUID
    tenant_id: UUID | None
    tenant_name: str | None = None
    tenant_slug: str | None = None
    role: str
    email: str | None = None
    full_name: str | None = None
    branch_id: UUID | None = None
    branch_name: str | None = None


def _create_token(user_id: UUID, tenant_id: UUID | None, role: str) -> str:
    settings = get_settings()
    expire = datetime.now(UTC) + timedelta(minutes=settings.jwt_expire_minutes)
    payload = {
        "sub": str(user_id),
        "tenant_id": str(tenant_id) if tenant_id else None,
        "role": role,
        "exp": expire,
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


async def get_current_user(token: str = Depends(oauth2_scheme)) -> CurrentUser:
    settings = get_settings()
    try:
        payload = jwt.decode(token, settings.jwt_secret, algorithms=[settings.jwt_algorithm])
    except JWTError as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid token") from exc
    return CurrentUser(
        user_id=UUID(payload["sub"]),
        tenant_id=UUID(payload["tenant_id"]) if payload.get("tenant_id") else None,
        role=payload["role"],
    )


@router.post("/login", response_model=TokenResponse)
async def login(form: OAuth2PasswordRequestForm = Depends()) -> TokenResponse:
    async with tenant_connection() as conn, conn.cursor() as cur:
        await cur.execute(
            """
                SELECT u.user_id, u.password_hash,
                       ur.tenant_id, ur.role::text
                  FROM users u
                  LEFT JOIN user_roles ur ON ur.user_id = u.user_id
                 WHERE u.email = %s
                 ORDER BY ur.granted_at DESC
                 LIMIT 1
                """,
            (form.username,),
        )
        row = await cur.fetchone()
    if row is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid credentials")
    user_id, password_hash, tenant_id, role = row
    if not pwd_context.verify(form.password, password_hash):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid credentials")
    token = _create_token(user_id, tenant_id, role or "customer")
    return TokenResponse(access_token=token, user_id=user_id, tenant_id=tenant_id)


@router.get("/me", response_model=MeResponse)
async def me(current: CurrentUser = Depends(get_current_user)) -> MeResponse:
    from ..db import tenant_connection as _tc

    async with _tc(
        tenant_id=current.tenant_id, user_id=current.user_id, role=current.role
    ) as conn, conn.cursor() as cur:
        await cur.execute(
            """
                SELECT u.email::text,
                       u.full_name,
                       t.name,
                       t.slug,
                       ur.branch_id,
                       b.name AS branch_name
                  FROM users u
             LEFT JOIN user_roles ur ON ur.user_id = u.user_id
                                     AND (ur.tenant_id = %s OR %s IS NULL)
             LEFT JOIN tenants t  ON t.tenant_id = ur.tenant_id
             LEFT JOIN branches b ON b.branch_id = ur.branch_id
                 WHERE u.user_id = %s
              ORDER BY ur.granted_at DESC
                 LIMIT 1
                """,
            (current.tenant_id, current.tenant_id, current.user_id),
        )
        row = await cur.fetchone()
    email = row[0] if row else None
    full_name = row[1] if row else None
    tenant_name = row[2] if row else None
    tenant_slug = row[3] if row else None
    branch_id = row[4] if row else None
    branch_name = row[5] if row else None
    return MeResponse(
        user_id=current.user_id,
        tenant_id=current.tenant_id,
        tenant_name=tenant_name,
        tenant_slug=tenant_slug,
        role=current.role,
        email=email,
        full_name=full_name,
        branch_id=branch_id,
        branch_name=branch_name,
    )
