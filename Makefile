.PHONY: dev dev:backend dev:frontend build test test:backend test:frontend lint lint:python lint:ts clean install install:all install:backend install:frontend

dev:all:
	npm run dev:all

dev:backend:
	npm run dev:backend

dev:frontend:
	npm run dev:frontend

build:
	npm run build:frontend

test:
	cd backend && python -m pytest -xvs
	cd frontend && npx vitest run

test:backend:
	cd backend && python -m pytest -xvs

test:frontend:
	cd frontend && npx vitest run

lint:
	ruff check backend/ pipeline/ tests/
	cd frontend && npx prettier --check "src/**/*.{ts,tsx}"

lint:python:
	ruff check backend/ pipeline/ tests/

lint:ts:
	cd frontend && npx prettier --check "src/**/*.{ts,tsx}"

clean:
	rm -rf .ruff_cache/ .pytest_cache/ .coverage
	rm -rf backend/__pycache__/ pipeline/__pycache__/
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true

install:all:
	npm run install:all

install:backend:
	pip install -r backend/requirements.txt

install:frontend:
	npm --prefix frontend install

start:
	./backend/start.sh
