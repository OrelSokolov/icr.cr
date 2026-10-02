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

describe Icr::LineEditor do
  it "picks the basic editor when stdin is not a TTY" do
    STDIN.tty?.should be_false # specs run with piped/closed stdin
    Icr::LineEditor.new.should be_a(Icr::BasicLineEditor)
  end
end

describe Icr::BasicLineEditor do
  it "prints the prompt and returns the line" do
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

  it "asks for more bytes on an incomplete escape sequence" do
    parser = Icr::KeyParser.new
    parser.parse_one([27_u8])[1].should eq(0)
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
