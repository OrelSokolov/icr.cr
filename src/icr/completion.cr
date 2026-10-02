# Compile-time harvest of the whole program's types and methods into a
# baked table for console autocomplete.
#
# Verified against Crystal 1.21 (see plans/autocomplete.md):
# - a top-level `macro finished` in this file fires at the end of EVERY
#   program that requires icr, after the host app's own code is analyzed;
# - `Object.all_subclasses` walks all classes/structs (stdlib included);
# - modules and enums never appear there, and constant names from
#   `@type.constants` cannot be turned back into types
#   (`MacroId#resolve` doesn't exist), so namespace roots must be passed
#   explicitly — that is what `require_with_autocomplete` is for;
# - annotation args are AST paths and DO resolve
#   (`ann.args.first.resolve`), which is how roots travel from the call
#   site to the harvest at the end of the program.
#
# Programs that never opt in get `TABLE = ""` — zero cost.

module Icr
  # Marks a namespace root (module/enum/class) to include in the table
  # besides the automatically harvested class hierarchy.
  annotation Root; end

  # Opts the program into harvesting without adding roots (used by the
  # standalone CLI so it gets a stdlib+icr table).
  annotation Enabled; end

  # Opt into the baked completion table without requiring anything.
  # Expands to a marker def carrying the annotation; `macro finished`
  # below looks for those markers. (Duplicate defs are legal in Crystal;
  # repeated calls simply re-mark, and the harvest dedupes.)
  macro enable_autocomplete!
    @[::Icr::Enabled]
    def icr_ac_enabled : Nil
    end
  end
end

# Require a dependency AND register its namespace roots for the baked
# autocomplete table. Classes and structs anywhere in the program are
# harvested automatically; modules and enums are invisible to
# `Object.all_subclasses`, so list them as roots:
#
#   require_with_autocomplete "./my_math", MyMath
#
# The require path resolves relative to the calling file, exactly like a
# plain `require`. Roots may be defined later in the program — paths are
# resolved when the whole program has been analyzed.
macro require_with_autocomplete(path, *roots)
  require {{ path }}
  {% for root in roots %}
    @[::Icr::Root({{ root }})]
    def icr_ac_root_{{ root.stringify.gsub(/\W/, "_").id }} : Nil
    end
  {% end %}
end

# The harvest itself. Runs at the very end of the program: collects
# roots from the marker annotations, walks the class hierarchy and the
# roots' ancestors, and bakes one TSV string constant. Line kinds:
#
#   T\t<type>\t<module|class|struct>
#   A\t<type>\t<ancestor>          (flattened, as TypeNode#ancestors gives them)
#   M\t<owner>\t<i|s>\t<name>\t<args>\t<return type>
#   C\t<owner>\t<constant name>
#
# Filtering happens here (visibility, operators, allocate/new/initialize,
# generic-name normalization); deduplication happens at parse time —
# macro-side `includes?` over ~40k lines would be O(n^2) compile time.
macro finished
  {% roots = [] of Nil %}
  {% enabled = false %}
  {% for m in @type.methods %}
    {% for ann in m.annotations(::Icr::Enabled) %}
      {% enabled = true %}
    {% end %}
    {% for ann in m.annotations(::Icr::Root) %}
      {% enabled = true %}
      {% roots << ann.args.first.resolve %}
    {% end %}
  {% end %}

  {% if enabled %}
    # Types to visit: explicit roots ∪ all classes/structs ∪ ancestors.
    {% pending = [] of Nil %}
    {% for r in roots %}
      {% pending << r %}
    {% end %}
    {% for c in ::Object.all_subclasses %}
      {% pending << c %}
    {% end %}
    {% types = [] of Nil %}
    {% for t in pending %}
      {% types << t %}
      {% if !t.module? %}
        {% for a in t.ancestors %}
          {% types << a %}
        {% end %}
      {% end %}
    {% end %}

    {% lines = [] of Nil %}
    # Top-level defs (puts, sleep, rand…) live on the Program type,
    # which the class walk never visits — harvest them under an empty
    # owner so bare-word completion can offer them.
    {% for m in @type.methods %}
      {% if m.visibility.stringify == ":public" && m.name.stringify =~ /\A[A-Za-z_]\w*[?!=]?\z/ && m.name.stringify != "initialize" %}
        {% argstr = "" %}
        {% for a in m.args %}
          {% piece = a.name.stringify %}
          {% if a.restriction.stringify != "" %}
            {% piece = piece + " : " + a.restriction.stringify %}
          {% end %}
          {% if a.default_value.stringify != "" %}
            {% piece = piece + " = " + a.default_value.stringify %}
          {% end %}
          {% argstr = argstr == "" ? piece : argstr + ", " + piece %}
        {% end %}
        {% lines << "M\t\ti\t" + m.name.stringify + "\t" + argstr + "\t" + m.return_type.stringify %}
      {% end %}
    {% end %}
    {% for t in types %}
      {% base = t.name.stringify.split("(").first %}
      {% if base =~ /\A[A-Za-z_]\w*(::[A-Za-z_]\w*)*\z/ %}
      {% kind = t.module? ? "module" : (t.struct? ? "struct" : "class") %}
      {% lines << "T\t" + base + "\t" + kind %}

      {% generic = t.name.stringify.includes?("(") %}
      {% if !generic && !t.module? %}
        {% for a in t.ancestors %}
          {% lines << "A\t" + base + "\t" + a.name.stringify.split("(").first %}
        {% end %}
      {% end %}

      {% if !generic %}
      {% for name in t.constants %}
        {% lines << "C\t" + base + "\t" + name.stringify %}
      {% end %}

      {% for m in t.methods %}
        {% if m.visibility.stringify == ":public" && m.name.stringify =~ /\A[A-Za-z_]\w*[?!=]?\z/ && m.name.stringify != "initialize" %}
          {% argstr = "" %}
          {% for a in m.args %}
            {% piece = a.name.stringify %}
            {% if a.restriction.stringify != "" %}
              {% piece = piece + " : " + a.restriction.stringify %}
            {% end %}
            {% if a.default_value.stringify != "" %}
              {% piece = piece + " = " + a.default_value.stringify %}
            {% end %}
            {% argstr = argstr == "" ? piece : argstr + ", " + piece %}
          {% end %}
          {% lines << "M\t" + base + "\ti\t" + m.name.stringify + "\t" + argstr + "\t" + m.return_type.stringify %}
        {% end %}
      {% end %}

      {% for m in t.class.methods %}
        {% if m.visibility.stringify == ":public" && m.name.stringify =~ /\A[A-Za-z_]\w*[?!=]?\z/ && m.name.stringify != "allocate" && m.name.stringify != "new" %}
          {% argstr = "" %}
          {% for a in m.args %}
            {% piece = a.name.stringify %}
            {% if a.restriction.stringify != "" %}
              {% piece = piece + " : " + a.restriction.stringify %}
            {% end %}
            {% if a.default_value.stringify != "" %}
              {% piece = piece + " = " + a.default_value.stringify %}
            {% end %}
            {% argstr = argstr == "" ? piece : argstr + ", " + piece %}
          {% end %}
          {% lines << "M\t" + base + "\ts\t" + m.name.stringify + "\t" + argstr + "\t" + m.return_type.stringify %}
        {% end %}
      {% end %}
      {% end %}
      {% end %}
    {% end %}

    module ::Icr::Completion
      TABLE = {{ lines.join("\n") }}
    end
  {% else %}
    module ::Icr::Completion
      TABLE = ""
    end
  {% end %}
end
