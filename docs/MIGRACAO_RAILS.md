# PRIMOCUT — Plano de Migração: Python/FastAPI/Svelte → Rails 8

> **Nota de idioma.** Por convenção do projeto, todo `.md` versionado é escrito em
> inglês (ver `AGENTS.md`). Este arquivo é uma **tradução autorizada** de
> `docs/RAILS_MIGRATION.md`, mantida em português como material de estudo. **A versão
> em inglês é a canônica**: em caso de divergência, ela vence — e esta deve ser
> atualizada.

## Contexto

O PRIMOCUT é uma PoC funcional construída como monólito Python: API FastAPI, SPA
Svelte 5, worker RQ, processo rq-scheduler e CLI Typer, todos compartilhando um único
núcleo de pipeline (`pipeline.py::run_stages`) sobre SQLite + Redis. O mapa completo
do sistema atual está em `docs/COMPONENTES.md`.

**Por que migrar.** O motivador principal é **aprender Rails 8** sobre uma base de
código real e não-trivial, que o autor já domina de ponta a ponta. A PoC é rica o
bastante para exercitar o framework inteiro (models, controllers, views, jobs,
tarefas recorrentes, manipulação de arquivos, adapters externos) — bom material de
aprendizado.

**Resultado pretendido.** Uma aplicação Rails 8 dona de tudo, exceto o que é
genuinamente preso a bibliotecas de ML em Python:

- **Rails 8** + **Hotwire** + **Tailwind CSS** no lugar de FastAPI + Svelte
- **PostgreSQL** no lugar do SQLite
- **Solid Queue** no lugar de RQ **e** rq-scheduler **e** Redis
- **RubyLLM** no lugar do cliente LLM multi-provider feito à mão
- Um **sidecar Python** enxuto (~584 LOC), mantido só para transcrição

### Decisões já tomadas

| Decisão | Escolha | Justificativa |
|---|---|---|
| Fronteira Python | Sidecar CLI, contrato JSON | Só a transcrição é realmente presa ao Python |
| Estratégia | Strangler fig, domínio a domínio | Sistema segue utilizável; ciclos de aprendizado curtos |
| Banco | PostgreSQL | `jsonb` para 10+ colunas de payload, concorrência de escrita, default do Rails |
| Schema | Redesenho idiomático + migração de dados | Não herda as convenções da PoC; ensina ActiveRecord de verdade |
| Fila | Solid Queue (via ActiveJob) | Default do Rails 8; remove o Redis por completo |
| GPU lock | Fila dedicada, concorrência 1 | Portável entre backends; espelha a semântica do `gpu.py` atual |
| Cálculo de métricas | Ruby (POROs); SQL só se medir lento | Igual ao desenho atual; mantém o banco trocável (§2.5) |
| Tratamento de erro | Exceções de domínio, capturadas no nível certo | Idiomático em Rails; espelha a resiliência atual (§2.6) |
| Tempo real | Polling primeiro, partials em tudo | Turbo Streams vira experimento deliberado depois |
| CLI | Mantida, como Thor/rake | Usada para testes, não para os fluxos de produto |

---

## 1. O que continua em Python, e por quê

Uma auditoria de todo import de terceiros e de cada entrada do `requirements.txt`
classificou o código em três grupos.

### 1.1 Genuinamente preso ao Python — **584 LOC**

| Arquivo | LOC | Dependência |
|---|---|---|
| `transcription/faster_whisper_engine.py` | 183 | faster-whisper (CTranslate2 + CUDA) |
| `transcription/whisperx_engine.py` | 153 | whisperx |
| `transcription/engine.py` | 26 | (protocolo) |
| `render/align.py` | 179 | alinhamento de palavras do whisperx |
| `render/align_worker.py` | 43 | whisperx (já é subprocesso) |

Essa é a **única** superfície Python que sobrevive.

### 1.2 Pacotes Python que **não** exigem cola em Python

- **yt-dlp** — já é invocado como subprocesso, não como biblioteca:
  `YTDLP = [sys.executable, "-m", "yt_dlp"]` (`download/audio.py:25`,
  `render/section.py:35`). Ruby chama o binário `yt-dlp` do mesmo jeito.
- **chat-downloader** — hoje usado como lib (`chat/downloader.py:21`), mas o pacote
  instala um **CLI** que emite JSON. Vira shell-out como os demais.
- **FFmpeg / NVENC** — já é `subprocess` puro. Todo o pacote `render/` (865 LOC) é
  orquestração de FFmpeg e porta para Ruby quase 1:1.

### 1.3 Substituídos por equivalentes Rails

`typer`/`rich` → Thor · `pydantic`/`pydantic-settings` → config + credentials do Rails ·
`anthropic` → RubyLLM · `fastapi`/`uvicorn` → Rails · `rq`/`rq-scheduler`/`redis` →
Solid Queue · `sqlalchemy` → ActiveRecord.

### 1.4 O contrato do sidecar

O padrão já existe no código: `render/align_worker.py` é um subprocesso em venv
separado, com contrato JSON e timeout matável. Generalizar num único binário fino:

```
primocut-engine transcribe --audio PATH --language pt --model large-v3-turbo --out OUT.json
primocut-engine align      --audio PATH --segments IN.json --out OUT.json
primocut-engine doctor     --json
```

Regras: stdout é **só JSON** (logs vão para stderr), saída não-zero significa falha
com corpo JSON de erro, e toda invocação é matável por timeout. Ruby nunca importa
Python — apenas executa um processo e lê um arquivo.

---

## 2. Arquitetura alvo

### 2.1 Processos

| Hoje | Amanhã |
|---|---|
| `primocut serve` (FastAPI + SPA) | `bin/rails server` |
| `primocut worker` (RQ) | `bin/jobs` (Solid Queue, filas default) |
| — | `bin/jobs --queue gpu` (concorrência **1** — o GPU lock) |
| `primocut scheduler` (rq-scheduler) | **eliminado** → tarefas recorrentes do Solid Queue (`config/recurring.yml`) |
| `primocut <admin>` (Typer) | `bin/primocut` (Thor) + rake tasks |
| Redis | **eliminado** |

> O Solid Queue tem tarefas recorrentes nativas, então o processo `scheduler`
> desaparece — os ciclos diário (`all`) e de 6h (`recent`) viram duas entradas em
> `config/recurring.yml`.

### 2.2 Separação de responsabilidades

Este é o coração da refatoração. O código atual mistura preocupações (`cli.py` tem
três papéis; `worker/queue.py` é um god-module de enfileiramento). A aplicação Rails
impõe camadas estritas:

```
app/
  models/          ActiveRecord: persistência, associações, scopes, validações.
                   Sem orquestração, sem chamada externa.
  services/        Operações de domínio, agrupadas POR DOMÍNIO (não por tipo técnico).
                   Objetos Ruby puros. É aqui que a lógica de verdade mora.
  jobs/            ActiveJob: finos. Parse de args → chama service → reporta progresso.
                   Nunca contêm regra de negócio.
  adapters/        O mundo externo, uma classe por dependência externa.
                   Substituíveis e falsificáveis em teste.
  controllers/     Finos: params → service → render. Sem lógica.
  views/           ERB + Hotwire. Tudo é partial (ver §2.7).
```

**Services, por domínio** — espelham os domínios que já existem na PoC:

| Namespace | Substitui | Responsabilidade |
|---|---|---|
| `Pipeline::` | `pipeline.py`, `worker/jobs.py` | Orquestração dos stages de uma live |
| `Competitors::` | `worker/snapshot_jobs.py`, `channel_jobs.py`, `channels.py`, `event_emission.py`, `comment_collection.py` | Registro de canal, ciclos de snapshot, emissão de eventos |
| `Metrics::` | `metrics/` (2219 LOC) | Score de outlier, bandas, padrões, impacto — computados na leitura |
| `Cuts::` | `worker/render_jobs.py`, `export_jobs.py`, `packaging_jobs.py` | Render, export, packaging |
| `Enrichment::` | `worker/enrich_jobs.py`, `metrics/enrichment.py` | Enriquecimento opt-in via LLM |

**Adapters, um por dependência externa:**

| Adapter | Encapsula | Substitui |
|---|---|---|
| `Adapters::Ytdlp` | binário `yt-dlp` | `download/audio.py`, `render/section.py` |
| `Adapters::Ffmpeg` | `ffmpeg`/`ffprobe` | `render/encode.py`, `frames.py`, `package.py` |
| `Adapters::TranscriptionEngine` | sidecar `primocut-engine` | `transcription/` |
| `Adapters::YoutubeApi` | YouTube Data API (Faraday) | `youtube/client.py` |
| `Adapters::Llm` | RubyLLM | `analysis/llm.py` |
| `Adapters::ChatDownloader` | CLI do `chat_downloader` | `chat/downloader.py` |

### 2.3 Preservar as duas invariantes

A PoC tem duas regras que precisam sobreviver à migração — são a razão de ela
funcionar:

1. **Um único núcleo de pipeline.** `run_stages` é o único lugar onde a ordem dos
   stages existe. Em Rails vira `Pipeline::Runner`, chamado **tanto** pelo job
   **quanto** pela CLI. O seam de injeção `Store`/`ProgressReporter` vira um
   **argumento `reporter`**: `Pipeline::DbReporter` (grava progresso) vs.
   `Pipeline::LogReporter` (CLI). A persistência é sempre ActiveRecord. **Nunca
   duplicar a lógica de stage.**

2. **A regra de ouro da análise.** O LLM devolve **índices** de segmento, nunca
   timestamps; a resolução índice→tempo é clampada a segmentos reais
   (`models.py::resolve_span`). Isso vira `Analysis::SpanResolver` e deve ser o único
   caminho da saída do modelo até o tempo. Ver o risco do RubyLLM na §5.

### 2.4 Princípios de design (calibrados, não dogmáticos)

A PoC **já pratica inversão de dependência**: 51 pontos de injeção (`metadata_fn`,
`download_audio_fn`, `store`, `reporter`, `engine`, `llm`, `gpu_lock`,
`thumbnail_fetcher`, …) e 9 classes fake na suíte de testes, que roda sem GPU e sem
rede. **Essa é a propriedade mais valiosa a carregar para o Rails.** Não é uma
disciplina nova a aprender — é uma a não perder.

**SOLID, ponderado para esta base de código:**

| | Peso | Aplicado a |
|---|---|---|
| **SRP** | **Alto** | A cura direta do `cli.py` (3 papéis) e do `worker/queue.py` (god-module de enqueue). Um service = uma operação de domínio. |
| **OCP** | Baixo | Sem pontos de extensão especulativos. Abra a classe quando o **segundo caso real** aparecer. |
| **LSP** | Médio | Adapters. Já presente: `TranscriptionEngine` é um protocolo com duas implementações intercambiáveis. |
| **ISP** | Médio | O seam do reporter. `ProgressReporter` é mínimo — por isso as duas implementações são triviais. |
| **DIP** | **Alto** | Já praticado. Portar como injeção via construtor, com defaults sensatos. |

**Convenções:**

- Services expõem **um método público** (`call`); dependências chegam pelo
  construtor com defaults reais, então o código de produção fica limpo e os testes
  injetam fakes.
- **Comentários explicam o *porquê*, nunca o *o quê*.** Os docstrings atuais são, em
  sua maioria, do tipo valioso — ex.: `worker/event_emission.py` explica por que
  `outlier_crossed` só dispara em transição para uma banda estritamente superior.
  Apagar narração; **preservar racional**. Perder esses comentários reintroduziria
  bugs já resolvidos.
- **DRY sob KISS.** Duplicação é mais barata que a abstração errada. Abstraia na
  terceira repetição *que compartilha uma razão para mudar*, não na segunda.
- Sem Repository por cima do ActiveRecord (§2.5). Sem Result objects por padrão (§2.6).

### 2.5 Abstração de banco: raio de explosão limitado, não custo zero

**O ActiveRecord já é a abstração de banco.** Colocar um Repository em cima dele
duplica uma abstração do framework — a definição de over-engineering.

A portabilidade vem de uma decisão de desenho: **o cálculo mora em Ruby, o banco só
armazena.** Isso espelha o que a PoC já faz — a matemática de percentis roda em
código de aplicação hoje (`metrics/core.py:166`, `nearest_rank_percentile` ordena
listas em Python), não em SQL. Mantendo isso:

- os services de `Metrics::` são POROs, testados sem banco;
- o SQL permanece portável (`SELECT` simples + índices);
- o Postgres continua sendo a escolha certa — `jsonb`, concorrência de escrita,
  default do Rails — mas sem prender o projeto.

Se algum dashboard se provar lento com volume real, **aquela query específica** vai
para um query object com SQL específico do banco. O acoplamento entra então **por
decisão e num lugar visível**, nunca por acidente. A meta não é troca gratuita de
banco (isso é ficção); é um conjunto de arquivos conhecido, pequeno e localizável.

### 2.6 Tratamento de erros: exceções, capturadas no nível certo

Exceções de domínio, numa hierarquia pequena — idiomático em Rails, e compõe com o
ActiveRecord, que levanta. Result objects **não** são adotados por padrão: adicionam
cerimônia em cada ponto de chamada e exigem embrulhar toda chamada de AR. Eles servem
a falhas que são resultados de negócio esperados e ramificáveis; as falhas do
PRIMOCUT (rede caiu, vídeo removido, FFmpeg quebrou, fila inacessível) são
genuinamente excepcionais.

Existe **um** modelo de erro; só o ponto de captura muda com o contexto — exatamente
o modelo que a PoC já usa:

- **Caminho de request** — a falha é terminal para o request → captura na borda
  (`rescue_from` → 404/422). Espelha o `KeyError → 404`, `QueueUnavailableError` e
  `VideoBusyError` de hoje.
- **Jobs em lote** — a falha é *dado sobre um item* → captura por item, persiste
  `state: :error` com a mensagem, o lote continua. Espelha o isolamento por item de
  `worker/render_jobs.py` e `worker/enrich_jobs.py`.

### 2.7 Views: partials primeiro

Toda view é composta de partials desde o dia um, porque **partial é a unidade que
polling e broadcast compartilham**. Começa com o comportamento atual (Turbo Frames
com `refresh`, equivalente ao polling de ~2s de hoje). Depois, migrar uma tela para
Turbo Streams é adicionar um `broadcast_replace_to` no job — **sem tocar na view**.
Isso transforma a comparação de tempo real num experimento controlado, não numa
reescrita.

---

## 3. Redesenho do schema

25 tabelas saem do SQLite para o PostgreSQL com convenções Rails aplicadas:

- **Chaves primárias**: `videos.id` hoje é o ID do YouTube (string). Vira
  `id: bigint` + `youtube_id: string` com índice único. Idem para
  `competitor_channels` (`UC…`) e `competitor_videos`.
- **JSON → `jsonb`** em todas as 10+ colunas de payload (`events.payload`,
  `jobs.warnings`, `jobs.stage_history`, `transcripts.segments`,
  `chat_signals.per_minute`/`peaks`, `video_attributes.attributes`, …), com índices
  GIN onde houver consulta.
- **Foreign keys reais + associações** no lugar de joins implícitos, para
  `belongs_to`/`has_many` funcionarem sem gambiarra.
- **Timestamps**: `created_at`/`updated_at` em tudo.
- **Migrations SQL escritas à mão** (`db/migrations/002…010`) viram migrations Rails;
  o histórico **não** é reproduzido — o schema redesenhado é a nova baseline.

### A consequência para o strangler (importante)

Redesenhar o schema significa que Rails e Python **não podem compartilhar banco**. O
strangler então roda como **sistemas paralelos com bancos independentes**, e não como
proxy sobre banco compartilhado:

- A aplicação Python segue rodando, intocada, sobre o SQLite dela.
- Um **importador idempotente e re-executável** (`rake primocut:import_legacy`) lê o
  arquivo SQLite e popula o Postgres.
- Re-execute o importador sempre que quiser dados frescos no Rails, até o cutover.
- O cutover é **por domínio**: quando um domínio funciona no Rails, pare de usá-lo no
  Python.

Isso é viável **especificamente** porque o PRIMOCUT é uma PoC pessoal de usuário
único — não há escrita concorrente a reconciliar.

---

## 4. Fases da migração

Ordenadas para que cada fase seja útil por si só, com a dificuldade subindo junto com
a fluência em Rails.

### Fase 0 — Spikes de risco (fazer primeiro)

Experimentos descartáveis que eliminam as três incógnitas antes de qualquer
compromisso:

1. ~~**Forced tool use no RubyLLM**~~ — **FEITO, passou.** Resultados na §5.1.
2. ~~**Sidecar Python**~~ — **FEITO, passou.** Resultados na §5.2.
3. ~~**Job longo no Solid Queue**~~ — **FEITO, passou.** Resultados na §5.3.

### Fase 1 — Fundação

- `rails new` (Rails 8, Postgres, Tailwind, Propshaft, Solid Queue).
- Schema completo como migrations Rails (§3); models ActiveRecord com associações,
  scopes e validações.
- `rake primocut:import_legacy` — o importador idempotente SQLite → Postgres.
- Layout, navegação e design system Tailwind, respeitando a IA atual (Radar/Activity
  globais, acima de Lives/Niche/Settings por projeto).

**Foco de aprendizado:** migrations, associações, scopes.

### Fase 2 — Nicho e métricas (fatia somente-leitura)

A fatia mais segura: **leitura pura, sem jobs, sem chamadas externas.**

- Portar `metrics/` (2219 LOC) para services `Metrics::` — score, régua de bandas,
  percentis, padrões, impacto. Tradução direta de algoritmo, fácil de testar.
- Controllers + views Hotwire para Radar, Activity, Niche (patterns/outliers/
  channels), dashboard de canal e detalhe de vídeo.
- Referência: `metrics/service.py` já monta exatamente esses payloads de dashboard.

**Foco de aprendizado:** queries ActiveRecord, controllers, views, Tailwind.

### Fase 3 — Coleta de concorrentes (jobs + recorrência)

- `Adapters::YoutubeApi` (contabilização de quota preservada).
- `Competitors::SnapshotCycle` como ActiveJob; as cadências diária (`all`) e de 6h
  (`recent`) viram entradas em **`config/recurring.yml`** — o processo scheduler some.
- Portar a emissão de eventos (incluindo a guarda anti-flapping do `outlier_crossed`,
  que depende de `last_band_emitted`) e a coleta de comentários.
- Registro de canal + backfill.

**Foco de aprendizado:** ActiveJob, Solid Queue, tarefas recorrentes, adapters HTTP.

### Fase 4 — Pipeline de lives (a fronteira do sidecar)

- `Adapters::Ytdlp`, `Adapters::ChatDownloader`; z-score do chat em Ruby
  (`chat/signals.py` é pequeno e puro).
- `Adapters::TranscriptionEngine` → o sidecar Python, na fila `gpu`.
- `Pipeline::Runner` — o núcleo único de stages, com o seam do reporter (§2.3).
- Lista de lives + submissão + UI de progresso ao vivo.

**Foco de aprendizado:** adapters de shell-out, orquestração de jobs, progresso.

### Fase 5 — Cut Room (maior superfície)

- `Adapters::Ffmpeg`; portar `render/` (865 LOC) — download de seção, encode, frames,
  package/export. Majoritariamente mecânico.
- Services `Cuts::`: render (isolamento por item + cache pay-once por `params_hash`),
  export (clips + SRT + master concatenado + manifests), packaging (títulos, briefs de
  thumbnail, extração de frames, ranking por visão, audience match) via RubyLLM.
- UI do Cut Room — a maior unidade de interface (`CutRoom.svelte`, 764 LOC)
  reconstruída em Hotwire.

**Foco de aprendizado:** formulários complexos, recursos aninhados, download de
arquivos, Turbo.

### Fase 6 — CLI, cutover, desativação

- `bin/primocut` (Thor) para os fluxos de teste que você realmente usa, mais rake
  tasks; `doctor` vira rake task validando GPU, FFmpeg, yt-dlp, sidecar, chave de LLM
  e banco.
- Apagar a aplicação Python exceto o sidecar; remover o Redis; arquivar `frontend/`.
- Atualizar `AGENTS.md`, `README.md`, `docs/DEVELOPMENT.md`, `docs/COMPONENTES.md`.

---

## 5. Riscos

| Risco | Impacto | Mitigação |
|---|---|---|
| ~~RubyLLM pode não suportar tool use *forçado*~~ | — | **RESOLVIDO** pelo spike da Fase 0 — ver §5.1. |
| Solid Queue é mais novo que Sidekiq para jobs de horas | Perda de job ou timeout inesperado | Spike da Fase 0; a transcrição é processo externo matável; o ActiveJob mantém a saída para Sidekiq a uma linha de config |
| Redesenho de schema impede strangler com banco compartilhado | Dados divergentes durante a migração | Importador idempotente re-executável; PoC de usuário único torna isso seguro (§3) |
| Porte de `metrics/` introduzir desvio numérico sutil | Bandas de outlier erradas, silenciosamente | Portar as fixtures da suíte Python como fixtures Rails; comparar a saída dos dois sistemas sobre o mesmo dataset importado |
| Cut Room é a maior unidade isolada | Fase 5 empacar | Está deliberadamente por último, quando a fluência em Rails/Hotwire é máxima |

### 5.1 Resultado do spike — forced tool use no RubyLLM (**passou**)

Executado contra a API real da Anthropic com `claude-sonnet-5`, RubyLLM 1.16.0,
Ruby 4.0.1.

**Forced tool use é suportado.** `chat.with_tool(tool, choice: :nome_da_tool)` mapeia
para `tool_choice: {type: "tool", name: …}` da Anthropic — exatamente o mecanismo do
qual `analysis/llm.py` depende. Escolhas válidas: `:auto`, `:none`, `:required`, ou o
nome de uma tool específica.

**O schema fixa os tipos.** Um bloco `params` declarando `integer :start_index`
devolveu `Integer` do Ruby em todos os casos — **inclusive num prompt adversarial**
que exigia explicitamente timestamps em `MM:SS` e um parágrafo de prosa antes. O
schema da tool venceu a instrução.

**`Tool::Halt` mantém uma única ida e volta.** Retornar `RubyLLM::Tool::Halt` do
`execute` para o loop agêntico, então a extração estruturada custa **uma** chamada de
API (trace: `user → assistant[tool_call] → tool`, 1 turno de assistant) — paridade de
custo com a implementação Python atual.

**O que o spike NÃO provou.** A tentativa de induzir índices fora de faixa (pedir 6
tópicos num transcript de 7 segmentos, sugerindo índices como 20/50/99) foi
**resistida pelo modelo** — ele devolveu índices válidos. Isso é tranquilizador, mas
**não é garantia**: `integer` no JSON Schema não carrega restrição de faixa, então
nada impede estruturalmente um índice alucinado. **O `Analysis::SpanResolver` precisa
continuar clampando para segmentos reais e permanecer a autoridade final**, exatamente
como `models.py::resolve_span` faz hoje.

**Dois achados operacionais:**

- **O registro de modelos embutido fica desatualizado.** `claude-sonnet-5` era
  desconhecido para o RubyLLM 1.16.0 e levantou `ModelNotFoundError`;
  `RubyLLM.models.refresh!` (que busca do provider) resolveu. Uma instalação limpa em
  produção vai esbarrar nisso — fazer refresh no boot, ou persistir um registro com
  `save_to_json` e versioná-lo.
- **`temperature` foi descontinuado no `claude-sonnet-5`.** O RubyLLM repassa o
  parâmetro e a API rejeita com `BadRequestError`. Não usar `with_temperature` nesse
  modelo.

Formato de referência para o `Adapters::Llm`:

```ruby
class SelectTopics < RubyLLM::Tool
  description "Return the macro topics found in the transcript."
  params do
    array :topics, required: true do
      object do
        string  :title,       required: true
        integer :start_index, required: true
        integer :end_index,   required: true
      end
    end
  end

  attr_reader :captured

  def execute(topics:)
    @captured = topics
    RubyLLM::Tool::Halt.new("captured")   # uma única ida e volta
  end
end
```

### 5.2 Resultado do spike — fronteira do sidecar Python (**passou**)

Ruby 4.0.1 dirigindo o venv do projeto (Python 3.13.5, faster-whisper 1.2.1) numa
RTX 3070 Ti sob WSL2, com o modelo real `large-v3-turbo`.

| Teste | Resultado |
|---|---|
| `doctor` → envelope JSON | passou |
| `transcribe` → execução real na GPU dirigida pelo Ruby | passou — load 3.59s, total 4.23s |
| Timeout mata o **grupo de processos** | passou — processos de compute no `nvidia-smi` antes=0 depois=0, **sem órfão** |
| Propagação estruturada de erro (áudio inexistente) | passou — exit não-zero + `{"error": …}` → `TranscriptionError` |
| 500 linhas de ruído no stderr | passou — JSON do stdout intacto |

**O achado que importa.** A primeira execução **falhou** com
`Library libcublas.so.12 is not found or cannot be loaded` — mesmo com as libs
presentes no venv e com o modelo carregando normalmente quando invocado direto. A
causa é o `_preload_cuda_libs()` em `transcription/faster_whisper_engine.py:20`: sob
WSL2 o runtime CUDA vem via pip e **não** está no `LD_LIBRARY_PATH`, então as libs
precisam ser carregadas com `RTLD_GLOBAL` via `ctypes` antes que o ctranslate2
consiga resolvê-las por soname. Um porte ingênuo perde isso silenciosamente e o
sidecar simplesmente não usa a GPU.

Duas consequências para o plano:

1. **O sidecar é dono do próprio ambiente CUDA.** O processo Rails nunca deve
   precisar de variáveis de ambiente de CUDA — portar `_preload_cuda_libs` para o
   entry point do sidecar é obrigatório, não opcional.
2. **Generalize a lição.** Esse é exatamente o tipo de conhecimento de produção,
   pago com dor, que vive nos comentários de *porquê* (§2.4). Ao portar qualquer
   módulo, leia primeiro os comentários de racional — eles codificam falhas já pagas.

**Decisões de contrato validadas:**

- **O payload vai para `--out ARQUIVO`, não para o stdout.** Um transcript de 4h são
  megabytes de JSON; um pipe pode bloquear se o leitor não drenar. O stdout carrega
  só um envelope de status pequeno.
- **O Ruby precisa drenar stdout/stderr em threads** e fazer spawn com
  `pgroup: true`, matando com `Process.kill("-KILL", pgid)`. Matar só o pai deixaria
  um processo CUDA segurando a GPU — exatamente a falha que o lock do `gpu.py` existe
  para evitar hoje.

**Não validado:** a *qualidade* da transcrição — o spike usou áudio sintético (1
segmento). O faster-whisper em si é código de produção inalterado; o que era novo, e
agora está provado, é a fronteira.

### 5.3 Resultado do spike — Solid Queue (**passou**)

Rails 8.1.3, Ruby 4.0.1. Tempos comprimidos (`process_alive_threshold` de 10s em vez
dos 5min padrão, heartbeat de 2s) para tornar o comportamento de "processo morto"
observável em segundos.

| Teste | Resultado |
|---|---|
| Job longo vs. staleness — 30s sob limiar de 10s | passou — **executou exatamente uma vez**, sem duplicata |
| Fila `gpu`, `threads: 1` — 3 jobs | passou — estritamente sequencial, mesmo PID, sem sobreposição |
| Progresso lido de **outro processo** durante a execução | passou — 20→40→60→80→100% |
| Tarefas recorrentes (`config/recurring.yml`, `every 5 seconds`) | passou — 4 disparos em 20s, pontuais |

**O risco principal não se materializou.** Um job rodando 3× mais que o limiar de
processo vivo **não** foi considerado morto nem re-enfileirado — o heartbeat do Solid
Queue roda em thread própria, independente da execução do job. Isso importa porque uma
transcrição duplicada significaria dois processos disputando uma GPU.

**O GPU lock é só configuração de fila.** Uma fila `gpu` com `threads: 1,
processes: 1` no `config/queue.yml` serializa exatamente como o lock em Redis do
`gpu.py` hoje — sem código de lock para escrever, e portável para o Sidekiq se um dia
for preciso:

```yaml
workers:
  - queues: "default"
    threads: 3
  - queues: "gpu"        # uma transcrição por vez (substitui gpu.py)
    threads: 1
    processes: 1
```

**O processo scheduler está confirmadamente eliminado.** O `config/recurring.yml`
disparou pontualmente e persistiu em `solid_queue_recurring_tasks`. Os ciclos diário
(`all`) e de 6h (`recent`) viram duas entradas YAML — `primocut scheduler` e o
`rq-scheduler` somem juntos.

**O Rails 8 já traz o Solid Queue.** O `rails new` gerou `config/queue.yml`,
`config/recurring.yml`, `db/queue_schema.rb` e `bin/jobs` sem gem adicional. Vem
habilitado só para produção; em desenvolvimento é preciso
`config.active_job.queue_adapter = :solid_queue`, mais uma entrada `queue` no
`database.yml` e `config.solid_queue.connects_to`.

**Ressalvas — o que este spike NÃO provou:**

- **Rodou em SQLite, não em PostgreSQL.** O Postgres **não está instalado** nesta
  máquina (sem `psql`, e sem `libpq-dev`, então a gem `pg` nem compila). O ciclo de
  vida de job do Solid Queue independe do backend, então os resultados se transferem —
  mas a concorrência de escrita do Postgres sob carga real de worker+web segue não
  verificada. Instalar Postgres e `libpq-dev` é pré-requisito da Fase 1.
- **Tempos comprimidos, não uma execução longa real.** O mecanismo está provado; uma
  transcrição de várias horas sob os limiares padrão não foi executada.

---

## 6. Verificação

**Por fase:**

- **Testes Rails** para cada service portado, usando fakes nos adapters — a suíte
  atual já prova que esse desenho funciona (roda sem GPU e sem rede).
- **Paridade numérica** na Fase 2: rodar `primocut metrics show --project N` (Python)
  e o equivalente Rails sobre os mesmos dados importados; diff do JSON. Limiares de
  banda, percentis e vereditos de outlier devem bater exatamente.
- **Paridade de pipeline** na Fase 4: processar uma live curta nos dois sistemas;
  comparar contagem de segmentos do transcript, minutos de pico do chat e spans dos
  tópicos.
- **Smoke test manual** de cada tela conforme ela nasce (a UI atual também não tem
  cobertura automatizada — ver `docs/DEVELOPMENT.md` §2.9).

**Ponta a ponta, antes de desativar o Python:**

1. `rake primocut:import_legacy` sobre uma cópia do SQLite real.
2. Registrar um canal concorrente → backfill roda → dashboards populam.
3. Deixar um ciclo de snapshot recorrente disparar → eventos aparecem no Radar.
4. Submeter uma live real → pipeline completa → transcript + picos de chat + tópicos.
5. Montar um cut → render → export → baixar o bundle; abrir no CapCut.
6. `rake primocut:doctor` passa num ambiente limpo.

---

## 7. Pontos em aberto

- **Tempo real**: experimento futuro designado — comparar polling com Turbo Frames
  vs. broadcasting com Turbo Streams sobre os mesmos partials (§2.7).
- **Produção**: hoje é local (workstation com GPU). Um deploy futuro precisa decidir
  onde o sidecar de GPU roda — mesmo host, ou separado com o sidecar atrás de uma
  fila numa máquina com GPU.
- **Autenticação**: inexistente hoje (usuário único). O Rails 8 traz um generator
  quando multiusuário virar realidade.

---

*Documento companheiro: `docs/COMPONENTES.md` mapeia o sistema Python atual do qual
este plano migra. Versão canônica em inglês: `docs/RAILS_MIGRATION.md`.*
