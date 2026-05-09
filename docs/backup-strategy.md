# Backup & disaster recovery strategy

> Стратегия рассчитана на учебный SaaS в одном регионе. Цель — не нулевой RPO
> (для этого нужна синхронная реплика), а **быстрое восстановление до
> состояния "вчера вечером"** и воспроизводимая процедура disaster recovery,
> которую можно прогнать живьём перед защитой.

## RPO / RTO цели

| Параметр | Цель     | Чем обеспечено                              |
|----------|----------|---------------------------------------------|
| RPO      | ≤ 1 сутки| ежедневный `pg_dump` + почасовые MV-refresh |
| RTO      | ≤ 10 мин | скрипт `restore.sh` с автоматическим DROP/CREATE/pg_restore |
| Test RTO | ≤ 3 мин  | `disaster-recovery-drill.sh` — полный round-trip на seed-объёме |

Для реальной продакшн-SaaS этого мало: понадобятся WAL archiving + PITR и
standby replica. Архитектура на это рассчитана (см. секцию **Upgrade path**),
но в рамках учебного проекта мы ограничиваемся логическими бэкапами.

---

## Ежедневный backup — `backup.sh`

[db/backup/backup.sh](../db/backup/backup.sh)

```bash
pg_dump \
    --host="$PGHOST" --port="$PGPORT" \
    --username="$PGUSER" --dbname="$PGDATABASE" \
    --format=custom \
    --jobs=4 \
    --compress=6 \
    --file="$BACKUP_DIR/ros_$(date +%Y%m%d_%H%M%S).dump"
```

Почему именно так:

- **`--format=custom`**, не plain SQL. Custom format даёт параллельный
  restore, выборочное восстановление отдельных таблиц, и в 3-5 раз компактнее.
- **`--jobs=4`** — параллельный dump. На многотабличной схеме (~25 таблиц)
  ускоряет в ~3 раза. Custom format обязан для `--jobs`.
- **`--compress=6`** — компромисс CPU/размер. 9 экономит ~5% размера за 40%
  CPU, 0 даёт большие файлы.
- **Retention 7 дней**: `find "$BACKUP_DIR" -name 'ros_*.dump' -mtime +7 -delete`.
  Для учебного проекта достаточно; в реальном проде — GFS retention (7 ежедн.
  + 4 недельных + 12 месячных), уезжает в S3 glacier.

### Что **не** попадает в бэкап и почему

- `pg_dump` **не** бэкапит роли (`app_readonly`, `app_waiter`, …) —
  они живут на уровне кластера, не базы. Отдельно: `pg_dumpall --roles-only`
  раз в неделю. Это делает [db/backup/backup.sh](../db/backup/backup.sh) тоже
  (см. блок `ROLES_FILE`).
- Extensions (`citext`, `pg_trgm`, …) попадают как `CREATE EXTENSION` команды,
  но **сами extension-объекты не дампятся** — они пересоздадутся при restore.

---

## Restore — `restore.sh`

[db/backup/restore.sh](../db/backup/restore.sh)

Процедура:

1. Берёт имя дампа (или `latest` — скрипт сам находит свежайший в
   `$BACKUP_DIR`).
2. **Спрашивает подтверждение** — чтобы `restore.sh latest` по ошибке не
   снёс прод.
3. `DROP DATABASE IF EXISTS` + `CREATE DATABASE`.
4. `pg_restore --jobs=4 --exit-on-error --no-owner --role=$PGUSER`.
5. `ANALYZE` для свежей статистики.

Ключевой флаг `--exit-on-error`: по умолчанию pg_restore продолжает после
ошибок, и ты легко получаешь частично-восстановленную базу, которая "вроде
работает". Плохая идея. Лучше упасть громко.

---

## Disaster recovery drill — живая демка

[db/backup/disaster-recovery-drill.sh](../db/backup/disaster-recovery-drill.sh)

Скрипт, который я запускаю **на защите**. Полная последовательность:

```bash
./db/backup/disaster-recovery-drill.sh
```

### Что делает

1. **Baseline**: фиксирует `COUNT(*)` по всем таблицам в файл
   `/tmp/ros_drill_before.txt`.
2. Запускает `backup.sh`, получает свежий дамп.
3. **`DROP DATABASE restaurant_ordering`** — симуляция катастрофы.
4. `CREATE DATABASE` пустую.
5. `pg_restore` из дампа.
6. Повторно считает `COUNT(*)` → `/tmp/ros_drill_after.txt`.
7. `diff` файлов. Пустой diff = **данные восстановлены 1:1**.
8. Проверка функциональности: вызывает `fn_place_order` на тестовых данных,
   проверяет что возвращается корректный order_id.

Вывод в консоль максимально шумный (`echo`, цвета) — чтобы на защите было
видно каждый шаг.

---

## Что делать если упали "всерьёз" (runbook)

### Сценарий 1: случайное `DELETE` в приложении

```bash
# 1. Остановить приложение (чтобы оно не писало новые данные поверх)
docker compose stop backend frontend

# 2. Найти вчерашний бэкап
ls -lt backups/ | head -3

# 3. Восстановить в отдельную базу для сравнения
createdb restaurant_ordering_recovery
pg_restore -d restaurant_ordering_recovery backups/ros_YYYYMMDD.dump

# 4. Достать удалённые строки нужной таблицы
psql -d restaurant_ordering_recovery -c \
    "\\copy (SELECT * FROM orders WHERE created_at > 'YYYY-MM-DD') TO '/tmp/orders_rescue.csv' CSV HEADER"

# 5. Залить обратно в продакшн
psql -d restaurant_ordering -c \
    "\\copy orders FROM '/tmp/orders_rescue.csv' CSV HEADER"

# 6. Поднять приложение
docker compose up -d
```

### Сценарий 2: диск умер, базы нет

```bash
# 1. Поднять пустой Postgres
docker compose up -d postgres

# 2. Применить схему с нуля
for f in db/0*.sql db/1*.sql; do
    psql -U ros_admin -d restaurant_ordering -f "$f"
done

# 3. Восстановить данные поверх схемы
# (pg_restore --data-only = только данные, без DDL)
pg_restore --data-only --dbname=restaurant_ordering backups/latest.dump

# 4. Проверка
psql -c "SELECT COUNT(*) FROM orders;"

# 5. Поднять приложение
docker compose up -d backend frontend
```

### Сценарий 3: кто-то дропнул extension (редко)

```bash
psql -c "CREATE EXTENSION IF NOT EXISTS citext;"
psql -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
# ... остальные из 01_extensions.sql
```

---

## Upgrade path — что дальше в реальной проде

Эта стратегия — логический бэкап. Для продакшена SaaS с RPO < 5 минут нужно:

1. **WAL archiving**: `archive_mode = on`,
   `archive_command = 'aws s3 cp %p s3://ros-wal/%f'`.
   Даёт **point-in-time recovery** — можно восстановиться на любой момент в
   прошлом, а не только "на вчерашний вечер".
2. **Physical backup**: `pg_basebackup` раз в неделю вместо/вместе с
   `pg_dump`. Быстрее восстанавливается (без парсинга SQL).
3. **Streaming replication**: synchronous standby в соседней AZ. Падение
   primary → promote standby за секунды, RPO = 0 для committed transactions.
4. **Point-in-time recovery демо**: при наличии WAL archive можно
   воспроизвести "восстановиться на 14:23:05 до того момента, как приложение
   сломало данные".

Всё это **архитектурно совместимо** с текущей схемой (никаких физических
конфликтов), но требует отдельной инфраструктуры (S3 bucket, standby host),
что выходит за рамки учебного проекта. В слайдах презентации это упомянуто
как "Production upgrade path" — чтобы было видно, что решение осмысленное, а
не случайное.

---

## Проверка бэкапа — не "сделали", а "работает"

Главное правило: **бэкап, который ты не проверял, — это не бэкап**.
Проверка включена в `Makefile`:

```makefile
backup-test:
	./db/backup/disaster-recovery-drill.sh
```

Запускается раз в неделю на CI (отдельный job в GitHub Actions). Если drill
падает — открывается issue. На защите я запускаю этот же target вживую.
