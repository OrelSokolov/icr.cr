# PTY via libc openpty (Linux). The live backend needs a real TTY: the
# interpreter's line editor (lib/reply) reads key events from stdin
# and crashes on a 0x0 window size, so we always pass a Winsize.

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
