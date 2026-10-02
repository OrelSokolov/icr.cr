# icr — Interactive Crystal Shell
#
# An irb-style console for Crystal with two interchangeable backends:
#
#   live    — Icr::LiveSession: a persistent `crystal i` interpreter
#             process driven over a PTY. Real state, instant answers
#             (~0.1-0.5s per line). Requires a compiler built WITH
#             interpreter support (official Linux builds ship WITHOUT
#             it! — run scripts/build-interpreter.sh to make one).
#   replay  — Icr::ReplaySession: fallback; every line recompiles and
#             re-runs the whole session via `crystal run`. State
#             "persists" because all previous lines are replayed
#             (~1.5-3s per line).
#
# Both sessions implement the same tiny interface:
#   submit(line) -> String   rendered output ("=> value" like irb)
#   reset        -> String   drop state
#   program_source -> String session source so far
#   close                   teardown (live backend)

require "./icr/pty"
require "./icr/live"
require "./icr/replay"
require "./icr/editor"
require "./icr/completion"
require "./icr/completion_index"

module Icr
  VERSION = "1.6.0"

  # Where the live backend's compiler comes from, in order:
  #   1. ICR_CRYSTAL env var (explicit override)
  #   2. CRYSTAL_INTERPRETER_PATH env var (checked from Crystal code
  #      at startup via ENV — no Rakefile needed)
  #   3. ~/.local/share/icr/crystal/bin/crystal (scripts/build-interpreter.sh)
  #   4. `crystal` from PATH (usually lacks interpreter support; the
  #      CLI then falls back to replay mode)
  def self.interpreter_bin : String?
    if env = ENV["ICR_CRYSTAL"]? || ENV["CRYSTAL_INTERPRETER_PATH"]?
      return File.exists?(env) ? env : nil
    end

    home = ENV["HOME"]? || "/root"
    local = File.join(home, ".local/share/icr/crystal/bin/crystal")
    return local if File.exists?(local)

    "crystal"
  end

  # Library-friendly entry point: open the best available session —
  # a LiveSession when interpreter_bin resolved to an interpreter-
  # capable crystal (env vars → ~/.local/share/icr → PATH), a
  # ReplaySession otherwise. This is the same logic the CLI uses, so
  # shard consumers always get the live interpreter by default when
  # one is present. Env vars are read at call time: host apps can set
  # ENV["CRYSTAL_INTERPRETER_PATH"] (or ICR_CRYSTAL) in their own
  # code before calling this.
  #
  # Pass replay: true to skip the interpreter entirely (the CLI's
  # --replay flag): always a ReplaySession, no fallback warnings.
  def self.open_session(cwd : String? = nil, replay : Bool = false) : LiveSession | ReplaySession
    return ReplaySession.new if replay
    if bin = interpreter_bin
      begin
        return LiveSession.new(bin, cwd)
      rescue ex
        warn_no_interpreter
        STDERR.puts "live mode unavailable (#{ex.message})"
      end
    else
      warn_no_interpreter
    end
    ReplaySession.new
  end

  # The `crystal i` interpreter cannot run C extensions: a call into one
  # deadlocks the interpreter process. Only `.reset` (process restart)
  # recovers the session; replay mode (`crystal run`) is unaffected.
  def self.warn_c_extensions
    msg = "WARNING: C extensions don't work in the interpreter — a call into one deadlocks it. Use .reset to recover; replay mode is unaffected."
    STDERR.puts STDERR.tty? ? "\e[33m#{msg}\e[0m" : msg
  end

  private def self.warn_no_interpreter
    msg = "WARNING: no interpreter found — running in replay mode (~2s per line).\n" \
          "Run `rake interpreter` (or scripts/build-interpreter.sh) once for instant answers."
    STDERR.puts STDERR.tty? ? "\e[31m#{msg}\e[0m" : msg
  end

  # irb-style braille banner: the art is tinted blue, the text stays in
  # the terminal's default color (no escapes at all when not a TTY)
  def self.banner(mode : String) : String
    art = {"⢀⡴⠊⢉⡟⢿", "⣎⣀⣴⡋⡟⣻", "⣟⣼⣱⣽⣟⣾"}
    text = {"icr v#{VERSION} - Crystal #{Crystal::VERSION} - #{mode}",
            %("exit" to quit · ".program" source · ".reset" clear · Tab complete · ^T search),
            Dir.current}
    tty = STDOUT.tty?
    String.build do |io|
      art.each_with_index do |a, i|
        io << (tty ? "\e[94m#{a}\e[0m" : a) << "  " << text[i] << '\n'
      end
    end
  end
end

require "./icr/cli"
