SHELL := /bin/bash
.DEFAULT_GOAL := help

# River → migrate-up → roles-pw → verify é ORDEM, não conveniência.
# A 012 concede privilégios sobre objetos criados pela CLI do River.
.NOTPARALLEL:

-include .env
export

COMPOSE ?= docker compose
# `=` é intencional: esta variável é exportada aos makes recursivos. Com `?=`,
# o filho preservava a URL 5432 herdada do pai mesmo quando o test-stack
# sobrescrevia DATABASE_URL_MIGRATE para a porta isolada 55432.
PSQL_URL = $(DATABASE_URL_MIGRATE)
MIGRATIONS := db/migrations
SEEDS := db/seed

# PINADO. Com @latest, um upgrade do River muda o schema de river_job sem
# aviso — e a 012 concede privilégio tabela a tabela. Subir versão é decisão,
# não efeito colateral de rodar `make` num dia diferente.
RIVER_VERSION ?= v0.14.3
MIGRATE_VERSION ?= v4.18.3

# Defaults só para o caso de .env existir e estar incompleto; quem realmente
# fecha o buraco é o require-env.
POSTGRES_USER ?= monitor
POSTGRES_DB   ?= monitor
POSTGRES_PORT ?= 5432
TARGET_PORT   ?= 8081
TEST_POSTGRES_PORT ?= 55432
TEST_TARGET_PORT   ?= 58081
TEST_PROJECT       ?= monitor-infra-test
TEST_VOLUME        ?= monitor-infra-test-pgdata
TEST_DATABASE_URL  ?= postgres://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@localhost:$(TEST_POSTGRES_PORT)/$(POSTGRES_DB)?sslmode=disable

# O CLI seleciona drivers por build tag. Sem `postgres`, ele compila e só
# falha em runtime com "unknown driver postgres".
MIGRATE := go run -tags postgres github.com/golang-migrate/migrate/v4/cmd/migrate@$(MIGRATE_VERSION)
RIVER_DATABASE_URL = $(PSQL_URL)$(if $(findstring ?,$(PSQL_URL)),&,?)search_path=river

# psql roda no container, então não é preciso ter o servidor instalado na
# máquina — só o cliente, se quiser usar `make psql` ou `make test-login`.
PSQL := $(COMPOSE) exec -T -e PGOPTIONS=--client-min-messages=warning postgres \
        psql -v ON_ERROR_STOP=1 -U $(POSTGRES_USER) -d $(POSTGRES_DB)

# As senhas chegam por -v (variável do psql), NUNCA por crase: a crase roda um
# shell no processo CLIENTE, que vive dentro do container e não enxerga o .env.
PSQL_VARS := -v migrate_pw="$(MONITOR_MIGRATE_PASSWORD)" \
             -v api_pw="$(MONITOR_API_PASSWORD)" \
             -v worker_pw="$(MONITOR_WORKER_PASSWORD)" \
             -v target_port="$(TARGET_PORT)"

.PHONY: help
help: ## mostra os alvos disponíveis
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: require-env
require-env:
	@test -f .env || { echo "ERRO: falta .env — rode: cp .env.example .env"; exit 1; }
	@for v in POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB POSTGRES_PORT TARGET_PORT \
	          MONITOR_MIGRATE_PASSWORD MONITOR_API_PASSWORD MONITOR_WORKER_PASSWORD \
	          DATABASE_URL_MIGRATE; do \
	  [ -n "$${!v}" ] || { echo "ERRO: $$v vazia no .env — veja .env.example"; exit 1; }; \
	done

.PHONY: up
up: require-env ## sobe Postgres e os alvos locais, e espera ficarem saudáveis
	$(COMPOSE) up -d --wait
	@echo "postgres em localhost:$(POSTGRES_PORT) · alvos em http://localhost:$(TARGET_PORT)/ok"

.PHONY: down
down: ## derruba os containers (mantém o volume)
	$(COMPOSE) down

.PHONY: nuke
nuke: ## derruba e APAGA o volume de dados
	$(COMPOSE) down -v

.PHONY: migrate
migrate: require-tools river migrate-up roles-pw ## provisiona River e aplica 001→012
	@echo "migrations aplicadas: version=$$($(PSQL) -Atc 'SELECT version FROM schema_migrations')"

.PHONY: migrate-up
migrate-up: require-env ## aplica somente migrations pendentes com golang-migrate
	$(MIGRATE) -path $(MIGRATIONS) -database "$(PSQL_URL)" up

.PHONY: roles-pw
roles-pw: require-env ## define as senhas dos papéis a partir do .env (depois da 011)
	@$(PSQL) $(PSQL_VARS) < db/roles-pw.sql

.PHONY: river
river: require-env ## cria schema e tabelas do River (exige Go e rede). ANTES da 012
	@$(PSQL) -c 'CREATE SCHEMA IF NOT EXISTS river'
	go run github.com/riverqueue/river/cmd/river@$(RIVER_VERSION) migrate-up \
	  --database-url "$(RIVER_DATABASE_URL)"

.PHONY: migrate-down
migrate-down: require-env ## reverte 012→001. SÓ para desenvolvimento: produção é forward-only
	$(MIGRATE) -path $(MIGRATIONS) -database "$(PSQL_URL)" down -all

.PHONY: migrate-force
migrate-force: require-env ## recuperação manual: make migrate-force VERSION=N
	@test -n "$(VERSION)" || { echo "ERRO: informe VERSION=N"; exit 1; }
	$(MIGRATE) -path $(MIGRATIONS) -database "$(PSQL_URL)" force $(VERSION)

.PHONY: version
version: require-env ## mostra versão atual e estado dirty
	@$(PSQL) -Atc "SELECT version || ' dirty=' || dirty FROM schema_migrations"

.PHONY: seed
seed: require-env ## popula com o time, o usuário e os alvos de desenvolvimento
	@set -e; for f in $$(ls $(SEEDS)/*.sql | sort); do \
	  echo "→ $$f"; $(PSQL) $(PSQL_VARS) < $$f; \
	done

.PHONY: reset
# require-env vem ANTES do nuke, e a ordem é a correção de um defeito: com
# `nuke` primeiro, um .env ausente ou incompleto apagava o volume e SÓ ENTÃO
# falhava. Toda pré-condição verificável é checada antes da operação destrutiva.
reset: require-env nuke up migrate seed verify ## do zero: apaga o volume, sobe, migra COM River, popula e confere

.PHONY: bootstrap
bootstrap: reset test-permissions test-login ## a fase 0 inteira, do zero e verificada

.PHONY: psql
psql: require-env ## abre um psql interativo no banco
	$(COMPOSE) exec postgres psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)

.PHONY: check
check: require-env ## roda as consultas de operação: atraso, lease órfão, zumbis, divergência
	@$(PSQL) < db/checks.sql

.PHONY: verify
verify: require-env ## PORTÃO: confere as invariantes do schema. Quebrou => sai 3
	@$(PSQL) < db/verify.sql

.PHONY: test-permissions
test-permissions: require-env ## prova os GRANT conectando com os papéis REAIS
	@$(PSQL) $(PSQL_VARS) < db/permissions.sql

.PHONY: require-tools
require-tools: require-env
	@command -v go >/dev/null || { echo "ERRO: Go não encontrado"; exit 1; }
	@$(COMPOSE) version >/dev/null || { echo "ERRO: compose não encontrado"; exit 1; }

.PHONY: test-login
test-login: require-env ## prova que as senhas do .env viraram as senhas dos papéis
	@# Usa um segundo container cliente na rede Compose. Loopback dentro do
	@# próprio Postgres cai em trust nesta imagem; postgres:5432 pela bridge cai
	@# no pg_hba host/scram e reproduz a conexão dos serviços, sem psql no host.
	@# monitor_migrate entra no loop: o roles-pw define a senha dos TRÊS e o
	@# verify só confirma que os três têm algum hash. Sem testar o login dele,
	@# uma senha divergente de MONITOR_MIGRATE_PASSWORD passava pelo bootstrap
	@# inteiro e só apareceria na primeira migration que usasse o papel.
	@set -e; \
	for pair in "monitor_api:$(MONITOR_API_PASSWORD)" \
	            "monitor_worker:$(MONITOR_WORKER_PASSWORD)" \
	            "monitor_migrate:$(MONITOR_MIGRATE_PASSWORD)"; do \
	  role=$${pair%%:*}; pw=$${pair#*:}; \
	  $(COMPOSE) run --rm --no-deps -T -e PGPASSWORD="$$pw" postgres \
	    psql -X -q -t -w -h postgres -U $$role \
	    -d $(POSTGRES_DB) -c "SELECT current_user, current_setting('TimeZone')" \
	    || { echo "FALHOU: $$role não logou com a senha do .env — rodou o make roles-pw?"; exit 1; }; \
	  if $(COMPOSE) run --rm --no-deps -T -e PGPASSWORD="senha-errada-$$RANDOM" postgres \
	       psql -X -q -w -h postgres -U $$role -d $(POSTGRES_DB) -c 'SELECT 1' >/dev/null 2>&1; then \
	    echo "FALHOU: $$role aceitou senha ERRADA — o pg_hba está em trust e este teste é vazio"; \
	    exit 1; \
	  fi; \
	done; \
	echo "ok: senhas do .env conferem, e senha errada é recusada"

.PHONY: logs
logs: ## acompanha logs do ambiente local
	$(COMPOSE) logs -f --tail=200

.PHONY: test-contracts
test-contracts: ## valida OpenAPI e vetores compartilhados
	cd tests/contracts && go test ./...
	@$(MAKE) diff-contracts

.PHONY: test-invariants
test-invariants: require-env ## exercita CHECKs e unicidades com rollback
	@$(PSQL) < db/invariants.sql

.PHONY: test-stack
test-stack: require-tools
	@set -eu; \
	cleanup() { $(MAKE) --no-print-directory COMPOSE='$(COMPOSE) -p $(TEST_PROJECT)' PG_VOLUME_NAME='$(TEST_VOLUME)' POSTGRES_PORT='$(TEST_POSTGRES_PORT)' TARGET_PORT='$(TEST_TARGET_PORT)' DATABASE_URL_MIGRATE='$(TEST_DATABASE_URL)' nuke >/dev/null 2>&1 || true; }; \
	trap cleanup EXIT INT TERM; \
	$(MAKE) --no-print-directory COMPOSE='$(COMPOSE) -p $(TEST_PROJECT)' PG_VOLUME_NAME='$(TEST_VOLUME)' POSTGRES_PORT='$(TEST_POSTGRES_PORT)' TARGET_PORT='$(TEST_TARGET_PORT)' DATABASE_URL_MIGRATE='$(TEST_DATABASE_URL)' reset; \
	$(MAKE) --no-print-directory COMPOSE='$(COMPOSE) -p $(TEST_PROJECT)' PG_VOLUME_NAME='$(TEST_VOLUME)' POSTGRES_PORT='$(TEST_POSTGRES_PORT)' TARGET_PORT='$(TEST_TARGET_PORT)' DATABASE_URL_MIGRATE='$(TEST_DATABASE_URL)' migrate-down; \
	$(MAKE) --no-print-directory COMPOSE='$(COMPOSE) -p $(TEST_PROJECT)' PG_VOLUME_NAME='$(TEST_VOLUME)' POSTGRES_PORT='$(TEST_POSTGRES_PORT)' TARGET_PORT='$(TEST_TARGET_PORT)' DATABASE_URL_MIGRATE='$(TEST_DATABASE_URL)' river migrate-up roles-pw seed verify test-invariants test-permissions test-login

.PHONY: test-migrations
test-migrations: test-stack ## ciclo isolado e descartável: up → down → up

.PHONY: test
test: test-contracts test-stack ## todos os portões, em banco isolado e descartável

.PHONY: ci
ci: test ## entrada única do CI
	@git diff --check

.PHONY: sync-contracts
sync-contracts: ## copia os contratos deste repo para os repos irmãos
	@# Este repo é o CANÔNICO. Com repos separados e sem registro de pacotes,
	@# a sincronia é explícita: sem ela, as duas implementações de SSRF
	@# divergem em silêncio, que é exatamente o que o contrato existe para
	@# impedir. Quando houver CI, isto vira download de uma tag fixada.
	@#
	@# openapi.yaml NÃO entra: a suíte da API o lê deste diretório
	@# (MONITOR_INFRA_DIR) e o app gera os modelos a partir daqui. Cópia seria
	@# mais uma superfície para divergir.
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
