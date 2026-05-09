.PHONY: up down restart logs psql seed reset backup restore test lint fmt

up:
	docker compose up -d
	@echo "Postgres: localhost:5432  |  pgAdmin: http://localhost:5050"

down:
	docker compose down

restart:
	docker compose restart postgres

logs:
	docker compose logs -f postgres

psql:
	docker compose exec postgres psql -U $${POSTGRES_USER:-ros_admin} -d $${POSTGRES_DB:-restaurant_ordering}

reset:
	docker compose down -v
	docker compose up -d

seed:
	python scripts/seed_faker.py

backup:
	bash db/backup/backup.sh

restore:
	bash db/backup/restore.sh

test:
	cd backend && pytest -q

lint:
	sqlfluff lint db/ || true
	cd backend && ruff check .

fmt:
	sqlfluff fix db/ || true
	cd backend && ruff format .
