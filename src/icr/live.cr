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

class Icr::LiveSession
  class Error < Exception; end

  CONTINUE_RE     = /icr:\d+\* *\z/
  ANSI_RE         = /\e\[[0-9;?]*[A-Za-z]/
  # steady-state silence windows; too low races the interpreter's echo
  SYNC_SILENCE    = 0.12
  RESULT_SILENCE  = 0.15
  SUBMIT_DEADLINE = 30.0

  getter? needs_continuation : Bool = false
  getter history = [] of String
  @pending : String? = nil
  @dead = false

  @master : IO::FileDescriptor
  @process : Process

  def initialize(@bin : String, cwd : String? = nil)
    @cwd = cwd || File.dirname(@bin)
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
    @needs_continuation = !(raw =~ CONTINUE_RE).nil?

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

  # After sending Enter: read until a prompt reappears at the end of
  # the stream (eval finished) and the stream goes quiet, or until the
  # deadline (endless programs). Returning only on a prompt guarantees
  # the NEXT submit's text can't race a still-busy interpreter.
  private def read_until_prompt : String
    buf = Bytes.new(4096)
    data = IO::Memory.new
    finish_at = Time.instant + SUBMIT_DEADLINE.seconds
    @master.read_timeout = RESULT_SILENCE.seconds
    prompt_at_end = false
    loop do
      n = begin
        @master.read(buf)
      rescue IO::TimeoutError
        break if prompt_at_end # quiet AND prompt seen: done
        next if Time.instant < finish_at
        break
      rescue IO::Error
        @dead = true # EIO: interpreter died (e.g. user code called exit)
        break
      end
      if n.zero? # EOF: interpreter died
        @dead = true
        break
      end
      data.write(buf[0, n])
      stripped = data.to_s.gsub(ANSI_RE, "")
      prompt_at_end = !(stripped =~ /(icr:\d+[>*] *)\z/).nil?
    end
    data.to_s
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
