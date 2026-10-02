# Live backend: a persistent `crystal i` interpreter process over a PTY.
#
# The PTY protocol was reverse-engineered from lib/reply's CharReader:
# a read() returning more than 6 bytes (or a chunk containing the Enter
# byte) is treated as a PASTE, so the line text and the Enter key (\r)
# must be written as two separate writes with a pause between them, or
# the interpreter never submits anything. The window size must also be
# set (reply crashes on a 0x0 pty). Results come back as
# "\r\n<program output>\r\n => <value>\r\nicr:N> " after the line
# editor's final repaint (everything up to the last cursor-show escape
# is repaint and gets stripped).
#
# Completion is detected from the stream tail, not a silence window:
# after a finished evaluation the fresh prompt "icr:N> " is the LAST
# thing in the stream (no trailing escape), and its number is higher
# than any repaint shows — paying the full RESULT_SILENCE on every line
# made each submission cost ~0.15s more than the interpreter itself.
# An INCOMPLETE line redraws the whole session and ends with a
# cursor-show escape instead: reply renumbers history there and appends
# an empty "icr:N> " line, so only the raw tail (prompt vs escape)
# tells the two apart.

class Icr::LiveSession
  class Error < Exception; end

  ANSI_RE         = /\e\[[0-9;?]*[A-Za-z]/
  # prompt at the end of ANSI-stripped data, any index/marker (repaints)
  ANY_PROMPT_RE   = /icr:\d+[>*] *\z/
  # fresh idle prompt at the very end of the RAW stream: nothing follows
  # it, not even a cursor escape — repaints always end with \e[?25h
  REAL_PROMPT_RE  = /icr:(\d+)> *\z/
  # steady-state silence windows; too low races the interpreter's echo
  SYNC_SILENCE    = 0.12
  # short quiet window after a completion signal before returning —
  # absorbs chunk-boundary races (a prompt split across reads, output
  # landing right after the prompt) without the full RESULT_SILENCE tax
  GRACE_SILENCE   = 0.03
  # fallback quiet window when the raw tail can't confirm completion
  # (incomplete-expression redraws, unexpected prompt shapes)
  RESULT_SILENCE  = 0.15
  SUBMIT_DEADLINE = 30.0

  getter? needs_continuation : Bool = false
  getter history = [] of String
  @pending : String? = nil
  @dead = false
  # line number of the last prompt seen; 0 until the first prompt
  @prompt_index = 0

  @master : IO::FileDescriptor
  @process : Process

  def initialize(@bin : String, cwd : String? = nil)
    # Run the interpreter in the user's directory so relative requires
    # (`require "./examples/foo"`) resolve against it, not the crystal
    # install dir. The wrapper script locates its compiler via its own
    # path, so chdir doesn't affect it.
    @cwd = cwd || Dir.current
    @master = uninitialized IO::FileDescriptor
    @process = uninitialized Process
    start_process
  end

  # Send one line (or continuation line) to the interpreter. Returns
  # the rendered output: program stdout plus "=> value" like irb.
  def submit(line : String) : String
    return dead_message unless alive?
    write_chunk(line)
    wait_for_echo(line)

    write_chunk("\r")
    raw = read_until_prompt
    return dead_message if @dead
    # Continuation = settled WITHOUT a fresh prompt: the editor redrew
    # the session (cursor-show escape at the tail) and waits for the
    # rest of the expression. A raw tail ending in "icr:N> " means the
    # expression was complete and evaluated.
    @needs_continuation = quiet_prompt?(raw) && !raw.match(REAL_PROMPT_RE)

    if @needs_continuation
      @pending = @pending ? "#{@pending}\n#{line}" : line
      ""
    else
      full = @pending ? "#{@pending}\n#{line}" : line
      @pending = nil
      history << full
      extract(raw)
    end
  end

  # The live interpreter cannot drop state in-place — restart it.
  def reset : String
    close
    begin
      start_process
      history.clear
      @needs_continuation = false
      "session restarted (state cleared)"
    rescue ex : Error
      "reset failed (#{ex.message})"
    end
  end

  def close : Nil
    # Same paste rule as submit: the text and the Enter key must be two
    # separate writes, or the interpreter never processes "exit" and we
    # end up killing it after a timeout instead.
    if alive?
      begin
        write_chunk("exit")
        wait_for_echo("exit")
        write_chunk("\r")
      rescue IO::Error
      end
    end
    20.times do
      break unless @process.exists?
      sleep 0.05.seconds
    end
    if @process.exists?
      @process.terminate rescue nil
      5.times { break unless @process.exists?; sleep 0.05.seconds }
      @process.terminate(graceful: false) rescue nil if @process.exists?
    end
    @process.wait rescue nil
    @master.close rescue nil
  end

  def alive? : Bool
    !@dead && @process.exists?
  end

  def program_source : String
    history.join('\n')
  end

  private def dead_message : String
    "interpreter exited"
  end

  private def start_process
    @dead = false
    @prompt_index = 0 # re-detected from the startup prompt below
    win = LibPty::Winsize.new(ws_row: 50, ws_col: 500, ws_xpixel: 0, ws_ypixel: 0)
    ret = LibPty.openpty(out master, out slave, Pointer(UInt8).null,
      Pointer(Void).null, pointerof(win))
    raise Error.new("openpty failed") unless ret == 0

    slave_io = IO::FileDescriptor.new(slave)
    env = ENV.to_h.merge({
      "TERM"                            => "xterm-256color",
      "CRYSTAL_INTERPRETER_SKIP_BANNER" => "1",
    })
    @process = Process.new(@bin, {"i"}, chdir: @cwd, env: env,
      input: slave_io, output: slave_io, error: slave_io)
    slave_io.close # parent copy; the child owns the slave now
    @master = IO::FileDescriptor.new(master)
    read_until_prompt # wait for the "icr:1> " prompt; banner lands before it
    if @dead
      raise Error.new("#{@bin} died at startup — it likely lacks interpreter " \
                      "support (run scripts/build-interpreter.sh)")
    end
  end

  private def write_chunk(data : String) : Nil
    # IO#write is write-all semantics (returns Nil) — no partial-write
    # loop needed.
    @master.write(data.to_slice)
    @master.flush
  end

  # After sending the line text: wait until the editor has consumed it
  # (its echo shows up in the redraw) so the following \r is guaranteed
  # to arrive as a SEPARATE read — a coalesced text+\r chunk is treated
  # as a paste and never submits.
  private def wait_for_echo(line : String) : Nil
    buf = Bytes.new(4096)
    data = IO::Memory.new
    @master.read_timeout = SYNC_SILENCE.seconds
    loop do
      n = begin
        @master.read(buf)
      rescue IO::TimeoutError
        break
      rescue IO::Error
        @dead = true # EIO: interpreter released the slave and died
        break
      end
      break if n.zero?
      data.write(buf[0, n])
      stripped = data.to_s.gsub(ANSI_RE, "")
      break if line.split('\n').all? { |part| stripped.includes?(part) }
    end
  end

  # After sending Enter: read until the REPL is verifiably idle again.
  # The fast path fires when the raw stream ENDS with a fresh prompt
  # whose number advanced past the last one we recorded — repaints
  # re-render old numbers and always end with a cursor escape, so this
  # tail cannot appear before eval is done. We return GRACE_SILENCE
  # after it; when no such tail shows up (incomplete expression →
  # session redraw, or an unexpected shape) fall back to the old
  # prompt-plus-quiet heuristic, capped by the deadline (endless
  # programs). Returning only on a prompt guarantees the NEXT submit's
  # text can't race a still-busy interpreter.
  private def read_until_prompt : String
    buf = Bytes.new(4096)
    data = IO::Memory.new
    raw = ""
    finish_at = Time.instant + SUBMIT_DEADLINE.seconds
    grace_until = nil : Time?
    loop do
      @master.read_timeout = (grace_until ? GRACE_SILENCE : RESULT_SILENCE).seconds
      n = begin
        @master.read(buf)
      rescue IO::TimeoutError
        break if grace_until                # fast path: fresh prompt settled
        break if quiet_prompt?(raw)         # legacy: quiet AND prompt at end
        break if Time.instant >= finish_at
        next
      rescue IO::Error
        @dead = true # EIO: interpreter died (e.g. user code called exit)
        break
      end
      if n.zero? # EOF: interpreter died
        @dead = true
        break
      end
      data.write(buf[0, n])
      raw = data.to_s
      grace_until = fast_prompt?(raw) ? Time.instant + GRACE_SILENCE.seconds : nil
    end
    advance_prompt_index(raw)
    raw
  end

  # The editor is idle at a fresh prompt: the prompt text is the very
  # last thing in the raw stream (a repaint would trail a cursor-show
  # escape) and its line number moved past the last fresh prompt we
  # saw — session redraws re-render the old numbers.
  private def fast_prompt?(raw : String) : Bool
    match = raw.match(REAL_PROMPT_RE)
    !!match && match[1].to_i > @prompt_index
  end

  # Settled with a prompt at the end of the ANSI-stripped stream but
  # no fresh-prompt tail: an incomplete-expression redraw (the editor
  # waits for more input) or an unexpected prompt shape — treat
  # quiet-plus-prompt as idle like the old silence heuristic did.
  private def quiet_prompt?(raw : String) : Bool
    !raw.gsub(ANSI_RE, "").match(ANY_PROMPT_RE).nil?
  end

  # Remember the line number of the newest fresh prompt so the next
  # read can tell it (number advances) from a session redraw (old
  # numbers re-rendered). Only the raw tail is trusted — user code
  # printing prompt-looking text mid-stream can't confuse it.
  private def advance_prompt_index(raw : String) : Nil
    raw.match(REAL_PROMPT_RE).try { |m| @prompt_index = m[1].to_i }
  end

  # Turn raw PTY bytes into irb-style output: drop the line editor's
  # repaint (everything up to the last cursor-show escape), strip
  # ANSI/CR, drop the trailing prompt, split program stdout from the
  # "=> value" tail.
  private def extract(raw : String) : String
    text = raw.rindex("\e[?25h").try { |i| raw[(i + 6)..] } || raw
    text = text.gsub(ANSI_RE, "").gsub("\r\n", "\n")
    text = text.sub(/(icr:\d+[>*] *)\z/, "")
    return dead_message if text.empty? && @dead

    if idx = text.rindex("\n => ")
      output = text[0...idx]
      value = text[(idx + 5)..].strip
      out = String.build do |io|
        io << output.strip << '\n' unless output.strip.empty?
        io << "=> " << value unless value.empty?
      end
      out.strip
    else
      text.strip
    end
  end
end
