# monitor-infra

Schema, ambiente local e contratos compartilhados do monitor de uptime.

Com três repos de código independentes, **o banco é a única superfície comum entre a API e o
Worker** — por isso ele é escrito aqui, e não dentro de um dos dois. Nenhum serviço cria ou
altera tabela em runtime.

## Subir o ambiente

Requer Docker (ou Podman com `COMPOSE=podman-compose`).

```bash
cp .env.example .env
make up        # Postgres 16 + alvos locais, espera ficarem saudáveis
make river     # tabelas do River (exige Go); rode ANTES da 012
make migrate   # aplica 001 → 012
make seed      # time, usuário e monitores de desenvolvimento
make verify    # confere que o schema subiu inteiro
```

Ou tudo de uma vez, do zero: `make reset`.

`make help` lista os alvos. `make check` roda as consultas de operação — atraso de
agendamento, lease órfão, resultados zumbi, divergência de estado, compras pendentes de
acknowledge.

## Alvos locais

O compose sobe um nginx em `localhost:8081` com rotas que exercitam cada caminho do worker:

| Rota | Desfecho esperado |
|---|---|
| `/ok` | `up` |
| `/erro` | `down` / `unexpected_status` (500 persistente — o bug que derrubava o worker) |
| `/nao-encontrado` | `down` / `unexpected_status` |
| `/redireciona` | `up`, com 1 salto |
| `/redireciona-privado` | `unknown` / `ssrf_blocked` — redirect para a metadata da nuvem |
| `/cadeia` | `too_many_redirects` — 6 saltos, acima do máximo de 5 |

O seed também cadastra os domínios `*.exemplo.com` que vieram do rascunho. Eles **não
resolvem**, e é por isso que são úteis: são alvo de falha garantida por DNS, que é o caminho
mais chato de reproduzir sob demanda.

Esses alvos não substituem os fakes `httptest` do worker — aqueles cobrem timeout, corpo
travado e corpo gigante de forma determinística, dentro do processo de teste. Estes existem
para exercitar o ciclo completo com dado real no banco.

**Atenção ao SSRF em dev**: os alvos estão em loopback e o guard bloqueia rede privada por
padrão. O `.env.example` já traz `SSRF_ALLOWED_CIDRS=127.0.0.0/8`. Só `SSRF_ALLOWED_HOSTS` não
resolveria — o dial conhece o IP, nunca o host.

## Migrations

`db/migrations/NNN_descricao.{up,down}.sql`, aplicadas em ordem.

| # | Conteúdo |
|---|---|
| 001 | extensões |
| 002 | `plans`, `plan_products`, `users`, `teams`, `refresh_tokens` |
| 003 | `regions`, `urls`, `url_schedules` — o protocolo de concorrência mora aqui |
| 004 | `url_history` particionada + funções de partição |
| 005 | `url_history_hourly`, `url_history_daily` |
| 006 | `incidents`, `notifications` |
| 007 | `devices`, `notification_prefs` |
| 008 | `invites` |
| 009 | `subscriptions`, `billing_webhook_events`, `billing_tombstones` |
| 010 | `idempotency_keys`, `rate_events`, `audit_log`, `system_flags`, `worker_blindness` |
| 011 | papéis, `GRANT` por coluna e o trigger de `suspended_reason` |
| 012 | privilégios do schema `river` |

**O `down` existe para desenvolvimento local.** Produção é forward-only: correção lá é uma
migration nova, para frente. Nunca renomear nem remover coluna em um passo.

## Três coisas que o schema garante e que é fácil errar

**As FKs circulares entre `users` e `teams` são `DEFERRABLE`, mas `NOT NULL` não é adiável.**
`DEFERRABLE` adia a verificação *referencial* até o `COMMIT`; a constraint de coluna é checada
na hora. Criar o primeiro usuário exige reservar os dois IDs com `nextval` antes de qualquer
`INSERT` — `db/seed/001_dev.sql` é o exemplo executável.

**`unknown_reason` tem default.** O `CHECK` exige que todo status `unknown` tenha motivo, e
`urls.current_status` já nasce `unknown`. Sem o default, todo `INSERT INTO urls` violaria a
constraint.

**Os serviços conectam como seus próprios papéis**, sem `SET ROLE` e sem herança por
membership. O trigger de `suspended_reason` compara `current_user`, e o `ALTER ROLE ... SET
timezone` só vale para a sessão do papel. Cada serviço afirma os dois no boot — senão o
trigger vira decorativo e as partições nascem com 3 horas de deslocamento, os dois em
silêncio.

## Contratos

`contracts/` é o **canônico**. Como os repos são separados e não há registro de pacotes, a
sincronia é explícita:

```bash
make sync-contracts   # copia para ../worker e ../api
make diff-contracts   # acusa divergência
```

- `ssrf-vectors.json` — 47 vetores de IP e 18 sintáticos. A API valida sintaticamente na
  criação da URL; o Worker valida o IP realmente discado no `Dialer.Control`. As duas rodam
  **estes** casos, senão divergem.
- `openapi.yaml` — ainda não escrito. É contract-first: o CI da API valida as respostas contra
  ele e o CI do app gera os modelos a partir dele. É o próximo artefato da fase 0.

## Pendências

- O runner de migration ainda não foi escolhido. Hoje o `Makefile` aplica via `psql` em ordem.
  A escolha entre `golang-migrate`, `goose` e `dbmate` depende de um requisito concreto:
  `CREATE INDEX CONCURRENTLY` não roda dentro de transação, então o runner precisa permitir
  migration sem transação.
- Os documentos de decisão ainda estão em `../docs/` e `../db/PLANO.md`. O lugar deles é aqui.
- Backup, PITR e o drill de restore: `docs/runbooks/db-restore.md` está por escrever.
