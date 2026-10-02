# Executable entry point for bin/icr.
require "./icr"

# Bake the completion table (stdlib + icr) into the standalone console.
Icr.enable_autocomplete!

Icr::CLI.run
