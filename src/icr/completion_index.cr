# Runtime side of the baked completion table: parse `Icr::Completion::TABLE`
# (TSV, see src/icr/completion.cr) and answer completion/search queries.
#
# The table is a flat string constant, so parsing is lazy (first use) and
# dedup happens here — identical lines are skipped, which keeps the
# compile-time harvest O(n).

module Icr::Completion
  # One harvested method: 'i' = instance method, 's' = class/module method.
  record Entry, kind : Char, name : String, args : String, ret : String

  # A search result: what to show and what to insert on selection.
  record Hit, label : String, insert : String

  class Index
    getter types = {} of String => String             # name => module|class|struct
    getter ancestors = {} of String => Array(String)  # type => flattened ancestor names
    getter entries = {} of String => Array(Entry)     # owner => methods (i and s)
    getter constants = {} of String => Array(String)  # owner => constant names

    # Parse a table; also the unit-test entry point (pass any TSV fixture).
    def initialize(table : String)
      seen = Set(String).new
      table.each_line do |line|
        next unless seen.add?(line) # skip exact duplicates from the bake
        parts = line.split('\t')
        case parts[0]?
        when "T"
          if name = parts[1]?
            types[name] = parts[2]? || "class"
          end
        when "A"
          if (name = parts[1]?) && (anc = parts[2]?)
            (ancestors[name] ||= [] of String) << anc
          end
        when "M"
          if (owner = parts[1]?) && (kind_raw = parts[2]?) && (name = parts[3]?)
            entry = Entry.new(kind_raw[0]? || 'i', name, parts[4]? || "", parts[5]? || "")
            (entries[owner] ||= [] of Entry) << entry
          end
        when "C"
          if (owner = parts[1]?) && (name = parts[2]?)
            (constants[owner] ||= [] of String) << name
          end
        end
      end
    end

    @@default : Index?

    # The index baked into THIS program (empty table when never opted in).
    def self.default : Index
      @@default ||= new(TABLE)
    end

    def type?(name : String) : String?
      types[name]?
    end

    # Instance methods reachable on `type`, inherited ones included
    # (ancestor lists were baked flattened, so no recursive walk needed).
    def member_names(type : String) : Array(String)
      names = [] of String
      each_owner(type) do |owner|
        entries[owner]?.try &.each { |e| names << e.name if e.kind == 'i' }
      end
      names.uniq.sort!
    end

    # Class/module-level methods defined on `type` itself (metaclass
    # inheritance isn't baked — `Foo.bar` completes only for defs on Foo).
    def self_method_names(type : String) : Array(String)
      names = [] of String
      entries[type]?.try &.each { |e| names << e.name if e.kind == 's' }
      names.uniq.sort!
    end

    # Methods callable as `type.name(...)`: self-methods always, plus —
    # for MODULES — the module-level defs, which the harvest bakes as
    # 'i' entries (`def sin` inside `module Math` is called Math.sin).
    # Class/struct 'i' entries are instance methods and never apply.
    def dot_method_names(type : String) : Array(String)
      is_module = type?(type) == "module"
      names = [] of String
      entries[type]?.try &.each do |e|
        names << e.name if e.kind == 's' || (is_module && e.kind == 'i')
      end
      names.uniq.sort!
    end

    # Types nested under a namespace: "Math" → the tails after "Math::".
    # The bake stores nested types under their full path names.
    def nested_type_names(namespace : String) : Array(String)
      prefix = "#{namespace}::"
      types.keys.select(&.starts_with?(prefix)).map { |k| k[prefix.size..] }.sort!
    end

    # Top-level defs (puts, sleep, rand…), baked under an empty owner.
    def top_level_method_names : Array(String)
      names = [] of String
      entries[""]?.try &.each { |e| names << e.name if e.kind == 'i' }
      names.uniq.sort!
    end

    # Constant (and nested type) names on `type` — `Math.` → PI, E.
    def constant_names(type : String) : Array(String)
      (constants[type]? || [] of String).uniq.sort!
    end

    # Type names by prefix — for word completion.
    def completions(prefix : String) : Array(String)
      return [] of String if prefix.empty?
      types.keys.select(&.starts_with?(prefix)).sort!
    end

    # Fuzzy search over "Owner.name(args)" / "Owner#name(args)" labels:
    # substring matches rank by position, in-order subsequence matches
    # after them; ties broken alphabetically for stable menus.
    def search(query : String, limit : Int32 = 10) : Array(Hit)
      pool = search_pool
      q = query.downcase
      scored = [] of {Int32, Hit}
      pool.each do |hit|
        label = hit.label.downcase
        score = if idx = label.index(q)
                  idx
                elsif subsequence?(q, label)
                  1_000
                else
                  next
                end
        scored << {score, hit}
      end
      scored.sort_by! { |score, hit| {score, hit.label} }
      scored.first(limit).map &.[1]
    end

    private def each_owner(type : String, &) : Nil
      yield type
      ancestors[type]?.try &.each { |a| yield a }
    end

    @search_pool : Array(Hit)?

    private def search_pool : Array(Hit)
      @search_pool ||= begin
        pool = [] of Hit
        entries.each do |owner, list|
          list.each do |e|
            call = e.args.empty? ? "#{e.name}()" : "#{e.name}(#{e.args})"
            if owner.empty? # top-level defs: no owner prefix
              pool << Hit.new(call, "#{e.name}(")
            elsif e.kind == 's'
              pool << Hit.new("#{owner}.#{call}", "#{owner}.#{e.name}(")
            else
              pool << Hit.new("#{owner}##{call}", "#{e.name}(")
            end
          end
        end
        pool.sort_by! &.label
      end
    end

    private def subsequence?(needle : String, haystack : String) : Bool
      return false if needle.empty? && haystack.empty?
      i = 0
      needle.each_char do |c|
        i = haystack.index(c, i) || return false
        i += 1
      end
      true
    end
  end

  # Pure token-completion logic: what to insert at the cursor and which
  # candidates remain ambiguous. The editor renders the result.
  module Completer
    KEYWORDS = %w[def end class module struct enum require include
                  record property]

    # Three shapes are completed:
    #   "MyMath::P|"  → constants + nested types of MyMath (Math::PI)
    #   "MyMath.sq|"  → methods callable on the type (Math.sin, File.exists?)
    #   "sl|"         → top-level methods + Object methods + types + keywords
    # Bare words complete to what's actually callable at the top level:
    # global defs (puts, sleep…) and Object instance methods — NOT every
    # stdlib method (bare `sqrt` isn't Crystal; that's Math.sqrt, and
    # Ctrl-T searches every method in the table).
    def self.complete(buffer : String, cursor : Int32, index : Index) : {String, Array(String)}
      before = buffer[0...Math.min(cursor, buffer.size)]
      frag = nil

      if match = before.match(/([\w:]+)::(\w*)\z/)
        namespace, frag = match[1], match[2]
        # Constants need the namespace itself in the table; nested types
        # don't — the harvest often skips the bare module (only roots and
        # ancestors are baked) while keeping its nested types.
        tails = index.nested_type_names(namespace)
        if index.type?(namespace)
          tails += index.constant_names(namespace)
        elsif tails.empty?
          return {"", [] of String}
        end
        tails = tails.uniq.select(&.starts_with?(frag)).sort!
        cands = tails.map { |t| "#{namespace}::#{t}" }
        {common_prefix(cands, match[0].size), cands}
      elsif match = before.match(/([\w:]+)\.(\w*)\z/)
        receiver, frag = match[1], match[2]
        return {"", [] of String} unless index.type?(receiver)
        cands = index.dot_method_names(receiver).select(&.starts_with?(frag))
        {common_prefix(cands, frag.size), cands}
      elsif match = before.match(/((?:\w+::)*\w+)\z/)
        frag = match[1]
        cands = (index.completions(frag) + KEYWORDS.select(&.starts_with?(frag)) +
                 index.top_level_method_names.select(&.starts_with?(frag)) +
                 index.member_names("Object").select(&.starts_with?(frag)))
                  .uniq.sort!
        {common_prefix(cands, frag.size), cands}
      else
        return {"", [] of String}
      end
    end

    # The part of the candidates' common prefix past the typed fragment.
    private def self.common_prefix(cands : Array(String), frag_size : Int32) : String
      return "" if cands.empty?
      prefix = cands.first
      cands.each do |c|
        while !c.starts_with?(prefix)
          prefix = prefix.rchop
        end
      end
      prefix.size <= frag_size ? "" : prefix[frag_size..]
    end

    # The typed tail being completed at the cursor — the text a dialog
    # candidate extends: the full "Namespace::frag" path (candidates
    # are full paths), the method fragment after "receiver.", or the
    # plain word fragment. Nil when the cursor isn't on completable
    # input (dialog closes then).
    def self.fragment(buffer : String, cursor : Int32) : String?
      before = buffer[0...Math.min(cursor, buffer.size)]
      if match = before.match(/([\w:]+)::(\w*)\z/)
        match[0]
      elsif match = before.match(/([\w:]+)\.(\w*)\z/)
        match[2]
      elsif match = before.match(/((?:\w+::)*\w+)\z/)
        match[1]
      end
    end
  end
end
