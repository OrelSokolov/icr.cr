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
