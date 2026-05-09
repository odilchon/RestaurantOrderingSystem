from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse

from .config import get_settings
from .db import close_pool, init_pool
from .routers import auth, menu, meta, orders, places, reports


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_pool()
    yield
    await close_pool()


app = FastAPI(
    title="Restaurant Ordering System",
    description="Multi-tenant SaaS backend for restaurant chains. "
    "Demonstrates RLS, partitioning, stored procedures, and ACID transactions.",
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=get_settings().cors_origins_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router, prefix="/auth", tags=["auth"])
app.include_router(menu.router, prefix="/menu", tags=["menu"])
app.include_router(orders.router, prefix="/orders", tags=["orders"])
app.include_router(reports.router, prefix="/reports", tags=["reports"])
app.include_router(places.router, prefix="/places", tags=["places"])
app.include_router(meta.router, prefix="/meta", tags=["meta"])


@app.get("/", include_in_schema=False)
async def root() -> RedirectResponse:
    return RedirectResponse(url="/docs", status_code=307)


@app.get("/health", tags=["meta"])
async def health() -> dict[str, str]:
    return {"status": "ok"}
