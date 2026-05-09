"""Shared pytest fixtures.

Стратегия: подключаемся к уже запущенной БД (host/port/user из env).
Для теста создаём одноразовую savepoint-транзакцию и откатываем её на
teardown — тесты не оставляют после себя данных и могут запускаться
в любом порядке.

Для тестов RLS используем несколько подключений с разным
app.current_tenant_id.
"""
from __future__ import annotations

import os
import sys
from collections.abc import Iterator

import psycopg
import pytest

# Ensure test directory is on sys.path for _constants import
sys.path.insert(0, os.path.dirname(__file__))

_password_part = os.environ.get('POSTGRES_PASSWORD') or os.environ.get('PGPASSWORD', '')
DSN = (
    f"host={os.environ.get('POSTGRES_HOST', 'localhost')} "
    f"port={os.environ.get('POSTGRES_PORT', '5433')} "
    f"user={os.environ.get('POSTGRES_USER', 'ros_admin')} "
    + (f"password={_password_part} " if _password_part else "")
    + f"dbname={os.environ.get('POSTGRES_DB', 'restaurant_ordering')}"
)

TENANT_A = "11111111-1111-1111-1111-111111111111"
TENANT_B = "22222222-2222-2222-2222-222222222222"
BRANCH_A = "b1000000-0000-0000-0000-000000000001"
TABLE_A = "b3000000-0000-0000-0000-000000000001"
WAITER_A = "a1000000-0000-0000-0000-000000000002"
PLOV_ID = "e1000000-0000-0000-0000-000000000001"


@pytest.fixture
def conn() -> Iterator[psycopg.Connection]:
    """Connection с автоматическим ROLLBACK в teardown."""
    connection = psycopg.connect(DSN)
    connection.autocommit = False
    try:
        yield connection
    finally:
        connection.rollback()
        connection.close()


@pytest.fixture
def tenant_a_conn() -> Iterator[psycopg.Connection]:
    connection = psycopg.connect(DSN)
    connection.autocommit = False
    with connection.cursor() as cur:
        cur.execute("SELECT set_config('app.current_tenant_id', %s, false)", (TENANT_A,))
    try:
        yield connection
    finally:
        connection.rollback()
        connection.close()


@pytest.fixture
def tenant_b_conn() -> Iterator[psycopg.Connection]:
    connection = psycopg.connect(DSN)
    connection.autocommit = False
    with connection.cursor() as cur:
        cur.execute("SELECT set_config('app.current_tenant_id', %s, false)", (TENANT_B,))
    try:
        yield connection
    finally:
        connection.rollback()
        connection.close()
