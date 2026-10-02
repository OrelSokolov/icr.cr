# Demo: icr as a library.
#
# Run:
#   rake librun   (or: crystal run examples/library_demo.cr)
#
# Behaves 1:1 like running the icr binary — the loop below is the
# same driver as Icr::CLI.run — except the session is opened with
# cwd = this directory and pre-seeded with `require "./my_math"`,
# so MyMath is available from the first prompt. MyMath lives in a
# real file the host program can require as usual; the session
# requires the same file via the relative path.
#
# require_with_autocomplete additionally bakes MyMath into the
# completion table, so Tab/Ctrl-T know about it (classes and structs
# are harvested automatically; modules need to be listed as roots).

require "../src/icr"
require_with_autocomplete "./my_math", MyMath

io = Icr.open_session(__DIR__)
io.submit(%(require "./my_math")) # preload into the session

editor = Icr::LineEditor.new(Icr::Completion::Index.default)
history = [] of String
mode = io.is_a?(Icr::LiveSession) ? "live interpreter" : "replay, ~2s/line"
puts Icr.banner(mode)
loop do
  prompt = io.is_a?(Icr::LiveSession) && io.needs_continuation? ? "... > " : "icr> "
  line = editor.read_line(prompt, history)
  break if line.nil? # Ctrl+D
  line = line.strip
  next if line.empty?

  unless io.is_a?(Icr::LiveSession)
    # Multi-line input in replay mode: end a line with '\' to continue.
    while line.ends_with?('\\')
      more = editor.read_line("... > ", history)
      break if more.nil?
      line = line.rchop + "\n" + more
    end
  end

  case line
  when ".exit", ".quit", "exit", "exit!" then break
  when ".reset"   then puts io.reset
  when ".program" then puts io.program_source.presence || "# (empty)"
  else
    started = Time.instant
    result = io.submit(line)
    elapsed = Time.instant - started
    puts result.presence || "# (no output)"
    printf("# %.1fs\n", elapsed.total_seconds)
    history << line unless history.last? == line
    break if io.is_a?(Icr::LiveSession) && !io.alive?
  end
end

puts # finish the "icr> " line cleanly on exit / Ctrl+D
editor.close
io.close if io.is_a?(Icr::LiveSession)
