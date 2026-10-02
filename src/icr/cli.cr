# CLI driver for the icr console.

module Icr::CLI
  def self.run : Nil
    live : Icr::LiveSession?
    mode = "replay, ~2s/line (no interpreter build found)"
    if bin = Icr.interpreter_bin
      begin
        live = Icr::LiveSession.new(bin)
        mode = "live interpreter"
      rescue ex
        STDERR.puts "live mode unavailable (#{ex.message}); falling back to replay"
        live = nil
      end
    end
    io = (live || Icr::ReplaySession.new).as(Icr::LiveSession | Icr::ReplaySession)
    puts Icr.banner(mode)
    loop do
      print io.is_a?(Icr::LiveSession) && io.needs_continuation? ? "... > " : "icr> "
      line = STDIN.gets
      break if line.nil? # Ctrl+D
      line = line.strip
      next if line.empty?

      unless io.is_a?(Icr::LiveSession)
        # Multi-line input in replay mode: end a line with '\' to continue.
        while line.ends_with?('\\')
          print "... > "
          more = STDIN.gets
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
        printf("# %.1fs\n", elapsed.total_seconds)
        # user code killed the interpreter (e.g. Process.exit) — follow it
        break if io.is_a?(Icr::LiveSession) && !io.alive?
      end
    end

    puts # finish the "icr> " line cleanly on exit / Ctrl+D
    io.close if io.is_a?(Icr::LiveSession)
  end
end
