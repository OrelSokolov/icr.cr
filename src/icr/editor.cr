# Line input for the console: command history with ↑/↓ navigation and
# ←/→ cursor editing.
#
# Port/adapter: LineEditor is the platform-independent port the CLI
# drives. UnixLineEditor puts the terminal into raw mode via termios
# (IO#raw) and renders the line itself; BasicLineEditor is the
# non-interactive fallback used when stdin is not a TTY (piped input,
# specs), where arrow keys just arrive as bytes and a plain gets is
# the honest behavior. A Windows console adapter would slot in next
# to UnixLineEditor the same way.
#
# The keystroke parsing (KeyParser) and the editing model (EditState)
# are pure and IO-free — the same design as hcode's TUI::Input /
# TUI::Editor, scaled down to a single line — so they are directly
# unit-testable and shared by every adapter.

abstract class Icr::LineEditor
  # Read one line, rendering `prompt` and walking `history` with ↑/↓.
  # Returns nil on EOF (Ctrl+D on an empty line); Ctrl+C discards the
  # line and returns "".
  abstract def read_line(prompt : String, history : Array(String)) : String?

  # Release terminal state (restore cooked mode). No-op for adapters
  # that never grabbed it.
  def close : Nil
  end

  # The adapter for this platform and input: an interactive editor
  # when stdin is a TTY, a plain gets otherwise.
  def self.new : LineEditor
    if STDIN.tty?
      {% if flag?(:unix) %}
        UnixLineEditor.new
      {% else %}
        BasicLineEditor.new
      {% end %}
    else
      BasicLineEditor.new
    end
  end
end

# Non-interactive fallback: plain gets, no history navigation.
class Icr::BasicLineEditor < Icr::LineEditor
  def initialize(@input : IO = STDIN, @output : IO = STDOUT)
  end

  def read_line(prompt : String, history : Array(String)) : String?
    @output.print prompt
    @input.gets
  end
end

enum Icr::Key
  Unknown
  Enter
  Backspace
  Delete
  CtrlC
  CtrlD
  Up
  Down
  Left
  Right
  Home
  End
  Char
end

record Icr::KeyEvent, key : Icr::Key, char : Char? = nil do
  def self.char(c : Char) : self
    new(Key::Char, c)
  end
end

# Byte-stream → KeyEvent parser. Pure: bytes in, events out, no IO.
# Handles CSI sequences (arrows, Home/End, Delete), SS3 arrows
# (\eOA..), and multi-byte UTF-8. {nil, 0} means "need more bytes".
class Icr::KeyParser
  def parse_one(bytes : Array(UInt8)) : {Icr::KeyEvent?, Int32}
    return {nil, 0} if bytes.empty?
    first = bytes[0]

    case first
    when 13, 10 then {Icr::KeyEvent.new(Icr::Key::Enter), 1}
    when 127, 8 then {Icr::KeyEvent.new(Icr::Key::Backspace), 1}
    when 3      then {Icr::KeyEvent.new(Icr::Key::CtrlC), 1}
    when 4      then {Icr::KeyEvent.new(Icr::Key::CtrlD), 1}
    when 27
      parse_escape(bytes)
    else
      if 32 <= first < 127
        {Icr::KeyEvent.char(first.chr), 1}
      elsif first >= 128
        parse_utf8(bytes)
      else
        {Icr::KeyEvent.new(Icr::Key::Unknown), 1}
      end
    end
  end

  private def parse_escape(bytes : Array(UInt8)) : {Icr::KeyEvent?, Int32}
    return {nil, 0} if bytes.size < 2 # rest of the sequence not here yet

    case bytes[1]
    when 91  then parse_csi(bytes) # '['
    when 79  then                  # 'O' — SS3: \eOA.. sent by some terminals
      return {nil, 0} if bytes.size < 3
      key = case bytes[2]
            when 65 then Icr::Key::Up
            when 66 then Icr::Key::Down
            when 67 then Icr::Key::Right
            when 68 then Icr::Key::Left
            when 72 then Icr::Key::Home
            when 70 then Icr::Key::End
            else        Icr::Key::Unknown
            end
      {Icr::KeyEvent.new(key), 3}
    else
      {Icr::KeyEvent.new(Icr::Key::Unknown), 2}
    end
  end

  private def parse_csi(bytes : Array(UInt8)) : {Icr::KeyEvent?, Int32}
    # Scan for the final byte (64..126); params/modifiers are 48..63.
    final_idx = -1
    i = 2
    while i < bytes.size
      b = bytes[i]
      if 48 <= b <= 63
        i += 1
      elsif 64 <= b <= 126
        final_idx = i
        break
      else
        return {Icr::KeyEvent.new(Icr::Key::Unknown), i + 1}
      end
    end
    return {nil, 0} if final_idx < 0

    param = bytes[2...final_idx].join(&.chr).to_i? || 0
    key = case bytes[final_idx]
          when 65 then Icr::Key::Up    # \e[A
          when 66 then Icr::Key::Down  # \e[B
          when 67 then Icr::Key::Right # \e[C
          when 68 then Icr::Key::Left  # \e[D
          when 72 then Icr::Key::Home  # \e[H
          when 70 then Icr::Key::End   # \e[F
          when 126
            case param
            when 1, 7 then Icr::Key::Home  # \e[1~ / \e[7~
            when 3     then Icr::Key::Delete # \e[3~
            when 4     then Icr::Key::End   # \e[4~
            else            Icr::Key::Unknown
            end
          else Icr::Key::Unknown
          end
    {Icr::KeyEvent.new(key), final_idx + 1}
  end

  private def parse_utf8(bytes : Array(UInt8)) : {Icr::KeyEvent?, Int32}
    first = bytes[0]
    length = case first
             when 0xC0..0xDF then 2
             when 0xE0..0xEF then 3
             when 0xF0..0xF7 then 4
             else                 return {Icr::KeyEvent.new(Icr::Key::Unknown), 1}
             end
    return {nil, 0} if bytes.size < length

    text = String.new(Bytes.new(bytes[0, length].to_unsafe, length)) rescue nil
    if (c = text.try(&.[0]?))
      {Icr::KeyEvent.char(c), length}
    else
      {Icr::KeyEvent.new(Icr::Key::Unknown), length}
    end
  end
end

# Single-line editing model: the buffer, a char cursor, and ↑/↓
# history navigation that preserves the draft being typed (hcode's
# TUI::Editor history_index convention: -1 = "not browsing yet").
# Pure state — the adapter renders it.
class Icr::EditState
  getter buffer : String = ""
  getter cursor : Int32 = 0 # char index within the buffer

  def initialize(@history : Array(String))
  end

  @history_index : Int32 = -1
  @draft : String = ""

  def handle(event : Icr::KeyEvent) : Nil
    case event.key
    when .char?   then insert(event.char.not_nil!)
    when .backspace? then backspace
    when .delete? then delete_forward
    when .left?   then @cursor -= 1 if @cursor > 0
    when .right?  then @cursor += 1 if @cursor < buffer.size
    when .home?   then @cursor = 0
    when .end?    then @cursor = buffer.size
    when .up?     then navigate(-1)
    when .down?   then navigate(1)
    else               # Enter/CtrlC/CtrlD/Unknown — the adapter's business
    end
  end

  private def insert(c : Char) : Nil
    @buffer = buffer.insert(@cursor, c)
    @cursor += 1
  end

  private def backspace : Nil
    return if @cursor.zero?
    @buffer = buffer[0...@cursor - 1] + buffer[@cursor..]
    @cursor -= 1
  end

  private def delete_forward : Nil
    return if @cursor >= buffer.size
    @buffer = buffer[0...@cursor] + buffer[@cursor + 1..]
  end

  private def navigate(direction : Int32) : Nil
    return if @history.empty?
    if @history_index == -1
      @draft = buffer
      @history_index = @history.size # virtual position: at the draft
    end

    # Positions run 0..size, where `size` is the draft itself; past
    # either end navigation stops.
    new_index = @history_index + direction
    return if new_index < 0 || new_index > @history.size

    @history_index = new_index
    @buffer = new_index == @history.size ? @draft : @history[new_index]
    @cursor = buffer.size
  end
end

{% if flag?(:unix) %}
  # Unix adapter: termios raw mode, chunked reads fed through KeyParser,
  # EditState mutated per event, prompt + buffer repainted after each
  # key (cursor parked back where EditState says it belongs).
  class Icr::UnixLineEditor < Icr::LineEditor
    def initialize(@input : IO::FileDescriptor = STDIN, @output : IO = STDOUT)
    end

    # Bytes read but not yet parsed — a paste can deliver several
    # lines at once, and what follows the first Enter must survive
    # into the next read_line call.
    @pending = [] of UInt8
    @raw = false
    @eof = false
    @saved = uninitialized LibC::Termios

    def read_line(prompt : String, history : Array(String)) : String?
      enter_raw
      @eof = false
      state = EditState.new(history)
      parser = KeyParser.new
      chunk = uninitialized UInt8[256]

      render(prompt, state)
      # Leftover from a previous multi-line paste, if any.
      if result = process(parser, @pending, state, prompt)
        return @eof ? nil : result
      end
      loop do
        # Blocking read of one chunk; an escape sequence arrives as
        # a single write, so CSI/UTF-8 stay intact. 0 means EOF.
        read = @input.read(chunk.to_slice)
        if read == 0
          @output.print "\r\n"
          return state.buffer.empty? ? nil : state.buffer
        end
        @pending.concat(chunk.to_slice[0, read].to_a)

        if result = process(parser, @pending, state, prompt)
          return @eof ? nil : result
        end
      end
    end

    # Restore the terminal the way the shell expects it.
    def close : Nil
      return unless @raw
      LibC.tcsetattr(@input.fd, LibC::TCSANOW, pointerof(@saved))
      @raw = false
    end

    # Whole-session raw mode, NOT IO#raw's cfmakeraw: input flags are
    # ours (no echo, no line buffering, no ISIG), but OPOST stays on
    # so every \n printed elsewhere in the program still becomes
    # \r\n. Reverting between lines would let the line discipline
    # rewrite bytes typed while the interpreter is busy (DEL eaten as
    # ERASE, arrows buffered, ...).
    private def enter_raw : Nil
      return if @raw
      t = uninitialized LibC::Termios
      raise IO::Error.new("tcgetattr failed") unless LibC.tcgetattr(@input.fd, pointerof(t)) == 0
      @saved = t

      t.c_lflag &= ~(LibC::ECHO | LibC::ICANON | LibC::ISIG | LibC::IEXTEN).to_u32!
      t.c_iflag &= ~(LibC::IXON | LibC::ICRNL | LibC::BRKINT).to_u32!
      # VMIN/VTIME keep the tty's defaults (blocking, single-byte min)
      LibC.tcsetattr(@input.fd, LibC::TCSANOW, pointerof(t))
      @raw = true
      at_exit { close } # never leave the user's terminal in raw mode
    end

    # Consume events from `bytes` until it runs dry or a line
    # terminator shows up. Returns the finished line, or nil to keep
    # reading.
    private def process(parser : KeyParser, bytes : Array(UInt8),
                        state : EditState, prompt : String) : String?
      while event = next_event(parser, bytes)
        case event.key
        when .enter?
          # Raw mode: no OPOST, so the newline needs its own \r or the
          # next output starts mid-column.
          @output.print "\r\n"
          return state.buffer
        when .ctrl_c? # discard the line like a shell does
          @output.print "^C\r\n"
          return ""
        when .ctrl_d?
          # Empty line → EOF (read_line turns @eof into nil, the nil
          # that "keep reading" also returns is untouchable here).
          # With text on the line, accept it like the cooked tty did.
          @output.print "\r\n"
          if state.buffer.empty?
            @eof = true
            return ""
          else
            return state.buffer
          end
        else
          state.handle(event)
          render(prompt, state)
        end
      end
      nil
    end

    private def next_event(parser : KeyParser, bytes : Array(UInt8)) : Icr::KeyEvent?
      loop do
        event, consumed = parser.parse_one(bytes)
        return nil if consumed == 0
        bytes.replace(bytes[consumed..])
        return event if event # Unknown events are dropped by parse callers
      end
    end

    private def render(prompt : String, state : EditState) : Nil
      # Repaint the whole line; \e[K clears whatever the previous paint
      # left to the right, then the cursor steps back from the end to
      # its position within the buffer.
      behind = state.buffer.size - state.cursor
      @output.print "\r#{prompt}#{state.buffer}\e[K"
      @output.print "\e[#{behind}D" if behind > 0
      @output.flush
    end
  end
{% end %}
