# Automatizaciones por proyecto

Scripts locales **sin versionar** que reaccionan a los sobres del bus del agente (o a un horario) y publican sus
resultados como sobres nuevos. Se declaran en el perfil del proyecto (`~/.chopshop/profiles/<proyecto>.yaml`, bloque
`automations:`) y viven en `~/.chopshop/automations/<proyecto>/` (0700) junto a `state/` y `logs/`. Nada de esto entra
al repo. Código: `apps/agent/chopshop/agent/automations.py`.

> Modelo de confianza: scripts escritos por los agentes del dueño, como las reacciones. No es un sandbox contra scripts
> hostiles. El agente **no** tiene ninguna ruta HTTP para crear ni ejecutar scripts.

## Declaración

```yaml
automations:
  - name: triage
    on:                                   # uno o varios disparadores
      - type: github.issue.opened         # tipo de sobre (admite globs: github.issue.*, *)
        where:
          body.labels: {not: triaged}
      - type: schedule
        every: 6h                         # o cron: "0 9 * * 1-5" (5 campos, hora local de la máquina)
      - manual                            # `chopshop automation run <proyecto> <nombre>`
    run: [python3, triage.py]             # argv, sin shell
    cwd: .                                # relativo a ~/.chopshop/automations/<proyecto>/ (no puede salir de ahí)
    timeout: 120                          # s; por defecto 60, rango 1-900
    max_runs_per_hour: 30                 # por defecto 60
    concurrency: 1                        # 1-8; 1 = serializa y descarta duplicados por sujeto
    env: [GITHUB_REPO]                    # lista blanca de variables heredadas del agente
    secrets: [triage_token]               # archivos 0600 de ~/.chopshop/secrets/ -> TRIAGE_TOKEN_FILE=<ruta>
    emits: [triage.result]                # tipos que el script puede emitir (lista blanca)
    on_failure: {needs: bot}              # opcional: needs del automation.ran cuando falla
    enabled: true
```

`chopshop profile check <proyecto>` y `chopshop automation check` validan el bloque: `run` debe ser una lista argv
(un texto con shell se rechaza), `emits` no puede usar los espacios de nombres del agente (`task`, `question`,
`approval`, `batch`, `graph`, `node`, `reaction`, `machine`, `github`, `automation`, `agent`, `desk`, `office`, `forge`,
`listener`; la única excepción es `forge.dispatch`, que anuncia un `workflow_dispatch` para atribuir su run), `timeout` en rango,
`where` bien formado y disparadores conocidos (los tipos deben pertenecer a un espacio del agente o a algún `emits`
del perfil). `automation check` además mira la carpeta, el `cwd`, que el ejecutable exista en el PATH mínimo y los
secretos.

### `where`

Mapa `ruta: condición`; todas deben cumplirse. Rutas: `type`, `project`, `severity`, `needs`, `subject.<campo>`,
`body.<campo>` (con puntos para anidar).

| condición | significado |
|---|---|
| `valor` | igualdad (si el campo es una lista: la contiene) |
| `[a, b]` o `{in: [a, b]}` | alguno de los valores |
| `{not: <condición>}` | negación (un campo ausente cumple `not`) |
| `{regex: "^fix"}` | `re.search` sobre el texto del campo |

Varios operadores en el mismo mapa se combinan con «y».

### `schedule`

- `every`: `90s`, `30m`, `6h`, `1d` (mínimo 60 s).
- `cron`: 5 campos (`min hora día mes día-semana`, `*`, `a-b`, `*/n`, listas; domingo = 0 o 7). Si día y día-semana
  están restringidos a la vez basta con uno (como cron).
- La primera vez que el agente ve un horario solo lo siembra; si el agente estuvo caído, al volver dispara **una sola
  vez**. Los cursores viven en la tabla `meta` del agente.

## Ejecución

- `subprocess.Popen(argv, shell=False)` en su propio grupo de procesos, `stdin=/dev/null`.
- Entorno limpio: `PATH=/usr/local/bin:/usr/bin:/bin`, las variables de `env` que existan, `<SECRETO>_FILE` por cada
  secreto presente y `CHOPSHOP_EVENT_FILE` (sobre disparador en un JSON 0600 temporal; `{}` sin disparador),
  `CHOPSHOP_PROJECT`, `CHOPSHOP_AUTOMATION`. Nada más (ni `HOME`: añádelo a `env` si hace falta).
- Límites: `RLIMIT_CPU` = timeout + 5 s, `RLIMIT_AS` = 1 GB, `RLIMIT_NOFILE` = 256; stdout y stderr se guardan hasta
  256 KB cada uno (el resto se descarta y `truncated` queda en `true`).
- Timeout: SIGTERM al grupo, 5 s de gracia y SIGKILL. Al terminar (bien o mal) se manda SIGKILL al grupo: un script no
  deja procesos vivos. Un script que se escapa con `setsid` queda fuera de este control.
- `max_runs_per_hour` (ventana deslizante) y `concurrency` (hasta 20 en cola por automatización); lo que se pasa del
  tope se descarta y se cuenta (no se emite `automation.ran`).
- Interruptor global: `[agent.automations] enabled = false` en `config.toml`.

## Salida = sobres

El script escribe JSONL en stdout, una línea por evento:

```json
{"type": "triage.result", "severity": "notice", "needs": "bot", "subject": {"kind": "issue", "id": "o/r#42"}, "body": {"kind": "bug"}}
```

El runner completa `project` y `cause = {id: <sobre disparador>, depth: <depth del disparador> + 1}` y lo publica con
`events.emit_envelope` (contrato de `agent/envelope.py`), que valida el sobre y pone `v`, `id` (ULID), `seq`, `ts` y
`machine`. Se descartan (y cuentan) las líneas que no son JSON, las que no son un objeto, las de tipos fuera de `emits`
y las que el bus rechaza; `severity`/`needs` desconocidos pasan a `info`/`null`; un `subject` ausente o con `kind`
fuera del contrato se sustituye por `{kind: automation, id: <nombre>}`. Como mucho 100 sobres por ejecución. Si la ejecución vence el
timeout no se publica nada de su salida.

Siempre se emite un `automation.ran`:

```json
{"automation": "triage", "trigger": "github.issue.opened", "trigger_event": "01JC9...", "exit": 0, "duration_ms": 2310,
 "emitted": 1, "discarded": 0, "timed_out": false, "stdout_tail": "...", "stderr_tail": "...", "truncated": false, "error": null}
```

`severity: error` si `exit ≠ 0`, timeout o no se pudo ejecutar; `warn` si hubo líneas descartadas. `error` describe
el fallo y las líneas descartadas. Cada ejecución deja además una línea en `logs/<nombre>.log`.

### Anti-bucles

- Un sobre con `cause.depth >= 3` no dispara nada.
- Una automatización no se dispara con sus propios `emits` ni con su propio `automation.ran`.
- Solo escucha sobres de **su** proyecto.

## Hilo del agente

`chopshop-agent` corre el hilo `automations` (cada `[agent.automations] interval` s, por defecto 2): relee los perfiles
cada 60 s, lee los sobres nuevos del bus desde un cursor guardado en `meta` (una DB nueva empieza en la cabeza: no
reprocesa el historial) y revisa los horarios. Las ejecuciones corren en hilos propios; `stop()` espera a las que estén
en curso (cada una con su timeout).

## CLI

```
chopshop automation list [proyecto]
chopshop automation check [proyecto]
chopshop automation run <proyecto> <nombre> [--event-file sobre.json] [--dry-run] [--json]
chopshop automation logs <proyecto> [nombre] [-n 20]
chopshop automation add <proyecto> <nombre> --script archivo [--on github.issue.* --on every:6h --on 'cron:0 9 * * 1']
                        [--emits triage.result] [--timeout 60] [--append] [--force]
```

`run` ejecuta en el proceso de la CLI y publica en la DB del agente (SQLite WAL); con `--dry-run` solo imprime los
sobres. `add` copia el script a la carpeta del proyecto (0700) e imprime la declaración; con `--append` la añade al
perfil si aún no tiene `automations:` (y la revierte si el perfil queda inválido).

## Ejemplo: triage

`examples/automations/triage/` trae un perfil (`profile.yaml`, proyecto `demo`) y `triage.py`, que lee el sobre
disparador, clasifica el issue por palabras clave y emite `triage.result` con `needs: bot`:

```
cp examples/automations/triage/profile.yaml ~/.chopshop/profiles/demo.yaml
chopshop automation add demo triage --script examples/automations/triage/triage.py
chopshop automation check demo
chopshop automation run demo triage --event-file sobre.json --dry-run
```

## Relación con el contrato de sobre

El hilo lee sobres con `events.list_after` (ya traducidos desde nombres viejos por `envelope.from_legacy`) y publica con
`events.emit_envelope`. El anti-bucle propio (`cause.depth >= 3` no dispara) es más estricto que el del bus
(`depth > 3` se descarta), así que una cadena de automatizaciones nunca llega a ser rechazada por el bus.
