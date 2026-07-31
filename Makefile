SHELL := /bin/bash
.DEFAULT_GOAL := help

-include .env
export

COMPOSE ?= docker compose
PSQL_URL ?= $(DATABASE_URL_MIGRATE)
MIGRATIONS := db/migrations
SEEDS := db/seed

# psql roda no container, então não é preciso ter o servidor instalado na
# máquina — só o cliente, se quiser usar `make psql` de fora.
PSQL := $(COMPOSE) exec -T -e PGOPTIONS=--client-min-messages=warning postgres \
        psql -v ON_ERROR_STOP=1 -U $(POSTGRES_USER) -d $(POSTGRES_DB)

.PHONY: help
help: ## mostra os alvos disponíveis
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: up
up: ## sobe Postgres e os alvos locais, e espera ficarem saudáveis
	$(COMPOSE) up -d --wait
	@echo "postgres em localhost:$(POSTGRES_PORT) · alvos em http://localhost:$(TARGET_PORT)/ok"

.PHONY: down
down: ## derruba os containers (mantém o volume)
	$(COMPOSE) down

.PHONY: nuke
nuke: ## derruba e APAGA o volume de dados
	$(COMPOSE) down -v

.PHONY: migrate
migrate: ## aplica 001→012 em ordem
	@set -e; for f in $$(ls $(MIGRATIONS)/*.up.sql | sort); do \
	  echo "→ $$f"; \
	  $(PSQL) \
	    -v migrate_pw="$(MONITOR_MIGRATE_PASSWORD)" \
	    -v api_pw="$(MONITOR_API_PASSWORD)" \
	    -v worker_pw="$(MONITOR_WORKER_PASSWORD)" \
	    < $$f; \
	done
	@echo "migrations aplicadas"

.PHONY: migrate-down
migrate-down: ## reverte 012→001. SÓ para desenvolvimento: produção é forward-only
	@set -e; for f in $$(ls $(MIGRATIONS)/*.down.sql | sort -r); do \
	  echo "← $$f"; $(PSQL) < $$f; \
	done

.PHONY: seed
seed: ## popula com o time, o usuário e os alvos de desenvolvimento
	@set -e; for f in $$(ls $(SEEDS)/*.sql | sort); do \
	  echo "→ $$f"; $(PSQL) < $$f; \
	done

.PHONY: reset
reset: nuke up migrate seed ## do zero: apaga o volume, sobe, migra e popula

.PHONY: psql
psql: ## abre um psql interativo no banco
	$(COMPOSE) exec postgres psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)

.PHONY: check
check: ## roda as consultas de operação: atraso, lease órfão, zumbis, divergência
	@$(PSQL) < db/checks.sql

.PHONY: verify
verify: ## confere que o schema aplicou corretamente
	@$(PSQL) < db/verify.sql

.PHONY: river
river: ## cria as tabelas do River (exige Go). Rode ANTES da migration 012
	go run github.com/riverqueue/river/cmd/river@latest migrate-up \
	  --database-url "$(PSQL_URL)" --schema river

.PHONY: sync-contracts
sync-contracts: ## copia os contratos deste repo para os repos irmãos
	@# Este repo é o CANÔNICO. Com repos separados e sem registro de pacotes,
	@# a sincronia é explícita: sem ela, as duas implementações de SSRF
	@# divergem em silêncio, que é exatamente o que o contrato existe para
	@# impedir. Quando houver CI, isto vira download de uma tag fixada.
	@set -e; \
	for repo in ../worker ../api; do \
	  if [ -d "$$repo" ]; then \
	    mkdir -p "$$repo/contracts"; \
	    cp contracts/ssrf-vectors.json "$$repo/contracts/"; \
	    echo "→ $$repo/contracts/ssrf-vectors.json"; \
	  fi; \
	done
	@echo "contratos sincronizados. Commite nos repos de destino."

.PHONY: diff-contracts
diff-contracts: ## acusa divergência entre este repo e os irmãos
	@set -e; ok=1; \
	for repo in ../worker ../api; do \
	  f="$$repo/contracts/ssrf-vectors.json"; \
	  if [ -f "$$f" ]; then \
	    if ! diff -q contracts/ssrf-vectors.json "$$f" >/dev/null; then \
	      echo "DIVERGENTE: $$f"; ok=0; \
	    else echo "ok: $$f"; fi; \
	  fi; \
	done; \
	[ $$ok -eq 1 ] || { echo "rode 'make sync-contracts'"; exit 1; }
