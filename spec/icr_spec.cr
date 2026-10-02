require "spec"
require "../src/icr"

describe Icr do
  it "shows version and mode in the banner" do
    banner = Icr.banner("test-mode")
    banner.should contain(Icr::VERSION)
    banner.should contain("test-mode")
    banner.should contain("icr v")
    # no ANSI escapes when not a TTY
    banner.should_not contain("\e[")
  end

  it "prefers ICR_CRYSTAL when it exists" do
    with_env("ICR_CRYSTAL", "/bin/sh") do
      Icr.interpreter_bin.should eq("/bin/sh")
    end
  end

  it "returns nil for a missing ICR_CRYSTAL" do
    with_env("ICR_CRYSTAL", "/nonexistent-crystal") do
      Icr.interpreter_bin.should be_nil
    end
  end

  it "falls back to CRYSTAL_INTERPRETER_PATH when ICR_CRYSTAL is unset" do
    with_env("ICR_CRYSTAL", nil) do
      with_env("CRYSTAL_INTERPRETER_PATH", "/bin/sh") do
        Icr.interpreter_bin.should eq("/bin/sh")
      end
    end
  end

  it "returns nil for a missing CRYSTAL_INTERPRETER_PATH" do
    with_env("ICR_CRYSTAL", nil) do
      with_env("CRYSTAL_INTERPRETER_PATH", "/nonexistent-crystal") do
        Icr.interpreter_bin.should be_nil
      end
    end
  end

  it "prefers ICR_CRYSTAL over CRYSTAL_INTERPRETER_PATH" do
    with_env("ICR_CRYSTAL", "/bin/sh") do
      with_env("CRYSTAL_INTERPRETER_PATH", "/nonexistent-crystal") do
        Icr.interpreter_bin.should eq("/bin/sh")
      end
    end
  end

  it "open_session falls back to ReplaySession when no interpreter exists" do
    with_env("ICR_CRYSTAL", "/nonexistent-crystal") do
      session = Icr.open_session
      session.should be_a(Icr::ReplaySession)
    end
  end

  it "open_session(replay: true) skips the interpreter even when one exists" do
    with_env("ICR_CRYSTAL", "/bin/sh") do
      session = Icr.open_session(replay: true)
      session.should be_a(Icr::ReplaySession)
    end
  end
end

describe Icr::ReplaySession do
  it "evaluates expressions and prints their values" do
    session = Icr::ReplaySession.new
    session.submit("2 + 2").should contain("=> 4")
  end

  it "keeps state across lines" do
    session = Icr::ReplaySession.new
    session.submit("x = 20").should contain("=> 20")
    session.submit("x + 1").should contain("=> 21")
    session.program_source.should contain("x = 20")
  end

  it "rejects broken lines without poisoning the session" do
    session = Icr::ReplaySession.new
    session.submit("def broken(").should match /[Ee]rror/
    session.submit("1 + 1").should contain("=> 2")
  end

  it "resolves relative requires against the user's cwd" do
    session = Icr::ReplaySession.new
    session.submit(%(require "./examples/my_math")).should_not match /[Ee]rror/
    session.submit("MyMath.square(5)").should contain("=> 25")
  end

  it "clears state on reset" do
    session = Icr::ReplaySession.new
    session.submit("x = 20")
    session.reset
    session.program_source.should be_empty
  end
end

{% if flag?(:unix) %}
  # Live specs need an interpreter-capable crystal (the same resolution
  # chain the CLI uses); replay-only environments skip the whole block.
  # The live backend itself is Unix-only (openpty).
  def live_interpreter_available? : Bool
  bin = Icr.interpreter_bin
  return false unless bin
  session = Icr::LiveSession.new(bin)
  session.close
  true
rescue Icr::LiveSession::Error
  false
end

if live_interpreter_available?
  describe Icr::LiveSession do
    it "evaluates lines and returns irb-style values" do
      session = Icr::LiveSession.new(Icr.interpreter_bin.not_nil!)
      begin
        session.submit("2 + 2").should contain("=> 4")
      ensure
        session.close
      end
    end

    it "continues incomplete expressions and keeps state" do
      session = Icr::LiveSession.new(Icr.interpreter_bin.not_nil!)
      begin
        session.submit("def f(x)").should eq("")
        session.needs_continuation?.should be_true
        session.submit("  x * 2").should eq("")
        session.needs_continuation?.should be_true
        session.submit("end")
        session.needs_continuation?.should be_false
        session.submit("f(21)").should contain("=> 42")
      ensure
        session.close
      end
    end

    it "detects completion by the prompt tail, not a silence window" do
      # Regression: the old heuristic paid a fixed ~0.15s+ per line on
      # top of the interpreter's own time, and continuation lines hit
      # the 30s deadline because the redraw arrives late.
      session = Icr::LiveSession.new(Icr.interpreter_bin.not_nil!)
      begin
        session.submit("1 + 1") # warm up: first line compiles primitives
        started = Time.instant
        session.submit("20 + 22").should contain("=> 42")
        (Time.instant - started).total_seconds.should be < 1.0
      ensure
        session.close
      end
    end
  end
end

describe Icr::LineEditor do
  it "picks the basic editor when stdin is not a TTY" do
    STDIN.tty?.should be_false # specs run with piped/closed stdin
    Icr::LineEditor.new.should be_a(Icr::BasicLineEditor)
  end
end
{% end %}

describe Icr::BasicLineEditor do  it "prints the prompt and returns the line" do
    input = IO::Memory.new("1 + 1\n")
    output = IO::Memory.new
    editor = Icr::BasicLineEditor.new(input, output)
    editor.read_line("icr> ", [] of String).should eq("1 + 1")
    output.to_s.should eq("icr> ")
  end

  it "returns nil on EOF" do
    editor = Icr::BasicLineEditor.new(IO::Memory.new, IO::Memory.new)
    editor.read_line("icr> ", [] of String).should be_nil
  end
end

describe "syntax highlighting" do
  # Same stdlib highlighter `crystal i` uses (Crystal::ReplReader#highlight),
  # so icr's input line and the interpreter's echo match token for token.
  it "colors keywords and idents like the interpreter echo" do
    hl = Crystal::SyntaxHighlighter::Colorize.highlight!("def f(x)")
    hl.should contain("\e[91mdef\e[39m") # keyword → light red
    hl.should contain("\e[92mf\e[39m")   # ident after def → light green
  end

  it "falls back to the plain line on unlexable mid-typing input" do
    Crystal::SyntaxHighlighter::Colorize.highlight!(%("open)).should eq(%("open))
  end
end

describe Icr::Completion::Completer do
  it "extracts the fragment being completed at the cursor" do
    fixture = [
      "T\tMyMath\tmodule",
      "M\tMyMath\ts\tsquare\tx : Int32\tInt32",
      "C\tMyMath\tPI",
    ].join("\n")
    index = Icr::Completion::Index.new(fixture)

    Icr::Completion::Completer.fragment("MyMath.sq", 9).should eq("sq")
    Icr::Completion::Completer.fragment("MyMa", 4).should eq("MyMa")
    Icr::Completion::Completer.fragment("x + ", 4).should be_nil
  end
end

describe Icr::CompletionDialog do
  fixture = [
    "T\tMyMath\tmodule",
    "M\tMyMath\ts\tsquare\tx : Int32\tInt32",
    "C\tMyMath\tPI",
  ].join("\n")
  index = Icr::Completion::Index.new(fixture)

  many = (1..15).join('\n') { |i| "T\tThing#{i.to_s.rjust(2, '0')}\tclass" }
  big_index = Icr::Completion::Index.new(many)

  it "opens with candidates for the token before the cursor" do
    dialog = Icr::CompletionDialog.new
    dialog.update("MyMa", 4, index)
    dialog.active?.should be_true
    dialog.candidates.should contain("MyMath")
    dialog.update("MyMath.", 7, index)
    dialog.candidates.should eq(["square"]) # methods after the dot, not constants
    dialog.update("MyMath::P", 8, index)
    dialog.candidates.should eq(["MyMath::PI"]) # constants behind ::
  end

  it "moves the selection and scrolls to keep it visible" do
    dialog = Icr::CompletionDialog.new
    dialog.update("Thing", 5, big_index)
    dialog.candidates.size.should eq(15)
    10.times { dialog.move(1) }
    dialog.selected.should eq(10)
    dialog.offset.should eq(1)
    labels, selected = dialog.visible
    labels.size.should eq(Icr::CompletionDialog::ROWS)
    selected.should eq(9)
    labels[selected].should eq("Thing11")
    20.times { dialog.move(-1) } # no wrap — stops at the top
    dialog.selected.should eq(0)
    dialog.offset.should eq(0)
  end

  it "stays dismissed until the input before the cursor changes" do
    dialog = Icr::CompletionDialog.new
    dialog.update("MyMa", 4, index)
    dialog.dismiss("MyMa", 4)
    dialog.active?.should be_false
    dialog.update("MyMa", 4, index) # same context: stays hidden
    dialog.active?.should be_false
    dialog.update("MyMat", 5, index) # more typing: reopens
    dialog.active?.should be_true
  end

  it "closes when the cursor leaves completable input" do
    dialog = Icr::CompletionDialog.new
    dialog.update("MyMa", 4, index)
    dialog.update("MyMath + ", 9, index)
    dialog.active?.should be_false
  end
end

describe Icr::KeyParser do
  it "parses plain chars, Enter and Backspace" do
    parser = Icr::KeyParser.new
    parser.parse_one("a".bytes)[0].not_nil!.char.should eq('a')
    parser.parse_one([13_u8])[0].not_nil!.key.enter?.should be_true
    parser.parse_one([127_u8])[0].not_nil!.key.backspace?.should be_true
  end

  it "parses CSI arrows, Home, End and Delete" do
    parser = Icr::KeyParser.new
    parser.parse_one("\e[A".bytes)[0].not_nil!.key.up?.should be_true
    parser.parse_one("\e[B".bytes)[0].not_nil!.key.down?.should be_true
    parser.parse_one("\e[C".bytes)[0].not_nil!.key.right?.should be_true
    parser.parse_one("\e[D".bytes)[0].not_nil!.key.left?.should be_true
    parser.parse_one("\e[H".bytes)[0].not_nil!.key.home?.should be_true
    parser.parse_one("\e[3~".bytes)[0].not_nil!.key.delete?.should be_true
    parser.parse_one("\e[4~".bytes)[0].not_nil!.key.end?.should be_true
  end

  it "parses SS3 arrows and reports consumed length" do
    parser = Icr::KeyParser.new
    event, consumed = parser.parse_one("\eOD".bytes) # left
    event.not_nil!.key.left?.should be_true
    consumed.should eq(3)
  end

  it "treats a lone \\e as Escape, waits for more bytes on \\e[ alone" do
    parser = Icr::KeyParser.new
    event, consumed = parser.parse_one([27_u8])
    event.not_nil!.key.escape?.should be_true
    consumed.should eq(1)
    parser.parse_one("\e[".bytes)[1].should eq(0)
  end

  it "decodes multi-byte UTF-8 as one Char event" do
    parser = Icr::KeyParser.new
    event, consumed = parser.parse_one("ф".bytes)
    event.not_nil!.char.should eq('ф')
    consumed.should eq("ф".bytesize)
  end
end

describe Icr::EditState do
  it "edits at the cursor" do
    state = Icr::EditState.new([] of String)
    "ab".each_char { |c| state.handle(Icr::KeyEvent.char(c)) }
    state.handle(Icr::KeyEvent.new(Icr::Key::Left))
    state.handle(Icr::KeyEvent.char('c'))
    state.buffer.should eq("acb")
    state.cursor.should eq(2)

    state.handle(Icr::KeyEvent.new(Icr::Key::End))
    state.handle(Icr::KeyEvent.new(Icr::Key::Delete))
    state.buffer.should eq("acb")
    state.handle(Icr::KeyEvent.new(Icr::Key::Backspace))
    state.buffer.should eq("ac")

    state.handle(Icr::KeyEvent.new(Icr::Key::Home))
    state.handle(Icr::KeyEvent.new(Icr::Key::Delete))
    state.buffer.should eq("c")
    state.cursor.should eq(0)
  end

  it "navigates history preserving the draft" do
    history = ["p", "q"]
    state = Icr::EditState.new(history)
    state.handle(Icr::KeyEvent.char('d'))
    state.handle(Icr::KeyEvent.new(Icr::Key::Up))   # → "q"
    state.buffer.should eq("q")
    state.handle(Icr::KeyEvent.new(Icr::Key::Up))   # → "p"
    state.buffer.should eq("p")
    state.handle(Icr::KeyEvent.new(Icr::Key::Down)) # → "q"
    state.buffer.should eq("q")
    state.handle(Icr::KeyEvent.new(Icr::Key::Down)) # → draft
    state.buffer.should eq("d")
  end
end

def with_env(key, value)
  old = ENV[key]?
  value ? (ENV[key] = value) : ENV.delete(key)
  begin
    yield
  ensure
    if old
      ENV[key] = old
    else
      ENV.delete(key)
    end
  end
end
