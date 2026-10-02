INTERPRETER = File.join(ENV["HOME"] || Dir.home, ".local/share/icr/crystal/bin/crystal")
WINDOWS = Gem.win_platform?
EXE = WINDOWS ? "icr.exe" : "icr"
# /usr/local needs sudo on Unix; on Windows a user-writable default
# (%USERPROFILE%\.local) avoids the UAC prompt entirely.
DEFAULT_PREFIX = WINDOWS ? File.join(ENV["USERPROFILE"] || Dir.home, ".local") : "/usr/local"
PREFIX = ENV["PREFIX"] || DEFAULT_PREFIX

desc "Build the icr CLI binary into build/"
task :build do
  mkdir_p "build"
  sh "crystal build --release -o build/#{EXE} src/cli.cr"
end

desc "Install the release binary to PREFIX/bin (default /usr/local on " \
     "Linux/macOS — needs sudo; PREFIX=$HOME/.local or on Windows " \
     "%USERPROFILE%\\.local for a user install)"
task install: :build do
  bindir = File.join(PREFIX, "bin")
  mkdir_p bindir
  dest = File.join(bindir, EXE)
  cp "build/#{EXE}", dest
  chmod 0755, dest
  puts "Installed #{dest}"
  paths = ENV["PATH"] ? ENV["PATH"].split(File::PATH_SEPARATOR) : []
  puts "Note: add #{bindir} to PATH to call `icr` from anywhere." unless paths.include?(bindir)
end

desc "Remove the installed binary (same PREFIX as install)"
task :uninstall do
  dest = File.join(PREFIX, "bin", EXE)
  rm_f dest
  puts "Removed #{dest}"
end

desc "Build a local Crystal compiler WITH interpreter support " \
     "(~/.local/share/icr; skipped when already present)"
task :interpreter do
  if WINDOWS
    puts "Live interpreter backend is Unix-only — skipping (icr runs in replay mode on Windows)."
  elsif File.exist?(INTERPRETER)
    green = $stdout.tty? ? "\e[32m" : ""
    reset = $stdout.tty? ? "\e[0m" : ""
    puts "#{green}Using interpreter #{INTERPRETER}#{reset}"
  else
    # Official Linux builds ship without the interpreter, so we compile
    # one from the Crystal sources ourselves. First run takes a while.
    sh "bash scripts/build-interpreter.sh"
  end
end

desc "Run icr (ensures the interpreter is built first)"
task run: :interpreter do
  sh "crystal run --no-color src/cli.cr"
end

desc "Run the library usage demo (examples/library_demo.cr; " \
     "ensures the interpreter is built first)"
task librun: :interpreter do
  sh "crystal run --no-color examples/library_demo.cr"
end

desc "Run specs"
task :spec do
  sh "crystal spec"
end

task default: :spec
