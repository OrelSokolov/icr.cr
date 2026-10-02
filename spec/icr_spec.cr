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
    with_env("CRYSTAL_INTERPRETER_PATH", "/bin/sh") do
      Icr.interpreter_bin.should eq("/bin/sh")
    end
  end

  it "returns nil for a missing CRYSTAL_INTERPRETER_PATH" do
    with_env("CRYSTAL_INTERPRETER_PATH", "/nonexistent-crystal") do
      Icr.interpreter_bin.should be_nil
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

  it "clears state on reset" do
    session = Icr::ReplaySession.new
    session.submit("x = 20")
    session.reset
    session.program_source.should be_empty
  end
end

def with_env(key, value)
  old = ENV[key]?
  ENV[key] = value
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
