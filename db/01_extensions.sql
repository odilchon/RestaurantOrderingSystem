-- ============================================================================
-- 01_extensions.sql
-- Расширения PostgreSQL, используемые в Restaurant Ordering System.
-- ============================================================================

-- Криптография: gen_random_uuid(), digest(), crypt() для хешей и UUID.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- GiST-операторы для обычных типов: нужны для EXCLUDE-ограничения
-- на пересечение бронирований стола.
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- Триграммы: быстрый fuzzy-поиск по названиям блюд / именам клиентов.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Статистика выполняемых запросов: основа observability и отчёта о
-- медленных запросах в README.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Case-insensitive текст: для email и прочих полей, где сравнение
-- должно игнорировать регистр без постоянного LOWER().
CREATE EXTENSION IF NOT EXISTS citext;
