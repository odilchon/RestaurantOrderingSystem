-- ============================================================================
-- 08_maintenance.sql — VACUUM, ANALYZE, REINDEX, bloat и slow query анализ
-- ============================================================================

-- 1. Размер таблиц и индексов (для README сводки).
SELECT
    schemaname || '.' || relname AS table_name,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
    pg_size_pretty(pg_relation_size(relid))       AS table_size,
    pg_size_pretty(pg_total_relation_size(relid) - pg_relation_size(relid)) AS indexes_size,
    n_live_tup AS live_rows,
    n_dead_tup AS dead_rows
  FROM pg_stat_user_tables
 ORDER BY pg_total_relation_size(relid) DESC
 LIMIT 20;

-- 2. Неиспользуемые индексы — кандидаты на удаление.
SELECT
    schemaname || '.' || relname AS table,
    indexrelname AS index,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size,
    idx_scan AS scans
  FROM pg_stat_user_indexes
 WHERE idx_scan = 0
 ORDER BY pg_relation_size(indexrelid) DESC;

-- 3. Топ-10 медленных запросов (требует pg_stat_statements).
SELECT
    substring(query, 1, 80) AS query_preview,
    calls,
    ROUND(total_exec_time::numeric, 2) AS total_ms,
    ROUND(mean_exec_time::numeric, 2)  AS mean_ms,
    ROUND((100 * total_exec_time / NULLIF(SUM(total_exec_time) OVER (), 0))::numeric, 2) AS pct_total
  FROM pg_stat_statements
 ORDER BY total_exec_time DESC
 LIMIT 10;

-- 4. Bloat estimate (упрощённая оценка — точная требует расширения pgstattuple).
SELECT
    schemaname || '.' || relname AS table,
    n_live_tup,
    n_dead_tup,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
    last_vacuum,
    last_autovacuum
  FROM pg_stat_user_tables
 WHERE n_dead_tup > 0
 ORDER BY dead_pct DESC NULLS LAST
 LIMIT 20;

-- 5. Ручной VACUUM на горячей таблице после массового UPDATE/DELETE.
VACUUM (ANALYZE, VERBOSE) orders;

-- 6. REINDEX CONCURRENTLY без блокировки чтений/записей (только B-tree).
-- REINDEX INDEX CONCURRENTLY idx_orders_tenant_branch_created;

-- 7. EXPLAIN ANALYZE на горячем запросе: активные заказы в филиале.
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT *
  FROM orders
 WHERE branch_id = (SELECT branch_id FROM branches LIMIT 1)
   AND status IN ('pending', 'confirmed', 'preparing', 'ready')
 ORDER BY created_at DESC
 LIMIT 20;

-- 8. Проверка partition pruning на orders.
EXPLAIN (ANALYZE, BUFFERS)
SELECT SUM(total_amount)
  FROM orders
 WHERE created_at >= NOW() - interval '7 days';

-- 9. Статистика партиций orders.
SELECT
    child.relname AS partition_name,
    pg_size_pretty(pg_relation_size(child.oid)) AS size,
    pg_get_expr(child.relpartbound, child.oid)  AS bound
  FROM pg_inherits i
  INNER JOIN pg_class parent ON i.inhparent = parent.oid
  INNER JOIN pg_class child  ON i.inhrelid  = child.oid
 WHERE parent.relname = 'orders'
 ORDER BY child.relname;

-- 10. Сброс pg_stat_statements для чистого эксперимента.
-- SELECT pg_stat_statements_reset();
