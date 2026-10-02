# Replay backend: the whole session is recompiled and re-run via
# `crystal run` after every submitted line. No interpreter needed —
# works with any stock Crystal install (~1.5-3s per line).
#
# Each line is executed as `__icr_r = begin <line> end; puts "=> ..."`,
# and committed in that wrapped form, so every run replays exactly what
# ran before and the new run's stdout is a growing prefix of the next
# one. That lets us diff away replayed output and show only what the
# new line added. Lines that can't be wrapped (require/def/class...)
# are committed plain and simply print nothing extra. Re-executed side
# effects (DB writes, network calls) still happen on every submission —
# that's inherent to the replay model.

class Icr::ReplaySession
  # A committed line: raw source plus whether it can be replayed in the
  # result-printing wrapper (expressions) or must run plain (require,
  # def, class and other non-expression declarations).
  record Line, src : String, wrapped : Bool

  getter lines = [] of Line
  @last_output = ""

  # Compile and run the session plus one new line. Returns the text to
  # display for this submission. The line is committed only if it
  # compiles and runs cleanly; a failed line never poisons the session.
  def submit(line : String) : String
    run_new_line(line, wrap: true) ||
      run_new_line(line, wrap: false) ||
      "error: line rejected; session unchanged"
  end

  def reset : String
    lines.clear
    @last_output = ""
    "session cleared"
  end

  def program_source : String
    lines.map(&.src).join('\n')
  end

  def close : Nil
  end

  private def run_new_line(line : String, wrap : Bool) : String?
    out_io = IO::Memory.new
    err_io = IO::Memory.new
    status = build_and_run(lines, line, wrap, out_io, err_io)

    unless status.success?
      # The wrapped variant failing is expected for require/def/class
      # lines — submit falls back to the plain run. Only surface the
      # error when the plain run is the one that failed.
      return nil if wrap
      return err_io.to_s.presence || "error: `crystal run` exited #{status.exit_code}"
    end

    # Success: commit the line, then show only the output this run
    # added on top of the previous one (the old run's stdout is a
    # prefix of the new one, since committed lines replay identically).
    full = out_io.to_s
    diff = diff_output(full)
    @last_output = full
    lines << Line.new(line, wrap)
    diff
  end

  private def build_and_run(base : Array(Line), new_line : String, wrap_new : Bool, out_io, err_io)
    source = String.build do |io|
      base.each { |l| emit(io, l.src, l.wrapped) }
      emit(io, new_line, wrap_new)
    end

    path = File.tempname("icr", ".cr")
    begin
      File.write(path, source)
      Process.run(
        "crystal", {"run", "--no-color", path},
        input: Process::Redirect::Close,
        output: out_io, error: err_io
      )
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  private def emit(io : IO, src : String, wrapped : Bool)
    if wrapped
      io << "__icr_r = begin\n" << src << "\nend\n"
      io << %(puts "=> \#{__icr_r.inspect}") << '\n'
    else
      io << src << '\n'
    end
  end

  # Strip the previous run's stdout from this run's output. Falls back
  # to the full output when the prefix doesn't match (nondeterministic
  # output, e.g. random values or timestamps).
  private def diff_output(output : String) : String
    if output.starts_with?(@last_output)
      output[@last_output.size..]
    else
      output
    end
  end
end
