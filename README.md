# icr — Interactive Crystal Shell

An irb-style console for Crystal:

```
⢀⡴⠊⢉⡟⢿  icr v1.1.0 - Crystal 1.21.0 - live interpreter
⣎⣀⣴⡋⡟⣻  "exit" to quit · ".program" session source · ".reset" clear
⣟⣼⣱⣽⣟⣾  ~/your/project
icr> 2 + 2
=> 4
# 0.2s
```

## Two backends

- **live** — a persistent `crystal i` interpreter process driven over a
  PTY: real in-process state, ~0.1–0.5s per line. Official Linux
  Crystal builds ship **without** interpreter support, so run
  `scripts/build-interpreter.sh` once to build a local compiler with
  `interpreter=1` into `~/.local/share/icr/` (nothing system-wide).
- **replay** — automatic fallback for stock compilers: every line
  recompiles and re-runs the whole session via `crystal run` (~1.5–3s
  per line). State "persists" because all previous lines are replayed;
  side effects (DB writes etc.) re-run on every submission.

The backend is picked automatically: `ICR_CRYSTAL` env var →
`CRYSTAL_INTERPRETER_PATH` env var →
`~/.local/share/icr/crystal/bin/crystal` → `crystal` from PATH
(usually falls through to replay). Both env vars are read directly
from Crystal code (`ENV[...]?` in `Icr.interpreter_bin`) at startup.

## Usage

```sh
bin/icr                          # or: crystal run src/cli.cr
ICR_CRYSTAL=/path/to/crystal bin/icr
CRYSTAL_INTERPRETER_PATH=/path/to/crystal bin/icr
```

Commands inside the console:

| command     | action                                   |
|-------------|------------------------------------------|
| `.program`  | print the session source so far          |
| `.reset`    | drop state (live: restart the process)   |
| `.exit` / `exit` / Ctrl+D | quit                       |

An incomplete line (`def f`, open blocks…) continues with `... >`
prompts until the expression is complete. In replay mode, end a line
with `\` to continue on the next one.

## As a library

Both sessions share one interface, and `Icr.open_session` picks the
best backend automatically — a live interpreter whenever one is
available (same chain as the CLI: `ICR_CRYSTAL` →
`CRYSTAL_INTERPRETER_PATH` → `~/.local/share/icr/…` → `crystal` on
PATH), replay otherwise. Works identically when icr is installed as
a shard into another app; the env vars are read from Crystal code at
call time, so the host app can set them before opening a session.

```crystal
require "icr"

session = Icr.open_session          # live if available, replay otherwise
puts session.submit("2 + 2")        # => "=> 4"
session.close
```

To control the backend explicitly:

```crystal
session = Icr::LiveSession.new(Icr.interpreter_bin.not_nil!)
```

## Notes

- Live backend: Linux and macOS (openpty via libutil; the interpreter
  builds from Crystal sources on both — see `scripts/build-interpreter.sh`).
  macOS is untested in this repo; on Windows there is no openpty, so icr
  runs in replay mode only (`crystal run` works everywhere Crystal does).
- The interpreter installs to `~/.local/share/icr/crystal` on every OS
  (the same path icr's loader checks).
- The PTY protocol quirks (paste threshold, window size, continuation
  prompts) are documented in `src/icr/live.cr`.
- Crystal >= 1.21.

## License

MIT
