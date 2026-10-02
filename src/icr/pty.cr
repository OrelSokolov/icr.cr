# PTY via libc openpty (Linux/macOS). The live backend needs a real
# TTY: the interpreter's line editor (lib/reply) reads key events from
# stdin and crashes on a 0x0 window size, so we always pass a Winsize.
# The Windows twin of Icr::Pty lives in conpty.cr (ConPTY).

{% if flag?(:unix) %}
  @[Link("util")]
  lib Icr::LibPty
    struct Winsize
      ws_row : UInt16
      ws_col : UInt16
      ws_xpixel : UInt16
      ws_ypixel : UInt16
    end

    fun openpty(amaster : Int32*, aslave : Int32*, name : UInt8*,
                termios : Void*, win : Winsize*) : Int32
  end

  # Terminal size query — Crystal's LibC doesn't bind ioctl or
  # TIOCGWINSZ. The request argument is unsigned long (UInt64 on LP64);
  # the constant differs between Linux and the BSDs/macOS.
  @[Link("c")]
  lib Icr::LibIoctl
    {% if flag?(:darwin) || flag?(:bsd) %}
      TIOCGWINSZ = 0x40087468
    {% else %}
      TIOCGWINSZ = 0x5413
    {% end %}

    fun ioctl(fd : Int32, request : UInt64, ...) : Int32
  end
{% end %}

{% if flag?(:unix) %}
  # A process attached to an openpty PTY. The interface mirrors the
  # Windows Icr::Pty in conpty.cr so Icr::LiveSession is platform-
  # neutral.
  class Icr::Pty
    class Error < Exception; end

    ROWS = 50
    COLS = 500

    def self.open(bin : String, args : Enumerable(String), cwd : String?,
                  env : Hash(String, String)) : self
      win = LibPty::Winsize.new(ws_row: ROWS, ws_col: COLS, ws_xpixel: 0, ws_ypixel: 0)
      ret = LibPty.openpty(out master, out slave, Pointer(UInt8).null,
        Pointer(Void).null, pointerof(win))
      raise Error.new("openpty failed") unless ret == 0

      slave_io = IO::FileDescriptor.new(slave)
      process = Process.new(bin, args, chdir: cwd, env: env,
        input: slave_io, output: slave_io, error: slave_io)
      slave_io.close # parent copy; the child owns the slave now
      new(IO::FileDescriptor.new(master), process)
    end

    def initialize(@master : IO::FileDescriptor, @process : Process)
    end

    def read(buf : Bytes) : Int32
      @master.read(buf)
    end

    def write(slice : Bytes) : Nil
      @master.write(slice)
      @master.flush
    end

    def read_timeout=(value : Time::Span?) : Nil
      @master.read_timeout = value
    end

    def exists? : Bool
      @process.exists?
    end

    def terminate(graceful : Bool = true) : Nil
      @process.terminate(graceful: graceful)
    end

    def wait : Nil
      @process.wait
    end

    def close : Nil
      @master.close rescue nil
    end
  end
{% end %}
