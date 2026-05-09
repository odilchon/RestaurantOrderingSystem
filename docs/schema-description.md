# Schema description

Полный перечень таблиц с их ролью в доменной модели. Исходник DDL —
[db/03_schema.sql](../db/03_schema.sql); ER-диаграмма —
[docs/erd.png](erd.png). Здесь только **смысл** каждой таблицы, бизнес-правила
и нетривиальные решения.

**Всего 31 таблица в базовой схеме** (+ 15 partitions для `orders`):

```
Tenancy & auth .............. 4 tables
Restaurant structure ........ 3 tables
Menu & recipes .............. 5 tables
Inventory & procurement ..... 5 tables
Orders, items & payments .... 5 tables
Customer experience ......... 5 tables
Operations & audit .......... 4 tables
```

---

## Tenancy & auth (4)

### `tenants`
SaaS-клиенты — ресторанные бренды. PK — `tenant_id UUID`. Содержит
`slug CITEXT UNIQUE` (для URL-friendly идентификаторов) и `settings JSONB`
для гибких настроек (валюта, tax rate, formatting).

**Особенности**: `settings JSONB` + GIN индекс → гибкие фичевые флаги без
миграций.

### `users`
Все пользователи системы: админы, менеджеры, официанты, клиенты. Почему
одна таблица? Потому что один человек может быть одновременно клиентом в
одном ресторане и менеджером в другом — семантически это один пользователь.

Ключевые поля: `email CITEXT UNIQUE`, `phone`, `password_hash`, `full_name`,
`locale` (ru/en/ky). Пароли — bcrypt, см. [security.md](security.md).

### `user_roles`
M:N связка users ↔ tenants ↔ branches ↔ role. Это **не** обычная связь
user↔role; это "user X имеет роль Y в тенанте Z, филиал может быть любой или
конкретный". Именно поэтому `tenant_id` и `branch_id` здесь nullable —
customer не принадлежит тенанту, super_admin может иметь глобальную роль.

Пример бизнес-смысла: "Омуров Айбек — waiter в branch 1, manager в branch 2,
customer в tenant 3". Три строки в `user_roles`, одна в `users`.

### `sessions`
Активные JWT-сессии для revocation. Содержит `expires_at`, `revoked_at`,
`ip_address`, `user_agent`. Partial index `WHERE revoked_at IS NULL` — для
быстрой очистки истёкших.

---

## Restaurant structure (3)

### `branches`
Физические филиалы. Содержит geo-координаты (lat, lng — для "ближайший
ресторан") и `operating_hours JSONB` — часы работы по дням недели с
возможностью задать исключения на праздники.

### `zones`
Секции внутри филиала: "терраса", "VIP зал", "бар-стойка". Нужны для
hostess-интерфейса и разной capacity/pricing.

### `restaurant_tables`
Физические столы. Называется именно `restaurant_tables` потому что `table` —
reserved word в SQL, а `tables` перекрывается с system view. `(branch_id,
table_number) UNIQUE` с `NULLS NOT DISTINCT` — PG15+ feature, которая
корректно отрабатывает случай "стол без номера" (для outdoor-мероприятий).

---

## Menu & recipes (5)

### `categories`
Иерархические категории меню с self-referencing `parent_id`. Позволяет
"Горячие блюда → Плов → Ферганский плов". Запрос "все блюда в поддереве" —
через `WITH RECURSIVE` (см. [db/queries/05_cte_window.sql](../db/queries/05_cte_window.sql)).

### `menu_items`
Собственно блюда. Содержит:
- `base_price` — fallback, если нет записи в `menu_item_prices`;
- `is_active` — soft delete (деактивируем, не удаляем — иначе ломаются старые
  заказы);
- `search_vector tsvector` — full-text search, обновляется триггером на
  INSERT/UPDATE;
- `photo_url`, `preparation_minutes`, `calories`.

### `menu_item_prices`
**Историческая таблица цен.** `(menu_item_id, valid_from, valid_to)`. Текущая
цена — та, у которой `valid_to IS NULL`. Старые заказы можно "пересчитать" на
цены того дня, когда они были созданы — нужно для аудита и споров с
клиентами.

### `menu_item_translations`
Локализация name/description (ru/en/ky). Отдельная таблица, а не массив в
`menu_items` — чтобы можно было делать FTS отдельно по языкам и не тащить
пустые колонки.

### `menu_item_ingredients`
Рецептура: blyudo ↔ ingredient с `quantity`. Именно через эту таблицу
`fn_place_order` знает, сколько риса списать при продаже плова.

### `menu_item_branch_availability`
Какое блюдо доступно в каком филиале. В Бишкеке есть плов, в филиале на
Иссык-Куле — нет (не завозят рис девзира). FK `(menu_item_id, branch_id)`,
флаг `is_available`.

---

## Inventory & procurement (5)

### `ingredients`
Каталог ингредиентов: `name`, `unit` (кг/л/шт), `reorder_level`,
`allergens TEXT[]` (с GIN индексом — для фильтра "без глютена"/"без орехов").

### `inventory`
**Текущие остатки**. PK `(branch_id, ingredient_id)`. `quantity NUMERIC(14,3)`.
Обновляется только через `fn_place_order` / `fn_cancel_order` /
`fn_receive_purchase_order` — никогда напрямую, иначе ломается аудит.

### `inventory_movements`
**Event-source движений склада.** Каждое списание / приход / корректировка
— отдельная строка. `reference_type` + `reference_id` — ссылка на исходник
(`order`, `purchase_order`, `manual_adjustment`). Это append-only, триггер
запрещает UPDATE и DELETE.

При защите: "если посмотреть на `inventory.quantity = SUM(inventory_movements.delta)`
по каждой паре (branch, ingredient) — должно быть равенство. Это и есть
проверка на integrity event-sourcing модели".

### `suppliers`
Поставщики ингредиентов. Контакт, условия оплаты.

### `purchase_orders` + `purchase_order_items`
Закупки. Статусная машина `draft → submitted → approved → received →
cancelled`. При `received` триггер (или функция) создаёт движения в
`inventory_movements` с `delta > 0`.

---

## Orders, items & payments (5)

### `orders` ⚠️ **partitioned**
Центральная таблица. PK — `(order_id, created_at)` композитный, потому что
партиционирование по `created_at` требует включения колонки в PK.
Партиции создаются через `ensure_orders_partition(date)` —
[db/04_partitions.sql](../db/04_partitions.sql).

Колонки: `tenant_id`, `branch_id`, `table_id`, `waiter_id`, `customer_id`,
`order_type ENUM`, `status ENUM`, `order_number` (human-friendly формат
`YYYYMMDD-HEX`), `subtotal`, `tax_amount`, `service_charge`,
`discount_amount`, `total_amount`, `notes`, `created_at`, `updated_at`.

**Кэшированные агрегаты**: `subtotal` и `total_amount` теоретически можно
вычислить из `order_items`, но для скорости (и для фискального чека)
держим денормализованно. Консистентность поддерживает `fn_place_order`.

### `order_items`
Позиции. PK — `(order_id, order_created_at, line_no)`. Колонки-снапшоты:
`name_snapshot`, `unit_price_snapshot`, `line_total` — чтобы переименование
блюда не ломало старые чеки. Это осознанная денормализация, см.
[normalization.md](normalization.md#денормализация-которую-мы-сознательно-оставили).

### `order_status_history`
Вся цепочка смен статуса с временем и `changed_by`. Триггер
`fn_order_status_history` пишет сюда автоматически при любом `UPDATE
orders SET status = …`.

### `payments`
Оплаты. `method ENUM (cash, card, elsom, mbank, other)`, `amount`, `tip`,
`external_transaction_id` (ссылка на банковскую транзакцию), `status`
(`captured`, `authorized`, `failed`).

### `refunds`
Возвраты. FK на `payments`. `amount`, `reason`, `approved_by`.

---

## Customer experience (5)

### `reservations` ⚠️ **EXCLUDE constraint**
Бронирования столов. Ключевая фича —

```sql
CONSTRAINT reservations_no_overlap
    EXCLUDE USING gist (
        table_id WITH =,
        reserved_period WITH &&
    )
    WHERE (status IN ('pending', 'confirmed', 'seated'))
```

Это делает **физически невозможным** забронировать один стол на пересекающиеся
временные интервалы. Проверка на уровне БД, не в приложении. Использует
`btree_gist` extension.

### `loyalty_accounts`
Программа лояльности клиента: `points_balance`, `tier ENUM (bronze/silver/
gold/platinum)`. Один к одному с `users.user_id`.

### `loyalty_transactions`
Движение баллов: `earn`/`redeem`/`expire`/`adjustment`. Привязано к
`order_id` когда применимо.

### `reviews`
Отзывы: `rating 1–5 CHECK`, `comment`, `branch_id`, `order_id` optional.

### (customer_id есть в `orders`)
Не отдельная таблица `customers` — любой user с ролью `customer` уже клиент.

---

## Operations & audit (4)

### `shifts`
Смены персонала: `user_id`, `branch_id`, `clock_in`, `clock_out`,
`break_minutes`. Partial index `WHERE clock_out IS NULL` — "кто сейчас на
смене".

### `audit_log` ⚠️ **generic**
Универсальный лог изменений. Одна таблица для всех. Колонки: `table_name`,
`row_pk JSONB`, `operation CHAR(1)`, `old_data JSONB`, `new_data JSONB`,
`changed_by`, `changed_at`. Заполняется одним триггером `fn_audit_row_change`,
который прикреплён к 13 критичным таблицам через `TG_TABLE_NAME` и
`row_to_json(OLD/NEW)`.

BRIN индекс на `changed_at` — см. [indexing-report.md](indexing-report.md#q5--brin-на-append-only-audit_log).

### `notifications`
Очередь уведомлений клиентам и персоналу. `channel ENUM (email/sms/push/
in_app)`, `payload JSONB`, `read_at`, `sent_at`. Partial index на
`read_at IS NULL` — "непрочитанные".

### (`sessions` — см. Tenancy)

---

## ENUM types

Все перечислены в [db/02_enums.sql](../db/02_enums.sql):

| ENUM               | Значения                                                             |
|--------------------|----------------------------------------------------------------------|
| `order_status`     | draft, pending, confirmed, preparing, ready, served, completed, cancelled |
| `order_type`       | dine_in, takeaway, delivery                                          |
| `payment_method`   | cash, card, elsom, mbank, other                                      |
| `payment_status`   | authorized, captured, failed, refunded, void                         |
| `user_role_enum`   | super_admin, tenant_owner, manager, waiter, chef, cashier, customer  |
| `table_status`     | available, occupied, reserved, cleaning, out_of_service              |
| `reservation_status`| pending, confirmed, seated, completed, cancelled, no_show           |
| `loyalty_tier`     | bronze, silver, gold, platinum                                       |
| `loyalty_txn_type` | earn, redeem, expire, adjustment                                     |
| `purchase_status`  | draft, submitted, approved, received, cancelled                      |
| `inv_movement_type`| purchase, consume, waste, adjustment, return                         |
| `notification_channel`| email, sms, push, in_app                                          |

Почему ENUM, а не lookup-таблицы: эти значения **стабильны** (меняются вместе
с кодом приложения), а не пользовательские (статус можно добавить только
миграцией). Trade-off: ENUM сложнее менять, но быстрее фильтровать и
валидировать.

---

## Checklist "покрытие курса"

| Требование Syllabus                 | Где в схеме                              |
|-------------------------------------|------------------------------------------|
| PK, FK, UNIQUE                      | каждая таблица                           |
| CHECK constraints                   | `reviews.rating`, `orders.amounts`, ...  |
| 1:1, 1:N, N:M                       | users↔loyalty_accounts, branches↔tables, menu_items↔ingredients |
| ENUM types                          | 12 штук                                  |
| JSONB                               | `tenants.settings`, `branches.operating_hours`, `audit_log.*_data` |
| Arrays                              | `ingredients.allergens`                  |
| Self-reference                      | `categories.parent_id`                   |
| Composite PK                        | `(order_id, created_at)`, `user_roles`, `menu_item_ingredients` |
| Partitioning                        | `orders` RANGE monthly                   |
| Full-text search                    | `menu_items.search_vector`               |
| Exclusion constraint                | `reservations_no_overlap`                |
| Views                               | 5 штук в `06_views.sql`                  |
| Materialized views                  | 3 штуки в `07_materialized_views.sql`    |
| Stored procedures                   | 6 штук в `08_functions.sql`              |
| Triggers                            | 5 штук в `09_triggers.sql`               |
| Row-level security                  | 18 таблиц в `10_rls_policies.sql`        |
| Roles & permissions                 | 4 роли в `11_roles_grants.sql`           |
| Indexes: B-tree/partial/expression/GIN/GiST/BRIN | все типы — см. `05_indexes.sql` |
| Transactions & ACID                 | `fn_place_order` + [transactions-demo.md](transactions-demo.md) |
| Backup & restore                    | `db/backup/*`                            |
