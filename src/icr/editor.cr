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

require "crystal/syntax_highlighter/colorize"

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
  # when stdin is a TTY, a plain gets otherwise. `completion` (when
  # given) powers Tab completion and the Ctrl-T search overlay in the
  # interactive adapter; the basic one ignores it.
  def self.new(completion : Icr::Completion::Index? = nil) : LineEditor
    if STDIN.tty?
      {% if flag?(:unix) %}
        UnixLineEditor.new(STDIN, STDOUT, completion)
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
  CtrlT
  Escape
  Tab
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
    when 9      then {Icr::KeyEvent.new(Icr::Key::Tab), 1}
    when 20     then {Icr::KeyEvent.new(Icr::Key::CtrlT), 1}
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
    # A lone \e buffered with nothing after it is a real Esc press —
    # CSI/SS3 sequences arrive as one chunk, so they never sit alone.
    return {Icr::KeyEvent.new(Icr::Key::Escape), 1} if bytes.size == 1

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

  # Insert a whole chunk of text at the cursor (completion results).
  def insert_text(text : String) : Nil
    return if text.empty?
    @buffer = buffer.insert(@cursor, text)
    @cursor += text.size
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

# IRB/reline-style candidate menu: the filtered candidate list for the
# token before the cursor, a scrollable window of ROWS visible rows and
# a moving selection. Pure state — the editor renders it. A dismissed
# dialog stays hidden until the input before the cursor changes.
class Icr::CompletionDialog
  ROWS = 10

  getter candidates = [] of String
  getter selected = 0
  getter offset = 0

  @hidden_for : String? = nil

  def active? : Bool
    !candidates.empty?
  end

  # Recompute the candidate list from the token before the cursor.
  # Selection and scroll reset only when the list actually changes, so
  # cursor moves don't yank the selection back to the top.
  def update(buffer : String, cursor : Int32, index : Icr::Completion::Index?) : Nil
    before = buffer[0...Math.min(cursor, buffer.size)]
    if before == @hidden_for
      @candidates.clear
      return
    end
    @hidden_for = nil

    cands = if index
              Icr::Completion::Completer.complete(before, before.size, index).last
            else
              [] of String
            end
    unless cands == @candidates
      @candidates = cands
      @selected = 0
      @offset = 0
    end
  end

  # Esc: hide for the current context; more typing reopens the dialog.
  def dismiss(buffer : String, cursor : Int32) : Nil
    @hidden_for = buffer[0...Math.min(cursor, buffer.size)]
    @candidates.clear
    @selected = 0
    @offset = 0
  end

  # ↑/↓: move the selection, scrolling the window to keep it visible.
  # No wrap — stops at either end like reline.
  def move(delta : Int32) : Nil
    return if candidates.empty?
    @selected = (@selected + delta).clamp(0, candidates.size - 1)
    if @selected < @offset
      @offset = @selected
    elsif @selected >= @offset + ROWS
      @offset = @selected - ROWS + 1
    end
  end

  # The visible window and the selection's position inside it (-1 when
  # nothing is selected — impossible while active, but keeps render
  # total).
  def visible : {Array(String), Int32}
    {candidates[offset, Math.min(ROWS, candidates.size - offset)], selected - offset}
  end
end

{% if flag?(:unix) %}
  # Unix adapter: termios raw mode, chunked reads fed through KeyParser,
  # EditState mutated per event, prompt + buffer repainted after each
  # key (cursor parked back where EditState says it belongs).
  class Icr::UnixLineEditor < Icr::LineEditor
    def initialize(@input : IO::FileDescriptor = STDIN, @output : IO = STDOUT,
                   @index : Icr::Completion::Index? = nil)
    end

    # Bytes read but not yet parsed — a paste can deliver several
    # lines at once, and what follows the first Enter must survive
    # into the next read_line call.
    @pending = [] of UInt8
    @raw = false
    @eof = false
    @dialog_drawn = 0 # dialog rows currently on screen (for wipe on submit)
    @saved = uninitialized LibC::Termios

    def read_line(prompt : String, history : Array(String)) : String?
      enter_raw
      @eof = false
      state = EditState.new(history)
      dialog = CompletionDialog.new
      parser = KeyParser.new
      chunk = uninitialized UInt8[256]

      render(prompt, state)
      # Leftover from a previous multi-line paste, if any.
      if result = process(parser, @pending, state, prompt, dialog)
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

        if result = process(parser, @pending, state, prompt, dialog)
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
                        state : EditState, prompt : String,
                        dialog : CompletionDialog) : String?
      while event = next_event(parser, bytes)
        case event.key
        when .enter?
          # Raw mode: no OPOST, so the newline needs its own \r or the
          # next output starts mid-column. The dialog dies with the
          # line — IRB submits as-is, it doesn't accept the selection.
          wipe_dialog(state)
          @output.print "\r\n"
          return state.buffer
        when .ctrl_c? # discard the line like a shell does
          wipe_dialog(state)
          @output.print "^C\r\n"
          return ""
        when .ctrl_d?
          # Empty line → EOF (read_line turns @eof into nil, the nil
          # that "keep reading" also returns is untouchable here).
          # With text on the line, accept it like the cooked tty did.
          wipe_dialog(state)
          @output.print "\r\n"
          if state.buffer.empty?
            @eof = true
            return ""
          else
            return state.buffer
          end
        when .tab?
          complete(prompt, state, dialog)
        when .ctrl_t?
          dialog.dismiss(state.buffer, state.cursor)
          run_search(prompt, state)
        when .escape? # Esc: dismiss the dialog (reline behavior)
          if dialog.active?
            dialog.dismiss(state.buffer, state.cursor)
            render(prompt, state, dialog)
          end
        when .up?, .down?
          # While the dialog is open its arrows belong to it, not to
          # history navigation — exactly how IRB's candidate menu works.
          if dialog.active?
            dialog.move(event.key.up?? -1 : 1)
            render(prompt, state, dialog)
          else
            state.handle(event)
            dialog.update(state.buffer, state.cursor, @index)
            render(prompt, state, dialog)
          end
        else
          state.handle(event)
          dialog.update(state.buffer, state.cursor, @index)
          render(prompt, state, dialog)
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

    # Tab: with the dialog open, accept the selected candidate;
    # otherwise complete the common prefix and open the dialog when
    # candidates remain ambiguous (reline flow).
    private def complete(prompt : String, state : EditState, dialog : CompletionDialog) : Nil
      index = @index
      return unless index

      if dialog.active?
        accept_selected(state, dialog, index)
      else
        insert, _cands = Icr::Completion::Completer.complete(state.buffer, state.cursor, index)
        state.insert_text(insert) unless insert.empty?
        dialog.update(state.buffer, state.cursor, index)
      end
      render(prompt, state, dialog)
    end

    # Replace the typed fragment with the dialog's selected candidate.
    # Candidates always start with the fragment, so only the remainder
    # is inserted at the cursor.
    private def accept_selected(state : EditState, dialog : CompletionDialog,
                                index : Icr::Completion::Index) : Nil
      candidate = dialog.candidates[dialog.selected]?
      return unless candidate
      frag = Icr::Completion::Completer.fragment(state.buffer, state.cursor)
      state.insert_text(candidate[frag.try(&.size) || 0..])
      dialog.update(state.buffer, state.cursor, index)
    end

    SEARCH_ROWS = 11 # query row + 10 result rows, lifted on every redraw

    # Ctrl-T overlay: fuzzy search over the baked table (see
    # Completion::Index#search). ↑/↓ select, Enter inserts into the
    # main line, Ctrl-C/Ctrl-D cancel.
    private def run_search(prompt : String, state : EditState) : Nil
      index = @index
      return unless index

      query = EditState.new([] of String)
      parser = KeyParser.new
      bytes = [] of UInt8
      chunk = uninitialized UInt8[256]
      selected = 0
      lifted = false

      loop do
        hits = index.search(query.buffer, 10)
        selected = hits.empty? ? 0 : selected.clamp(0, hits.size - 1)
        draw_search(prompt, state, query, hits, selected, lifted)
        lifted = true

        read = @input.read(chunk.to_slice)
        if read == 0 # EOF — cancel
          @output.print "\r\n"
          return render(prompt, state)
        end
        bytes.concat(chunk.to_slice[0, read].to_a)

        while event = next_event(parser, bytes)
          case event.key
          when .enter?
            @output.print "\r\n"
            state.insert_text(hits[selected].insert) if hits[selected]?
            return render(prompt, state)
          when .ctrl_c?, .ctrl_d?, .escape?
            @output.print "\r\n"
            return render(prompt, state)
          when .up?   then selected -= 1
          when .down? then selected += 1
          else
            query.handle(event)
          end
        end
      end
    end

    private def draw_search(prompt : String, state : EditState, query : EditState,
                            hits : Array(Icr::Completion::Hit), selected : Int32,
                            lifted : Bool) : Nil
      # \e[NF homes the cursor N lines up; \e[J wipes the old overlay.
      @output.print "\e[#{SEARCH_ROWS}F\e[J" if lifted
      @output.print "  search: #{query.buffer}  (↑↓ select · Enter insert · ^C cancel)\e[K\r\n"
      10.times do |i|
        if hit = hits[i]?
          marker = i == selected ? "›" : " "
          @output.print "  #{marker} #{hit.label}\e[K\r\n"
        else
          @output.print "\e[K\r\n"
        end
      end
      render(prompt, state)
    end

    DIALOG_WIDTH = 44 # label cap; longer names are truncated with "…"

    # Erase the dialog rows below the line before leaving the editor
    # loop (submit/discard/EOF): park at the end of the line first so
    # \e[J doesn't eat the text right of the cursor.
    private def wipe_dialog(state : EditState) : Nil
      return if @dialog_drawn.zero?
      behind = state.buffer.size - state.cursor
      @output.print "\e[#{behind}C" if behind > 0
      @output.print "\e[J"
      @dialog_drawn = 0
    end

    private def render(prompt : String, state : EditState,
                       dialog : CompletionDialog? = nil) : Nil
      # Repaint the whole line; \e[K clears whatever the previous paint
      # left to the right of it, \e[J clears any dialog rows below (or
      # leftovers from a previous frame). The highlight's ANSI codes
      # are zero-width, so the cursor math still uses the plain buffer.
      behind = state.buffer.size - state.cursor
      @output.print "\r#{prompt}#{highlight(state.buffer)}\e[K\e[J"

      if dialog && dialog.active?
        labels, selected = dialog.visible
        width = labels.map { |l| l.size > DIALOG_WIDTH ? DIALOG_WIDTH : l.size }.max
        indent = dialog_indent(prompt, state, width + 2)
        labels.each_with_index do |label, i|
          label = label[0, DIALOG_WIDTH - 1] + "…" if label.size > DIALOG_WIDTH
          body = " #{label.ljust(width)} "
          row = i == selected ? "#{" " * indent}\e[7m#{body}\e[27m" : "#{" " * indent}#{body}"
          @output.print "\r\n#{row}\e[K"
        end
        @dialog_drawn = labels.size
        # Park the cursor back on the input line at its column.
        @output.print "\e[#{labels.size}A\r\e[#{prompt.size + state.cursor}C"
      else
        @dialog_drawn = 0
        @output.print "\e[#{behind}D" if behind > 0
      end
      @output.flush
    end

    # Where the dialog starts: under the fragment being completed
    # ("x = MyMa|" → under "MyMa"), like reline. Clamped so the widest
    # row still fits the terminal — a long line pushes the dialog back
    # toward the left edge instead of wrapping it.
    private def dialog_indent(prompt : String, state : EditState, row_width : Int32) : Int32
      frag = Icr::Completion::Completer.fragment(state.buffer, state.cursor)
      col = prompt.size + state.cursor - (frag.try(&.size) || 0)
      if (term = terminal_columns) > 0
        col = col.clamp(0, {term - row_width, 0}.max)
      end
      col
    end

    # Terminal width via TIOCGWINSZ (0 when it can't be queried — the
    # Winsize struct is already bound for the PTY backend).
    private def terminal_columns : Int32
      fd = @output.as?(IO::FileDescriptor).try(&.fd) || -1
      return 0 if fd < 0
      win = uninitialized Icr::LibPty::Winsize
      ret = Icr::LibIoctl.ioctl(fd, Icr::LibIoctl::TIOCGWINSZ.to_u64!, pointerof(win))
      ret.zero? ? win.ws_col.to_i : 0
    end

    # Paint the buffer exactly like the live interpreter paints its own
    # echo: `crystal i` runs the very same stdlib highlighter
    # (Crystal::ReplReader#highlight → SyntaxHighlighter::Colorize), so
    # icr's input and the interpreter's echo match token for token.
    # highlight! falls back to the plain line when it can't lex
    # mid-typing input (e.g. an open string), and colors are suppressed
    # when the output isn't a TTY or NO_COLOR/TERM=dumb say so
    # (Colorize.enabled? checks both).
    private def highlight(line : String) : String
      return line unless @output.tty? && ::Colorize.enabled?
      Crystal::SyntaxHighlighter::Colorize.highlight!(line)
    end
  end
{% end %}
