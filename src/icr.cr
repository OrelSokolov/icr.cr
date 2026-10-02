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

module Icr
  VERSION = "1.0.0"

  # Where the live backend's compiler comes from, in order:
  #   1. ICR_CRYSTAL env var (explicit override)
  #   2. ~/.local/share/icr/crystal/bin/crystal (scripts/build-interpreter.sh)
  #   3. `crystal` from PATH (usually lacks interpreter support; the
  #      CLI then falls back to replay mode)
  def self.interpreter_bin : String?
    if env = ENV["ICR_CRYSTAL"]?
      return File.exists?(env) ? env : nil
    end

    home = ENV["HOME"]? || "/root"
    local = File.join(home, ".local/share/icr/crystal/bin/crystal")
    return local if File.exists?(local)

    "crystal"
  end

  # irb-style braille banner: the art is tinted blue, the text stays in
  # the terminal's default color (no escapes at all when not a TTY)
  def self.banner(mode : String) : String
    art = {"⢀⡴⠊⢉⡟⢿", "⣎⣀⣴⡋⡟⣻", "⣟⣼⣱⣽⣟⣾"}
    text = {"icr v#{VERSION} - Crystal #{Crystal::VERSION} - #{mode}",
            %("exit" to quit · ".program" session source · ".reset" clear),
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
