# Security — multi-tenant isolation & least privilege

> Как Restaurant Ordering System обеспечивает, что один tenant не видит
> данные другого — **даже если** приложение напишут с багом или API-ключ
> утечёт.

Три уровня защиты, уложенные друг на друга:

1. **Database roles** — физические роли PostgreSQL с гранулярными правами.
2. **Row-Level Security** — политики `USING`/`WITH CHECK` на 18 tenant-scoped
   таблицах.
3. **Session variable** `app.current_tenant_id` — выставляется приложением на
   каждое соединение, RLS сравнивает с ней.

---

## 1. Database roles — least privilege

[db/11_roles_grants.sql](../db/11_roles_grants.sql)

Четыре роли с наследованием:

```
app_readonly  ──┐
                ├──▶  app_waiter  ──┐
                │                   ├──▶  app_manager  ──▶  app_admin
                │                   │
                └───────────────────┘
```

| Роль            | `SELECT` | `INSERT/UPDATE` | Особое                              |
|-----------------|----------|------------------|-------------------------------------|
| `app_readonly`  | всё        | —                | аналитика, BI                       |
| `app_waiter`    | всё        | `orders`, `order_items`, `payments`, `reservations` | вызывать `fn_place_order` |
| `app_manager`   | всё        | + меню, инвентарь, closures | `REFRESH MATERIALIZED VIEW` |
| `app_admin`     | всё        | всё              | **`BYPASSRLS`** — для миграций и бэкапов |

Ключевой момент: **только `app_admin` имеет `BYPASSRLS`**. Все остальные
роли обязаны предоставить `app.current_tenant_id`, иначе RLS их не пустит.

### Как это проверить

```sql
SET ROLE app_waiter;
SELECT * FROM orders LIMIT 1;
-- rows: 0   (RLS не пустил, потому что app.current_tenant_id не задан)

SELECT set_config('app.current_tenant_id',
                  '11111111-1111-1111-1111-111111111111', true);
SELECT * FROM orders LIMIT 1;
-- rows: 1   (тенант 1 видит свои заказы)

SELECT set_config('app.current_tenant_id',
                  '22222222-2222-2222-2222-222222222222', true);
SELECT * FROM orders LIMIT 1;
-- rows: 0   (тенант 2 — если там нет своих заказов — не видит чужие)
```

---

## 2. Row-Level Security — в "последний барьер"

[db/10_rls_policies.sql](../db/10_rls_policies.sql)

Все таблицы с `tenant_id` имеют `ENABLE ROW LEVEL SECURITY` + `FORCE ROW
LEVEL SECURITY` (чтобы даже владелец таблицы не мог обойти).

### Две формы политик

**Прямая** — для таблиц с `tenant_id` колонкой:

```sql
CREATE POLICY p_tenants ON tenants
    USING (tenant_id = app_current_tenant_id());
```

**Через EXISTS** — для дочерних таблиц, у которых `tenant_id` достаётся
через родителя:

```sql
CREATE POLICY p_order_items ON order_items
    USING (EXISTS (
        SELECT 1 FROM orders o
         WHERE o.order_id = order_items.order_id
           AND o.created_at = order_items.order_created_at
           AND o.tenant_id = app_current_tenant_id()
    ));
```

Это чуть медленнее (доп. subquery), но не требует дублировать `tenant_id`
в каждую дочернюю таблицу, сохраняя нормализацию.

### Почему **не просто** WHERE в приложении

```python
# Плохой вариант — всё держится на том, что разработчик не забудет:
cur.execute("SELECT * FROM orders WHERE tenant_id = %s", (current_tenant,))
```

Одна строчка без `WHERE tenant_id` — и утечка. Code review может пропустить.
Линтер не поймает. RLS **физически** не даст запрос без tenant-фильтра
вернуть чужие строки. Это defense-in-depth.

### Как backend выставляет переменную

[backend/app/db.py](../backend/app/db.py) — `tenant_connection` context
manager:

```python
async with tenant_connection(tenant_id=current.tenant_id,
                              user_id=current.user_id) as conn:
    # SET LOCAL app.current_tenant_id = '...'
    # SET LOCAL app.current_user_id = '...'
    ...  # все запросы внутри видят только свой тенант
```

`SET LOCAL` привязывает переменную к транзакции, не к соединению — так что
при возврате соединения в pool она сбрасывается.

---

## 3. Defense-in-depth — что ещё мешает утечке

### Пароли

- `bcrypt` через `passlib`, cost=12 (~250 мс на hash — защита от brute force).
- **Никогда** не хранятся в plain. Приложение работает с `password_hash`.
- В `seed_faker.py` все пользователи получают **одинаковый** фиктивный
  bcrypt-хэш (`$2b$12$dummyhash…`) — нормальным bcrypt никогда не провалидирует,
  что правильно для seed.

### JWT

- `python-jose` HS256 с секретом из env.
- Payload: `sub` (user_id), `tenant_id`, `role`, `exp`.
- Срок жизни — 60 минут из [backend/app/config.py](../backend/app/config.py).
- Revocation — через отдельную таблицу `sessions` с `expires_at` и
  `revoked_at`. Логика "logout" ставит `revoked_at = NOW()`.

### Audit log

[db/09_triggers.sql](../db/09_triggers.sql) `fn_audit_row_change` — один
generic триггер на 13 критичных таблиц. Логирует:

- `table_name`, `row_pk`, `operation` (I/U/D);
- `old_data`, `new_data` (JSONB, из `row_to_json(OLD)/(NEW)`);
- `changed_by` = `current_setting('app.current_user_id', true)`;
- `changed_at = NOW()`.

На защите: "удалите какую-нибудь строку из `menu_items`, потом откройте
`audit_log` — увидите кто, когда, что".

Сам `audit_log` read-only для всех кроме `app_admin` — `GRANT SELECT` для
остальных. Это важно: злоумышленник, получивший роль `app_waiter`, не должен
мочь "заметать следы".

### SQL injection

- psycopg параметры (`%s`, `%(name)s`) экранируются на уровне драйвера,
  никаких f-strings с данными в SQL.
- FastAPI валидирует типы через Pydantic → UUID, Decimal, enum —
  принудительная типизация до того, как значение доходит до SQL.

### Extensions

- `pgcrypto` подключен для `gen_random_uuid()` — все ID генерятся как UUIDv4,
  не sequential. Это делает нереальной атаку "я видел `order_id=42`, давайте
  попробую `order_id=43`".

---

## Чего мы осознанно **не** делаем

- **Шифрование данных в покое** (`pg_crypto` для колоночного шифрования).
  Оверхед не оправдан для учебной БД, и ключи пришлось бы где-то хранить.
  Вместо этого полагаемся на disk encryption на уровне ОС.
- **Column-level privileges** (`GRANT SELECT (col1, col2)`). Сложно
  поддерживать при эволюции схемы, и RLS покрывает main use case.
- **Audit log immutability via hash chains**. Переусложнение для учебника.
- **IP allowlist / pg_hba.conf enforced rules** — для docker compose
  оставлено `trust` локально; в реальной проде — `md5`/`scram-sha-256`.

---

## Чеклист для ревью на защите

- [ ] `SELECT rolname, rolbypassrls FROM pg_roles WHERE rolname LIKE 'app_%';`
      → только `app_admin` имеет `rolbypassrls = true`.
- [ ] `SELECT tablename, rowsecurity, forcerowsecurity FROM pg_tables
      WHERE schemaname='public';` → 18 tenant-scoped таблиц с обеими `t`.
- [ ] Демо: `SET ROLE app_waiter;` без `app.current_tenant_id` → пустая
      выборка из `orders`.
- [ ] Демо: `set_config('app.current_tenant_id', 'wrong-uuid', true);` →
      пустая выборка (вместо чужих данных).
- [ ] `SELECT * FROM audit_log ORDER BY changed_at DESC LIMIT 5;` — видно
      последние изменения с `changed_by`.
