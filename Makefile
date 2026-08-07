.PHONY: dev dev-all dev-backend dev-frontend build test test-backend test-frontend lint lint-python lint-ts clean install install-all install-backend install-frontend db-backup db-drain

dev:
	npm run dev:all

dev-all:
	npm run dev:all

dev-backend:
	npm run dev:backend

dev-frontend:
	npm run dev:frontend

build:
	npm run build:frontend

test:
	python3 -m pytest -xvs
	cd frontend && npx vitest run

test-backend:
	python3 -m pytest -xvs backend/tests

test-frontend:
	cd frontend && npx vitest run

lint:
	ruff check backend/ pipeline/ tests/
	cd frontend && npx prettier --check "src/**/*.{ts,tsx}"

lint-python:
	ruff check backend/ pipeline/ tests/

lint-ts:
	cd frontend && npx prettier --check "src/**/*.{ts,tsx}"

clean:
	rm -rf .ruff_cache/ .pytest_cache/ .coverage
	rm -rf backend/__pycache__/ pipeline/__pycache__/
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true

install-all:
	npm run install:all

install-backend:
	pip install -r backend/requirements.txt

install-frontend:
	npm --prefix frontend install

start:
	./backend/start.sh

# ── Ops: backup e drenagem sob demanda (BYOB / Drain-First) ─────────────────
# Alvos padrão = banco da NUVEM (Aiven), conforme DATABASE_URL do backend/.env.
# Upload p/ Object Storage acontece automaticamente se credenciais estiverem
# configuradas (OBJECT_STORAGE_BUCKET + AWS_* + S3_ENDPOINT_URL); senão os
# artefatos ficam 100% locais (database/backups_locais/ e database/logs_locais/).
db-backup:
	bash ops/backup_local_ondemand.sh

db-drain:
	python3 ops/drain_logs.py
