# monitor-infra

Schema, ambiente local e contratos compartilhados do monitor de uptime.

Com três repos de código independentes, **o banco é a única superfície comum entre a API e o
Worker** — por isso ele é escrito aqui, e não dentro de um dos dois. Nenhum serviço cria ou
altera tabela em runtime.

## Subir o ambiente

Requer Docker (ou Podman com `COMPOSE=podman-compose`) e Go 1.23+.

```bash
cp .env.example .env    # e troque as três MONITOR_*_PASSWORD
make bootstrap          # do zero, e verificado
```

`make bootstrap` é `reset` (nuke → up → migrate → seed → verify) mais `test-permissions` e
`test-login`. Passo a passo, se preferir:

```bash
make up        # Postgres 16 + alvos locais, espera ficarem saudáveis
make migrate   # River → migrations 001→012 → senhas dos papéis
make seed      # time, usuário e monitores de desenvolvimento
make verify    # PORTÃO: invariante quebrada faz o psql sair 3
```

**`make migrate` ordena o River sozinho**, e isso é a correção de um defeito real: a 012
concede privilégios sobre as tabelas que a CLI do River cria, e `GRANT ... ON ALL TABLES`
sobre um schema vazio é um no-op **legal**. Rodando fora de ordem, a migration "passava" e a
falha só aparecia no boot do worker, como `permission denied for table river_job`. Hoje a 012
**recusa** rodar sem as tabelas, e o alvo `migrate` encadeia
`river → migrate-up → roles-pw`.

`make help` lista os alvos. `make check` roda as consultas de operação — atraso de
agendamento, lease órfão, resultados zumbi, divergência de estado, compras pendentes de
acknowledge.

## Os três portões

Nenhum deles é relatório: todos saem diferente de zero quando reprovam.

| Alvo | Prova |
|---|---|
| `make verify` | as invariantes do schema, **incluindo os GRANT por coluna** — que a API não escreve `current_status`, que o Worker não escreve `name`, que `teams` só aceita UPDATE por coluna, que o worker consome toda tabela do schema `river`, e que toda partição nasce à meia-noite UTC |
| `make test-permissions` | os mesmos GRANT, mas **conectando como os papéis reais**: privilégio negado de verdade, a receita de IDs reservados criando o primeiro usuário, `INSERT INTO urls` sem `unknown_reason`, a API enfileirando no River, o trigger recusando o worker limpar `config_error`, e partições criadas sob fusos diferentes com limites idênticos |
| `make test-login` | que as senhas do `.env` viraram as senhas dos papéis — por TCP a partir de um segundo container na rede Compose, com controle negativo: senha errada **tem** que ser recusada |
| `make test` | contratos, ciclo completo `up → down → up`, invariantes e permissões em projeto, portas e volume Docker isolados; o ambiente de teste é removido mesmo se houver falha |

Vale ver cada um vermelho uma vez. Portão que nunca reprovou não é portão:

```bash
docker compose exec -T postgres psql -U monitor -d monitor \
  -c 'GRANT UPDATE ON teams TO monitor_api'
make verify    # sai 3, apontando "api NÃO escreve teams.created_at"
```

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
| 012 | privilégios do schema `river` — **recusa rodar antes de `make river`** |

**As migrations são SQL puro, sem meta-comando de psql.** Não é estética: o runner
`golang-migrate` e o harness de teste da API não executam `\set`, `\if` nem `\gset`. Um
único meta-comando aqui e a suíte da API não consegue mais
aplicar o schema. Por isso as senhas dos papéis moram em `db/roles-pw.sql`, fora desta pasta —
lá o psql é o único consumidor e meta-comando é permitido.

**O `down` existe para desenvolvimento local.** Produção é forward-only: correção lá é uma
migration nova, para frente. Nunca renomear nem remover coluna em um passo.

`make migrate` é incremental e reexecutável pelo `golang-migrate`: a tabela
`schema_migrations` registra a versão e o estado `dirty`. `make version` consulta esse
estado; `make migrate-force VERSION=N` é recuperação manual, não fluxo normal. O caminho
suportado para reconstruir o ambiente local continua sendo `make reset`.

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
- `openapi.yaml` — contrato da fase 1, escrito à mão e **antes** do código. O CI da API valida
  cada resposta da suíte contra ele (`kin-openapi`), e o CI do app gera os modelos Dart a
  partir dele. Cobre auth, `/v1/me`, dashboard, o CRUD de URLs, histórico, incidentes,
  devices, inbox e preferências. Times, billing e exclusão de conta entram por PR nas fases 5
  e 6.

  Ele **não** é copiado para os repos irmãos pelo `sync-contracts`, ao contrário dos vetores
  de SSRF: a suíte da API o lê deste diretório (`MONITOR_INFRA_DIR`) e o app gera a partir
  daqui. Uma cópia seria mais uma superfície para divergir.

  Duas armadilhas já pagas, para quem for editar:

  - **não** adicione um bloco `servers`, nem `- url: /`. O router do `kin-openapi` consome o
    prefixo do servidor antes de casar o caminho, e a suíte inteira passa a falhar com "rota
    ausente no OpenAPI";
  - toda operação declara `default` com o envelope de erro. Sem isso o validador **aceita em
    silêncio** qualquer status não documentado — um 500 com corpo em texto passaria por
    resposta válida.

## Pendências

- **`monitor_migrate` é decorativo hoje, e isso tem prazo.** Ele é criado, recebe senha e fuso,
  e não recebe privilégio nenhum: quem aplica as migrations é o superusuário de
  `DATABASE_URL_MIGRATE`. Em produção isso significa migrar com uma credencial capaz de
  qualquer coisa no cluster.

  **Gatilho: logo após o primeiro `make bootstrap` verde.** A separação foi adiada de
  propósito, e não por esquecimento — fazer redesenho de privilégio na mesma rodada da
  primeira execução de um schema que nunca rodou confunde duas fontes de falha: quebrando,
  não se sabe se foi o schema ou a troca de papel. O `make test-login` já cobre o
  `monitor_migrate`, então a credencial dele estará provada quando a hora chegar.

  O desenho já levantado, para quando for feito: `001` cria `pg_stat_statements`, que **não**
  é extensão *trusted* e exige superusuário, e `011` faz `CREATE ROLE`, que exige superusuário
  ou `CREATEROLE`. As demais rodam como `monitor_migrate` se ele tiver `CREATE` no schema
  `public`. Então: bootstrap superusuário mínimo (extensões + papéis), resto sob
  `monitor_migrate`, e `DATABASE_URL_MIGRATE` repontuada. Ganho colateral relevante — as
  funções `SECURITY DEFINER` da `004` hoje pertencem ao superusuário, o que dá ao Worker DDL
  de superusuário através delas; passando a ser de `monitor_migrate`, o privilégio efetivo cai
  para o necessário.
- `RIVER_VERSION` está pinado no `Makefile`. Subir é decisão consciente: a 012 concede
  privilégio tabela a tabela, e um upgrade que cria tabela nova depende do
  `ALTER DEFAULT PRIVILEGES` que ela instala.
- Os documentos de decisão ainda estão em `../docs/` e `../db/PLANO.md`. O lugar deles é aqui.
- Backup, PITR e o drill de restore: `docs/runbooks/db-restore.md` está por escrever.
