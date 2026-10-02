INTERPRETER = File.join(ENV["HOME"], ".local/share/icr/crystal/bin/crystal")

desc "Build the icr CLI binary into build/icr"
task :build do
  mkdir_p "build"
  sh "crystal build --release -o build/icr src/cli.cr"
end

desc "Build a local Crystal compiler WITH interpreter support " \
     "(~/.local/share/icr; skipped when already present)"
task :interpreter do
  if File.exist?(INTERPRETER)
    puts "interpreter already present: #{INTERPRETER}"
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

desc "Run specs"
task :spec do
  sh "crystal spec"
end

task default: :spec
