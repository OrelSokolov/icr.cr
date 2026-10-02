require "spec"
require "../src/icr"

describe Icr::Completion::Index do
  fixture = [
    "T\tMyMath\tmodule",
    "M\tMyMath\ts\tsquare\tx : Int32\tInt32",
    "T\tFoo\tclass",
    "A\tFoo\tReference",
    "A\tFoo\tObject",
    "M\tReference\ti\tdup\t\t",
    "M\tFoo\ti\tbar\ts, n = 1\t",
    "C\tMyMath\tPI",
    "T\tMyMath\tmodule",
  ].join("\n")

  index = Icr::Completion::Index.new(fixture)

  it "parses types, kinds and deduplicates lines" do
    index.type?("MyMath").should eq("module")
    index.type?("Foo").should eq("class")
    index.type?("Nope").should be_nil
  end

  it "collects self-methods" do
    index.self_method_names("MyMath").should eq(["square"])
  end

  it "collects instance methods with inherited ones" do
    index.member_names("Foo").should contain("bar") # own
    index.member_names("Foo").should contain("dup") # from Reference
  end

  it "collects constants" do
    index.constant_names("MyMath").should eq(["PI"])
  end

  it "completes type names by prefix" do
    index.completions("MyMa").should eq(["MyMath"])
    index.completions("zzz").should be_empty
  end

  it "searches by substring, ranked first" do
    hits = index.search("square", 3)
    hits.first.label.should start_with("MyMath.square")
    hits.first.insert.should eq("MyMath.square(")
  end

  it "matches as subsequence when substring fails" do
    index.search("mmsq", 5).map(&.label).should contain("MyMath.square(x : Int32)")
  end

  it "parses an empty table into an empty index" do
    empty = Icr::Completion::Index.new("")
    empty.types.should be_empty
    empty.completions("A").should be_empty
  end
end

describe Icr::Completion::Completer do
  fixture = [
    "T\tMyMath\tmodule",
    "M\tMyMath\ts\tsquare\tx\t",
    "M\tMyMath\ts\tsum\ta, b\t",
    "C\tMyMath\tPI",
    "T\tString\tclass",
  ].join("\n")

  index = Icr::Completion::Index.new(fixture)

  it "completes a unique method after a receiver" do
    insert, cands = Icr::Completion::Completer.complete("MyMath.sq", 9, index)
    insert.should eq("uare")
    cands.should eq(["square"])
  end

  it "reports the ambiguous candidate set without a shared prefix" do
    insert, cands = Icr::Completion::Completer.complete("MyMath.s", 8, index)
    insert.should eq("")
    cands.size.should eq(2) # square + sum share only the typed "s"
    cands.should contain("square")
  end

  it "offers constants after a receiver" do
    _, cands = Icr::Completion::Completer.complete("MyMath.", 7, index)
    cands.should contain("PI")
  end

  it "completes type names as words" do
    insert, cands = Icr::Completion::Completer.complete("MyMa", 4, index)
    insert.should eq("th")
    cands.should contain("MyMath")
  end

  it "does not complete unknown receivers or non-word input" do
    Icr::Completion::Completer.complete("unknown.sq", 10, index)[1].should be_empty
    Icr::Completion::Completer.complete("  ", 2, index)[1].should be_empty
  end
end

describe Icr::KeyParser do
  it "parses Tab and Ctrl-T" do
    parser = Icr::KeyParser.new
    parser.parse_one([9_u8])[0].not_nil!.key.tab?.should be_true
    parser.parse_one([20_u8])[0].not_nil!.key.ctrl_t?.should be_true
  end
end

describe Icr::EditState do
  it "inserts completion text at the cursor" do
    state = Icr::EditState.new([] of String)
    "MyMath.".each_char { |c| state.handle(Icr::KeyEvent.char(c)) }
    state.insert_text("square")
    state.buffer.should eq("MyMath.square")
    state.cursor.should eq(13)
    state.handle(Icr::KeyEvent.new(Icr::Key::Left))
    state.insert_text("()")
    state.buffer.should eq("MyMath.squar()e")
  end
end

describe "require_with_autocomplete (baked table)" do
  it "harvests roots and the class hierarchy at compile time" do
    root = File.expand_path("..", __DIR__)
    dir = File.join(Dir.tempdir, "icr-ac-spec-#{Random::Secure.hex(4)}")
    Dir.mkdir(dir)
    fixture = File.join(dir, "fixture.cr")
    # Crystal resolves require paths only relative to the requiring file
    # (or via CRYSTAL_PATH), so point the fixture at the repo relatively.
    icr_rel = Path.new(root, "src/icr").relative_to?(dir).not_nil!
    math_rel = Path.new(root, "examples/my_math").relative_to?(dir).not_nil!
    begin
      File.write(fixture, <<-SRC)
        require "#{icr_rel}"
        require_with_autocomplete "#{math_rel}", MyMath
        idx = Icr::Completion::Index.default
        puts idx.type?("MyMath")
        puts idx.self_method_names("MyMath").join(",")
        puts idx.type?("String")
      SRC
      out_io = IO::Memory.new
      err_io = IO::Memory.new
      status = Process.run("crystal", {"run", "--no-color", fixture},
        output: out_io, error: err_io)
      status.success?.should be_true, err_io.to_s
      lines = out_io.to_s.lines.map(&.strip)
      lines[0].should eq("module")
      lines[1].should eq("square")
      lines[2].should eq("class")
    ensure
      File.delete(fixture) if File.exists?(fixture)
      Dir.delete(dir) if Dir.exists?(dir)
    end
  end
end
