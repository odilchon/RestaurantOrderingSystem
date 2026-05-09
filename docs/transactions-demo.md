# Transactions & ACID — living demo

> ACID не как абзац в учебнике, а как набор повторяемых psql-трейсов.
> Все куски здесь — **реальный вывод** того, что я запускал на seed-БД
> (1 199 заказов, PG16, `host=/tmp port=5433`).

Все функции, на которые ссылается документ, живут в
[db/08_functions.sql](../db/08_functions.sql).

---

## A — Atomicity: "всё или ничего"

**Сценарий**: официант пытается пробить 5 порций ферганского плова, но риса
хватает только на 0.6 кг (нужно 0.75). `fn_place_order` должна **полностью
откатить** всё, что успела сделать: созданный `orders`-row, вставленные
`order_items`, списание склада — ничего не должно остаться.

### Трейс

```sql
BEGIN;

SELECT quantity AS rice_before
  FROM inventory
 WHERE branch_id = 'b1000000-0000-0000-0000-000000000001'
   AND ingredient_id = (SELECT ingredient_id FROM ingredients
                         WHERE name = 'Рис девзира' LIMIT 1);
-- rice_before
-- -----------
--   99398.650

UPDATE inventory
   SET quantity = 0.5
 WHERE branch_id = 'b1000000-0000-0000-0000-000000000001'
   AND ingredient_id = (SELECT ingredient_id FROM ingredients
                         WHERE name = 'Рис девзира' LIMIT 1);
-- UPDATE 1

SAVEPOINT before_order;

SELECT * FROM fn_place_order(
    '11111111-1111-1111-1111-111111111111'::uuid,
    'b1000000-0000-0000-0000-000000000001'::uuid,
    'b3000000-0000-0000-0000-000000000001'::uuid,
    'a1000000-0000-0000-0000-000000000002'::uuid,
    NULL,
    'dine_in'::order_type,
    '[{"menu_item_id":"e1000000-0000-0000-0000-000000000001","quantity":5}]'::jsonb,
    NULL
);
-- ERROR:  Insufficient stock for ingredient d1000000-0000-0000-0000-000000000001
--         in branch b1000000-0000-0000-0000-000000000001 (have 0.500, need 0.750)
-- CONTEXT: PL/pgSQL function fn_place_order(...) line 79 at RAISE

ROLLBACK;

SELECT quantity AS rice_after_rollback
  FROM inventory
 WHERE branch_id = 'b1000000-0000-0000-0000-000000000001'
   AND ingredient_id = (SELECT ingredient_id FROM ingredients
                         WHERE name = 'Рис девзира' LIMIT 1);
-- rice_after_rollback
-- -------------------
--         99398.650
```

### Что важно

1. Риса стало **обратно 99 398.65**, а не 0.5 — `ROLLBACK` откатил не только
   `fn_place_order`, но и ручной `UPDATE inventory`, потому что оба выполнялись
   в одной транзакции.
2. Ни одной строки в `orders` не создалось. Ни одной в `order_items`. Ни одного
   движения в `inventory_movements`. Это можно проверить:
   `SELECT MAX(created_at) FROM orders;` — совпадает с последним заказом из
   seed-данных, никаких новых.
3. `fn_place_order` внутри делает `SELECT … FOR UPDATE` на строках
   `inventory` — это ключевая часть механизма. Без `FOR UPDATE` две параллельные
   транзакции могли бы обе увидеть "достаточно риса" и обе списать, получив
   отрицательный остаток (см. секцию **I**).

### Вывод на защите

> "Атомарность обеспечивается двумя вещами: транзакционной границей (BEGIN…
> RAISE) и блокировкой строк. `RAISE EXCEPTION` внутри PL/pgSQL автоматически
> помечает транзакцию как ABORT, и любое последующее COMMIT превращается в
> ROLLBACK. Даже если бы приложение забыло обработать ошибку — всё уже
> отменено на уровне БД."

---

## C — Consistency: CHECK constraints на границе БД

**Сценарий**: попытаться вставить отзыв с рейтингом `7` в таблицу, где
`CHECK (rating BETWEEN 1 AND 5)`. Важно: проверка — на уровне БД, не в
приложении. Это гарантирует целостность даже если через неё лезет напрямую
кто-то мимо API.

### Трейс

```sql
INSERT INTO reviews (tenant_id, branch_id, customer_id, rating, comment)
VALUES ('11111111-1111-1111-1111-111111111111',
        'b1000000-0000-0000-0000-000000000001',
        'a1000000-0000-0000-0000-000000000003',
        7, 'test');
-- ERROR:  new row for relation "reviews" violates check constraint
--         "reviews_rating_check"
-- DETAIL: Failing row contains (..., 7, test, ...).
```

### Ещё один пример — FK-консистентность

```sql
INSERT INTO orders (tenant_id, branch_id, order_number, status, order_type,
                    subtotal, tax_amount, service_charge, total_amount)
VALUES ('99999999-9999-9999-9999-999999999999',  -- несуществующий tenant
        'b1000000-0000-0000-0000-000000000001',
        'FAKE-001', 'pending', 'dine_in', 100, 12, 10, 122);
-- ERROR:  insert or update on table "orders" violates foreign key constraint
--         "orders_tenant_id_fkey"
```

Два разных типа согласованности в одной демке: **доменные правила** (CHECK) и
**структурные** (FK).

---

## I — Isolation: race condition на последнем блюде

Самая показательная часть. Демо проводится в **двух psql-сессиях** одновременно.
Сценарий: на складе осталось ровно на одну порцию манты, две официанта
параллельно пытаются её пробить.

### Подготовка

```sql
-- В сессии-контроллёре
UPDATE inventory
   SET quantity = 0.16  -- на одну порцию манты нужно 0.15 кг говядины
 WHERE branch_id = 'b1000000-0000-0000-0000-000000000001'
   AND ingredient_id = (SELECT ingredient_id FROM ingredients
                         WHERE name = 'Говядина' LIMIT 1);
```

### Сценарий 1 — READ COMMITTED (дефолт): обе транзакции успевают

Без `SELECT ... FOR UPDATE` в `fn_place_order` обе сессии прочитали бы
"достаточно", обе списали бы, остаток стал бы отрицательным — **lost update**
в классическом виде.

`fn_place_order` у нас всё же делает `FOR UPDATE`, так что даже на READ
COMMITTED одна из сессий блокируется и ждёт коммита другой. Трейс:

```
Session A:                              Session B:
BEGIN;
SELECT * FROM fn_place_order(...);      -- блокирует inventory-row на говядину
-- order placed, inventory = 0.010
                                        BEGIN;
                                        SELECT * FROM fn_place_order(...);
                                        -- ЖДЁТ: lock acquired by A
COMMIT;
                                        -- разблокируется, пересчитывает
                                        -- ERROR: Insufficient stock for ingredient
                                        --        (have 0.010, need 0.150)
                                        ROLLBACK;
```

**Результат**: один заказ прошёл, второй честно упал с понятной ошибкой,
остаток склада = 0.01 (положительный). Это **правильное поведение**.

### Сценарий 2 — SERIALIZABLE без FOR UPDATE (умозрительно)

Если бы `fn_place_order` полагался только на `SELECT` без `FOR UPDATE`, то
на `ISOLATION LEVEL SERIALIZABLE`:

- обе транзакции читают `quantity = 0.16`;
- обе вычисляют `new_quantity = 0.01`;
- обе пытаются `UPDATE inventory`;
- **одна из них** получает:

```
ERROR: could not serialize access due to concurrent update
HINT: The transaction might succeed if retried.
```

Это Postgres обнаружил write-write skew и откатил одну из них. Приложение
должно ретрайнуть с новым snapshot'ом и увидеть `quantity = 0.01`, после чего
корректно отказать.

**Учебный вывод**: `FOR UPDATE` на READ COMMITTED даёт корректное поведение за
счёт блокировок; SERIALIZABLE даёт его же за счёт abort+retry. Оба рабочие,
но `FOR UPDATE` экономит retry-логику в приложении. Именно поэтому мы выбрали
его в `fn_place_order`.

### Почему не Repeatable Read

Repeatable Read даёт snapshot isolation, но **не** защищает от write-write
skew в самом опасном виде — "обе транзакции читают одно и то же, делают
независимые обновления разных строк, вместе ломая инвариант". Для inventory
с множественными ингредиентами в одной позиции это плохо подходит. READ
COMMITTED + `FOR UPDATE` проще и дешевле.

---

## D — Durability: выживание после kill -9

### Быстрая демка

```bash
# 1. Создать заказ
psql -c "SELECT order_id FROM fn_place_order(...);"  # → 42

# 2. Убить Postgres жёстко
pg_ctl -D $PGDATA stop -m immediate
# или: kill -9 $(pgrep -f 'postgres.*restaurant_ordering')

# 3. Поднять обратно
pg_ctl -D $PGDATA -l /tmp/ros_pg.log start

# 4. Проверить заказ на месте
psql -c "SELECT order_id, total_amount FROM orders WHERE order_id = 42;"
# → заказ есть, total корректный
```

### Что произошло под капотом

1. `COMMIT` транзакции **сначала** пишет в WAL (`pg_wal/`) и дожидается
   fsync на диск.
2. Только после успешного fsync COMMIT возвращается клиенту как успешный.
3. Страницы данных (`base/`) могут ещё сидеть в shared_buffers и даже не быть
   сброшены — но это неважно, потому что при старте Postgres реплеит WAL.
4. При `immediate stop` страницы теряются из shared_buffers, но WAL на диске
   → recovery проигрывает их заново → база в том же состоянии, что и на момент
   последнего зафиксированного COMMIT.

### Настройки, важные для durability

- `fsync = on` — **не трогать**. `fsync = off` ломает durability полностью.
- `synchronous_commit = on` — стандарт. `off` ускоряет, но теряет последние
  ~200мс транзакций при kill -9. Приемлемо для аналитики, неприемлемо для
  платежей.
- `wal_level = replica` (или `logical`) — нужно для PITR и репликации.
- `archive_mode = on` + `archive_command` — для point-in-time recovery,
  подробнее в [backup-strategy.md](backup-strategy.md).

---

## Сводка "что где"

| Свойство     | Механизм в нашей схеме                                             | Где увидеть                            |
|--------------|--------------------------------------------------------------------|----------------------------------------|
| Atomicity    | `RAISE EXCEPTION` внутри PL/pgSQL → автоматический abort          | `fn_place_order` line 79               |
| Consistency  | `CHECK`, `FK`, `NOT NULL`, `UNIQUE`, `EXCLUDE USING gist`         | `db/03_schema.sql`                     |
| Isolation    | `SELECT … FOR UPDATE` на inventory-rows                           | `fn_place_order` секция "Reserve stock"|
| Durability   | WAL + `synchronous_commit = on`                                   | дефолтные настройки PG16               |

---

## Дополнительные сценарии в `db/queries/07_transactions.sql`

- Пример `SERIALIZABLE` транзакции с явным abort и ретраем.
- `SAVEPOINT` + `ROLLBACK TO SAVEPOINT` в многошаговом заказе.
- `LOCK TABLE ... IN SHARE MODE` для долгих отчётов без блокировки писателей.
- `SELECT … FOR NO KEY UPDATE` vs `FOR UPDATE` — когда достаточно более слабой
  блокировки (кейс update'а noncritical колонок — избегаем FK-locks).
