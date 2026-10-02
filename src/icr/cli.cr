# CLI driver for the icr console.

module Icr::CLI
  def self.run : Nil
    # --replay: force replay mode (crystal run), never touch the interpreter.
    io = Icr.open_session(replay: ARGV.includes?("--replay"))
    editor = Icr::LineEditor.new(Icr::Completion::Index.default)
    history = [] of String
    mode = io.live? ? "live interpreter" : "replay, ~2s/line"
    puts Icr.banner(mode)
    Icr.warn_c_extensions if io.live?
    loop do
      prompt = io.live? && io.needs_continuation? ? "... > " : "icr> "
      line = editor.read_line(prompt, history)
      break if line.nil? # Ctrl+D
      line = line.strip
      next if line.empty?

      unless io.live?
        # Multi-line input in replay mode: end a line with '\' to continue.
        while line.ends_with?('\\')
          more = editor.read_line("... > ", history)
          break if more.nil?
          line = line.rchop + "\n" + more
        end
      end

      case line
      when ".exit", ".quit", "exit", "exit!" then break # irb-style: exit the console
      when ".reset"   then puts io.reset
      when ".program" then puts io.program_source.presence || "# (empty)"
      else
        started = Time.instant
        result = io.submit(line)
        elapsed = Time.instant - started
        puts result.presence || "# (no output)"
        if elapsed.total_seconds >= 1
          timing = sprintf("# %.1fs", elapsed.total_seconds)
          puts STDOUT.tty? ? "\e[90m#{timing}\e[0m" : timing
        end
        history << line unless history.last? == line
        # user code killed the interpreter (e.g. Process.exit) — follow
        # it; replay sessions report alive? always true
        break unless io.alive?
      end
    end

    puts # finish the "icr> " line cleanly on exit / Ctrl+D
    editor.close
    io.close
  rescue IO::Error
    # stdout went away — the consumer closed the pipe (grep -q, icr |
    # head). Exit quietly like any Unix filter instead of crashing with
    # an unhandled broken-pipe error; a REPL without stdout is done.
    return
  end
end
