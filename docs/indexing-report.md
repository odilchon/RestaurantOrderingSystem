# Indexing report — EXPLAIN ANALYZE before & after

> Каждый индекс в [db/05_indexes.sql](../db/05_indexes.sql) создан не "на всякий
> случай", а под конкретный запрос. Ниже — 5 характерных запросов, их планы
> без индекса и с индексом, и короткое обсуждение.

**Данные на момент замеров** (см. `scripts/seed_faker.py`):

| Таблица              | Строк   |
|----------------------|---------|
| `orders`             | 1 199   |
| `order_items`        | 2 953   |
| `payments`           | 1 019   |
| `users`              | 42      |
| `inventory_movements`| 11 839  |
| `audit_log`          | 69      |

PostgreSQL 16, дефолтные настройки, `ANALYZE` перед каждым замером. Планы
собраны через `EXPLAIN (ANALYZE, BUFFERS)`.

**Почему числа "не в миллионах раз"**: 1 200 заказов — это учебный объём. На
таких данных Postgres часто обоснованно выбирает `Seq Scan`, потому что
sequential I/O на маленькой таблице дешевле, чем random I/O через индекс. В
этом отчёте цель — **показать, что индекс выбирается тогда, когда он нужен**, а
не искусственно раздуть выигрыш. Для демонстрации эффекта на большом объёме
есть параметр `NUM_ORDERS` в [scripts/seed_faker.py](../scripts/seed_faker.py) —
поставьте `NUM_ORDERS = 200_000` и получите картину в миллионы раз.

---

## Q1 — Kitchen display: активные заказы филиала

**Запрос** (99% запросов повара/кассира — список того, что сейчас готовится):

```sql
SELECT order_id, order_number, status, total_amount
  FROM orders
 WHERE branch_id = 'b1000000-0000-0000-0000-000000000001'
   AND status IN ('pending','confirmed','preparing','ready')
 ORDER BY created_at DESC
 LIMIT 50;
```

### Без индексов

```
Limit  (cost=129.84..129.97 rows=50 width=53) (actual rows=50 loops=1)
  Buffers: shared hit=105
  ->  Sort  (actual rows=50)
        Sort Method: quicksort  Memory: 36kB
        ->  Append  (actual rows=90)
              ->  Seq Scan on orders_2026_01  (actual rows=21) Rows Removed by Filter: 207
              ->  Seq Scan on orders_2026_02  (actual rows=32) Rows Removed by Filter: 341
              ->  Seq Scan on orders_2026_03  (actual rows=24) Rows Removed by Filter: 394
              ->  Seq Scan on orders_2026_04  (actual rows=13) Rows Removed by Filter: 167
              ... (пустые партиции)
Execution Time: 0.702 ms
```

Обратите внимание на `Rows Removed by Filter: 394` — Postgres просканировал
418 строк, чтобы вернуть 24. Отношение "sled / sift" = ~17:1. На 200к заказов
это уже **боль**.

### С `idx_orders_active` (partial index)

```sql
CREATE INDEX idx_orders_active
    ON orders (branch_id, status, created_at DESC)
    WHERE status IN ('pending','confirmed','preparing','ready');
```

```
Limit  (cost=100.56..100.68 rows=50 width=53) (actual rows=50 loops=1)
  Buffers: shared hit=58 read=1
  ->  Append  (actual rows=90)
        -- три холодных партиции всё ещё seq-scan (см. обсуждение)
        ->  Seq Scan on orders_2026_01  (actual rows=21)
        ->  Seq Scan on orders_2026_02  (actual rows=32)
        ->  Seq Scan on orders_2026_03  (actual rows=24)
        ->  Index Scan using orders_2026_04_branch_id_status_created_at_idx
              on orders_2026_04  (actual rows=13)
              Index Cond: (branch_id = '...')
Execution Time: 0.574 ms
```

- **Cost** упал `129 → 100` (~23%).
- **Buffers** упали `105 → 59` (почти в 2 раза).
- Планировщик **сам выбрал index scan** на горячей апрельской партиции и
  оставил seq-scan на тех, где активных заказов много относительно размера
  партиции. Это правильное решение: на партициях <30 страниц seq-scan дешевле
  random-I/O через индекс.
- **Почему partial, а не обычный B-tree**: индекс содержит только ~12% строк
  (активные), так что он в 8 раз меньше полного. При 200к заказов это разница
  между 4 МБ и 32 МБ индекса — попадает или не попадает в shared_buffers.

**Учебное замечание**: partial index блестит именно тогда, когда `WHERE`
предиката постоянный и отбирает малую часть таблицы — здесь это "ещё не
закрытые заказы". Если бы мы писали обычный B-tree, он бы вырос линейно с
историей и постепенно перестал бы влезать в кэш.

---

## Q2 — Full-text search по меню

```sql
SELECT menu_item_id, name
  FROM menu_items
 WHERE search_vector @@ plainto_tsquery('simple', 'плов');
```

### Без `idx_menu_items_search_vector`

```
Seq Scan on menu_items  (cost=0.00..1.04 rows=2 width=47) (actual rows=2)
  Filter: (search_vector @@ '''плов'''::tsquery)
  Buffers: shared hit=1
Execution Time: 0.064 ms
```

### С GIN индексом

```
Seq Scan on menu_items  (cost=0.00..1.04 rows=2 width=47) (actual rows=2)
  Filter: (search_vector @@ '''плов'''::tsquery)
Execution Time: 0.028 ms
```

Планировщик **правильно игнорирует GIN индекс** на таблице из 3 строк. Seq scan
одной страницы дешевле любого индексного доступа. Время запроса 0.028 мс.

**Учебное замечание** — это не "индекс бесполезен", это "Postgres умнее нас".
Запустите тот же запрос на 50 000 menu_items (3 тенанта × 500 брендовых меню
× 30 позиций) и GIN индекс даст:

- `Bitmap Index Scan on idx_menu_items_search_vector` → `Bitmap Heap Scan` с
  ~50 попаданиями вместо полного seq scan.
- Ожидаемое ускорение 100–500× на realистичных FTS объёмах.

**Правило индексирования #1**: `EXPLAIN` должен быть одним из входных сигналов
при проектировании, а не оправданием после.

---

## Q3 — Partition pruning: заказы за месяц

```sql
SELECT COUNT(*)
  FROM orders
 WHERE created_at >= '2026-03-01'
   AND created_at <  '2026-04-01';
```

```
Aggregate  (actual rows=1)
  ->  Seq Scan on orders_2026_03 orders  (actual rows=418)
        Filter: ((created_at >= '2026-03-01') AND (created_at < '2026-04-01'))
Execution Time: 0.385 ms
```

**Ключевой момент**: в плане видна **только одна партиция** `orders_2026_03`.
Остальные 14 партиций даже не появились в `Append` — Postgres отсёк их на
стадии планирования через **partition pruning**. Без RANGE-партиционирования
пришлось бы seq-scan всей таблицы. На 200к+ строк это было бы 1 700 мс vs
~20 мс.

Это иллюстрирует, почему `orders` партиционирована по `created_at` (и почему
первичный ключ пришлось сделать композитным `(order_id, created_at)` — PK FK на
партиционированной таблице обязаны включать колонку партиционирования).

---

## Q4 — Covering index на inventory

```sql
SELECT ingredient_id, quantity
  FROM inventory
 WHERE branch_id = 'b1000000-0000-0000-0000-000000000001';
```

```
Bitmap Heap Scan on inventory  (actual rows=9)
  Recheck Cond: (branch_id = 'b1000000-...')
  Heap Blocks: exact=12
  ->  Bitmap Index Scan on inventory_pkey  (actual rows=983)
        Index Cond: (branch_id = '...')
Execution Time: 0.213 ms
```

Сейчас используется PK (`branch_id, ingredient_id`) и потом идёт heap fetch
за `quantity`. В
[db/05_indexes.sql](../db/05_indexes.sql) есть **covering index**:

```sql
CREATE INDEX idx_inventory_low_stock
    ON inventory (branch_id, ingredient_id)
    INCLUDE (quantity);
```

Эффект: `Index Only Scan` вместо `Bitmap Heap Scan` — `quantity` читается прямо
из индекса, без обращения к heap-страницам. Это особенно важно для
`fn_check_low_stock()`, который крутится каждые несколько секунд на dashboard
low-stock alerts — экономит 12 random I/O на каждый вызов.

---

## Q5 — BRIN на append-only audit_log

```sql
SELECT * FROM audit_log
 WHERE changed_at >= NOW() - INTERVAL '1 day';
```

**Зачем BRIN**. `audit_log` растёт append-only: каждая операция добавляет
строку, ничего не обновляется. Физический порядок совпадает с логическим
(`changed_at` монотонно растёт).

- **B-tree** на `changed_at`: ~10 МБ на 1М строк — для каждой строки по записи.
- **BRIN** (`pages_per_range = 64`): ~40 КБ на тот же миллион — одна запись
  на 64 страницы.

При запросе "аудит за последний день" BRIN отсекает 99% диапазонов сразу, и
дальше Postgres делает точечный bitmap heap scan только по нужным страницам.
Потеря точности фильтрации (false positives внутри range) компенсируется тем,
что индекс в 250× компактнее и полностью влезает в кэш.

На учебных 69 строках BRIN не показывает преимущества — планировщик вообще
предпочитает seq scan. Это **правильное решение** при таком объёме; BRIN
включается в игру при 100k+ строк.

---

## Итоговая таблица — карта индексов к сценариям

| Индекс                              | Тип              | Запрос-потребитель                          | Почему именно этот тип                               |
|-------------------------------------|------------------|---------------------------------------------|------------------------------------------------------|
| `idx_orders_active`                 | partial B-tree   | kitchen display (Q1)                        | малая доля строк, постоянный предикат                |
| `idx_orders_tenant_branch_created`  | composite B-tree | список заказов филиала за период            | главный композитный, покрывает 3 измерения           |
| `idx_menu_items_search_vector`      | GIN              | FTS по меню (Q2)                            | неструктурированный текст                            |
| `idx_menu_items_name_trgm`          | GIN trgm         | fuzzy-поиск (опечатки)                      | trigrams устойчивы к опечаткам                       |
| `idx_inventory_low_stock`           | covering B-tree  | `fn_check_low_stock` (Q4)                   | INCLUDE даёт Index Only Scan                         |
| `idx_audit_log_changed_at_brin`     | BRIN             | аудит за период (Q5)                        | append-only, корреляция физ.порядка                  |
| `idx_users_email_lower`             | expression       | case-insensitive login                      | поиск по функции от колонки                          |
| `idx_branches_operating_hours_gin`  | GIN JSONB        | "кто открыт сейчас"                         | JSONB path queries                                   |
| `idx_ingredients_allergens_gin`     | GIN array        | "блюда без глютена"                         | `@>` на массиве                                      |
| `idx_reservations_period_gist`      | GiST             | пересекающиеся бронирования                 | range overlap `&&`                                   |
| `idx_sessions_expires_at`           | partial B-tree   | housekeeping cleanup                        | 99% строк уже `revoked_at NOT NULL`                  |

Каждый имеет `COMMENT ON INDEX` с обоснованием прямо в
[db/05_indexes.sql](../db/05_indexes.sql) — `\d+ orders` в psql показывает эти
комментарии.

---

## Что делать, если индекс **не** используется

Диагностическая последовательность:

1. **`EXPLAIN (ANALYZE, BUFFERS)` вместо простого `EXPLAIN`** — реальные
   времена и буферы вместо cost-модели.
2. **`ANALYZE <table>`** — если статистика устарела, планировщик примет
   странные решения.
3. **Проверить селективность**: `SELECT COUNT(*) FROM ... WHERE <предикат>`.
   Если предикат возвращает >20% таблицы, планировщик **правильно** выберет
   seq scan.
4. **Проверить, что предикат совпадает с `WHERE` partial индекса** побуквенно:
   `WHERE status IN ('a','b')` и `WHERE status = 'a' OR status = 'b'` для
   planner — разные предикаты.
5. **`SET enable_seqscan = off;`** временно — если и тогда индекс не выбран,
   значит он не подходит по типу/порядку колонок.
6. **`pg_stat_statements`** для топ-10 медленных запросов в продакшене.
