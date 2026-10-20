require 'puppet'
require 'facter'

require 'pupgrade/compile/stubs'

module Pupgrade
  module Compile
    # Raised inside a compile when module code tries to run a command the
    # stubs do not answer and the run's policy is to stop.
    class Leak < StandardError; end

    # What one node's compile used, as the hooks in {Probes} report it:
    # functions called, facts read, lookups made, providers loaded, warnings
    # and deprecations logged, and commands or facts that reached the
    # execution guard. One per compile; {Probes.current} points at it while
    # the compile runs.
    class Recorder
      LOGGED_LEVELS = %i[warning err alert emerg crit].freeze

      # @param factset [Factset] the node's facts, answering Facter reads
      # @param stubs [Stubs] what the guard answers commands with
      # @param on_leak [String] "raise" or "allow" for commands the stubs do not answer
      # @param repo_dir [String] call sites are reported relative to it
      def initialize(factset:, stubs:, on_leak:, repo_dir:)
        @factset  = factset
        @stubs    = stubs
        @on_leak  = on_leak
        @repo_dir = File.expand_path(repo_dir)
        @prefixes = {}
        @modules  = {}
        @functions = Hash.new { |h, k| h[k] = { 'module' => nil, 'calls' => 0, 'sites' => [] } }
        @facts     = Hash.new(0)
        @legacy    = Hash.new(0)
        @lookups   = Hash.new { |h, k| h[k] = { 'found' => false, 'automatic' => 0, 'explicit' => 0 } }
        @providers = {}
        @aliases   = Hash.new { |h, k| h[k] = { 'module' => nil, 'uses' => 0, 'sites' => [] } }
        @warnings  = []
        @deprecations = []
        @leaks = []
        # Puppet reports each deprecation and each unique warning once per
        # process; reset so every node's compile reports its own.
        $deprecation_warnings = {} # rubocop:disable Style/GlobalVars -- Puppet's own
        $unique_warnings = {} # rubocop:disable Style/GlobalVars -- Puppet's own
      end

      # ---- facts -----------------------------------------------------------

      # Remembers every hash inside `hash` by identity, so a later access on
      # one of them can be named by its path.
      #
      # @param hash [Hash] `$facts` or `$trusted` as the scope holds them
      # @param prefix [String, nil] nil for `$facts`
      def index_hash(hash, prefix)
        return unless hash.is_a?(Hash)

        @prefixes[hash.object_id] = prefix.to_s
        hash.each { |k, v| index_hash(v, [prefix, k.to_s].compact.join('.')) if v.is_a?(Hash) }
      end

      # A `[]` access on a hash: recorded when the hash is inside `$facts`
      # or `$trusted`.
      def hash_access(hash, keys)
        prefix = @prefixes[hash.object_id]
        return if prefix.nil?

        keys.each { |k| @facts[[prefix, k.to_s].reject(&:empty?).join('.')] += 1 }
      end

      # The `dig` function walking keys from a value: recorded when the value
      # is inside `$facts` or `$trusted`, by the path dug.
      def dig(data, keys)
        prefix = @prefixes[data.object_id]
        return if prefix.nil?

        @facts[([prefix] + keys.map(&:to_s)).reject(&:empty?).join('.')] += 1
      end

      # `key in $facts`: a membership test on a hash inside `$facts` or
      # `$trusted`.
      def membership(hash, key)
        prefix = @prefixes[hash.object_id]
        return if prefix.nil? || !key.is_a?(String)

        @facts[[prefix, key].reject(&:empty?).join('.')] += 1
      end

      # A dotted path walked from a value, as Hiera interpolation and the
      # `get`-style functions do.
      def sub_lookup(value, segments)
        prefix = @prefixes[value.object_id]
        return if prefix.nil?

        @facts[([prefix] + segments.map(&:to_s)).reject(&:empty?).join('.')] += 1
      end

      # A variable read: recorded as a legacy fact when the bare name is a
      # top-level fact carrying that value.
      def variable(name, value)
        bare = name.to_s.delete_prefix('::')
        return if bare.include?('::') || !@factset.values.key?(bare)

        @legacy[bare] += 1 if @factset.values[bare] == value
      end

      # A `Facter.value` or `Facter.fact` read from Ruby code.
      #
      # @return [Array(Boolean, Object)] whether anything answered, and the value
      def facter_value(query)
        name = query.to_s.downcase
        found, value = dig_fact(name)
        if found
          @facts["#{name} (Facter)"] += 1
          return [true, value]
        end

        found, value = @stubs.fact(name)
        if found
          leak('fact', name, 'stubbed', nil)
          return [true, value]
        end

        leak('fact', name, 'missing', nil)
        [false, nil]
      end

      # ---- functions and lookups -------------------------------------------

      # @param func [Puppet::Pops::Functions::Function, nil] what the loader gave
      def function_call(name, func, file, line)
        entry = @functions[name.to_s]
        entry['module'] ||= module_of_loader(func&.loader)
        entry['calls'] += 1
        site = site(file, line)
        entry['sites'] << site if site && entry['sites'].size < 20 && !entry['sites'].include?(site)
      end

      # A value checked against a type alias: a parameter typed with it, a
      # match, or a data type expression, once per check. Puppet's own
      # aliases have no namespace; a module's or environment's always do.
      def type_alias(name)
        @aliases[name.to_s]['uses'] += 1 if name.to_s.include?('::')
      end

      # Where an alias is referenced: the parser resolves a definition's
      # parameter types once per environment, so the sites are gathered
      # process-wide by {Probes.alias_sites} and joined here.
      def alias_sites!
        @aliases.each do |name, entry|
          sites = Probes.alias_sites.fetch(name, []).select { |file, _| file.to_s.start_with?("#{@repo_dir}/") }
          entry['sites'] = sites.map { |file, line| site(file, line) }.compact.uniq.first(20)
        end
      end

      def lookup(name, found, automatic)
        entry = @lookups[name.to_s]
        entry['found'] ||= found
        entry[automatic ? 'automatic' : 'explicit'] += 1
      end

      # ---- providers, logs ---------------------------------------------------

      def provider_loaded(type, provider, path)
        @providers["#{type}/#{provider}"] = { 'type' => type.to_s, 'provider' => provider.to_s, 'file' => relative(path) }
      end

      def log(msg)
        return unless LOGGED_LEVELS.include?(msg.level)

        @warnings << { 'level' => msg.level.to_s, 'message' => msg.message.to_s,
                       'file' => msg.file && relative(msg.file.to_s), 'line' => msg.line }.compact
      end

      def deprecation(message, file, line)
        @deprecations << { 'message' => message.to_s, 'file' => file && relative(file.to_s), 'line' => line }.compact
      end

      # ---- the execution guard -------------------------------------------------

      # What to do with a command module code wants to run.
      #
      # @param kind [String] which entry point: "execute", "execpipe", "backtick", ...
      # @param command [String] the command line
      # @return [Array(Symbol, String)] [:stub, stdout] or [:run, nil]
      # @raise [Leak] when nothing answers and the policy is to stop
      def guard(kind, command)
        entry = @stubs.for_command(command)
        if entry&.action == 'stub'
          leak(kind, command, 'stubbed', location)
          return [:stub, entry.stdout]
        end
        if entry || @on_leak == 'allow'
          leak(kind, command, 'allowed', location)
          return [:run, nil]
        end

        where = location
        leak(kind, command, 'raised', where)
        raise Leak, "#{kind}: #{command.inspect} is not answered by the stubs (#{where})"
      end

      # @return [Hash] the probe record, JSON-ready
      def to_h
        alias_sites!
        {
          'functions'    => @functions.sort.to_h,
          'facts'        => @facts.sort.to_h,
          'legacy_facts' => @legacy.sort.to_h,
          'lookups'      => @lookups.sort.to_h,
          'providers'    => @providers.sort.to_h.values,
          'type_aliases' => @aliases.sort.to_h,
          'warnings'     => @warnings,
          'deprecations' => @deprecations,
          'leaks'        => @leaks,
        }
      end

      private

      def leak(kind, what, action, where)
        @leaks << { 'kind' => kind, 'command' => what, 'action' => action, 'location' => where }.compact
      end

      # "file:line" of the innermost Puppet call in progress and the first
      # Ruby frame outside the gems, when there are any.
      def location
        parts = []
        top = Puppet::Pops::PuppetStack.top_of_stack
        if top.is_a?(Array) && top[0] && top[0] != 'unknown'
          parts << "#{relative(top[0])}:#{top[1]}"
        end
        frame = caller_locations(2, 30).find { |l| !l.path.include?('/gems/') && !l.path.include?('pupgrade/compile') }
        parts << "#{relative(frame.path)}:#{frame.lineno}" if frame
        parts.empty? ? nil : parts.join(' via ')
      end

      def site(file, line)
        return nil if file.nil? || file.to_s.empty?

        "#{relative(file)}:#{line}"
      end

      def relative(path)
        path.to_s.delete_prefix("#{@repo_dir}/")
      end

      # @return [Array(Boolean, Object)] a fact by dotted name
      def dig_fact(name)
        values = @factset.values
        return [true, values[name]] if values.key?(name)

        value = values
        name.split('.').each do |seg|
          return [false, nil] unless value.is_a?(Hash) && value.key?(seg)

          value = value[seg]
        end
        [true, value]
      end

      # The module a function's loader belongs to: a module loader is named
      # after its module ("stdlib" or "stdlib private"); loaders for the
      # environment and Puppet itself name no module; a local loader's name
      # is a Symbol, so the parent chain is walked to a named one.
      def module_of_loader(loader)
        loader = loader.parent while loader && loader.loader_name.is_a?(Symbol)
        return nil unless loader

        name = loader.loader_name.to_s.sub(/ private\z/, '')
        %w[puppet_system environment static].include?(name) ? nil : name
      end
    end

    # The hooks into Puppet and Facter that report to {Probes.current}, and
    # the execution guard. Installed once per process; every hook is a
    # pass-through while no compile is running.
    module Probes
      class << self
        # @return [Recorder, nil] the compile in progress
        attr_accessor :current

        # @return [Hash{String => Array<Array(String, Integer)>}] where each
        #   type alias is referenced, by name, for the whole process
        def alias_sites
          @alias_sites ||= Hash.new { |h, k| h[k] = [] }
        end

        def install!
          return if @installed

          @installed = true
          Puppet::Parser::Scope.prepend(ScopeHooks)
          Puppet::Pops::Evaluator::AccessOperator.prepend(AccessHooks)
          Puppet::Pops::Lookup::SubLookup.prepend(SubLookupHooks)
          Puppet::Pops::Evaluator::EvaluatorImpl.prepend(CallHooks)
          Puppet::Functions.singleton_class.prepend(FunctionFactoryHooks)
          Puppet::Pops::Lookup.singleton_class.prepend(LookupHooks)
          Puppet::Pops::Types::TypeParser.prepend(TypeParserHooks)
          Puppet::Pops::Types::PTypeAliasType.prepend(TypeAliasHooks)
          Puppet::Util::Logging.prepend(DeprecationHooks)
          Puppet::Type.singleton_class.prepend(ProviderHooks)
          Puppet::Node::Environment.prepend(ConfigVersionHooks)
          Puppet::Util::Execution.singleton_class.prepend(ExecutionGuard)
          Facter::Core::Execution.singleton_class.prepend(FacterExecutionGuard)
          Facter.singleton_class.prepend(FacterGuard)
          Puppet::Util::Log.newdesttype(:pupgrade_probes) do
            match 'Pupgrade::Compile::Probes::LogSink'

            def initialize(sink)
              @sink = sink
            end

            def handle(msg)
              @sink.call(msg)
            end
          end
        end

        # Makes sure Puppet's log reaches the recorder, through one sink:
        # Puppet keys destinations by the object given, and drops them all
        # whenever it closes its log.
        def attach_log
          @sink ||= LogSink.new
          Puppet::Util::Log.newdestination(@sink) unless Puppet::Util::Log.destinations.key?(@sink)
        end
      end

      # Receives every Puppet log message.
      class LogSink
        def call(msg)
          Probes.current&.log(msg)
        end
      end

      module ScopeHooks
        def set_facts(hash)
          super
          Probes.current&.index_hash(hash, nil)
        end

        def set_trusted(hash)
          super
          Probes.current&.index_hash(hash, 'trusted')
        end

        # Every scope on the way up answers a lookup; the top scope is
        # where a fact lives, so only its answer is recorded.
        def lookupvar(name, options = {})
          value = super
          Probes.current&.variable(name, value) if is_topscope?
          value
        end
      end

      module AccessHooks
        def access_Hash(o, scope, keys) # rubocop:disable Naming/MethodName -- Puppet's name
          Probes.current&.hash_access(o, keys)
          super
        end
      end

      module SubLookupHooks
        def sub_lookup(key, context, segments, value)
          Probes.current&.sub_lookup(value, segments)
          super
        end
      end

      module CallHooks
        # `key in $hash` hands the hash to the evaluator whole.
        def eval_InExpression(o, scope) # rubocop:disable Naming/MethodName -- Puppet's name
          if (rec = Probes.current)
            right = evaluate(o.right_expr, scope)
            rec.membership(right, evaluate(o.left_expr, scope)) if right.is_a?(Hash)
          end
          super
        end

        def call_function(name, args, o, scope, &block)
          if (rec = Probes.current)
            file, line = extract_file_line(o)
            loader = Puppet::Pops::Adapters::LoaderAdapter.loader_for_model_object(o, file)
            func   = loader.load(:function, name) if loader
            rec.function_call(name, func, file, line)
          end
          super
        end
      end

      # Puppet builds a function's class once per loader; the `dig` function
      # gets the hook below as it is created, whichever loader builds it.
      module FunctionFactoryHooks
        def create_function(func_name, function_base = Puppet::Functions::Function, &block)
          klass = super
          klass.prepend(DigHooks) if func_name.to_s == 'dig'
          klass
        end
      end

      # `dig($facts, 'os', 'family')`, which `$facts.dig(...)` also calls,
      # receives the hash itself.
      module DigHooks
        def dig(data, *args)
          Probes.current&.dig(data, args)
          super
        end
      end

      module LookupHooks
        def search_and_merge(name, lookup_invocation, merge, apl = true)
          found = false
          value = super
          found = true
          value
        ensure
          Probes.current&.lookup(name, found, apl)
        end
      end

      # Every type reference the evaluator resolves passes through here; one
      # that resolves to an alias names a site referencing it. Puppet resolves
      # a definition's parameter types once per environment, so this fires
      # for the first compile only and the sites are kept for the process.
      module TypeParserHooks
        def interpret_QualifiedReference(name_ast, context) # rubocop:disable Naming/MethodName -- Puppet's name
          type = super
          if type.is_a?(Puppet::Pops::Types::PTypeAliasType) && Probes.current && name_ast.respond_to?(:file)
            Probes.alias_sites[name_ast.cased_value] << [name_ast.file, name_ast.line]
          end
          type
        end
      end

      # A value checked against an alias, which happens on every compile.
      module TypeAliasHooks
        def instance?(o, guard = nil)
          Probes.current&.type_alias(name)
          super
        end
      end

      module DeprecationHooks
        def issue_deprecation_warning(message, key, file, line, use_caller)
          Probes.current&.deprecation(message, file, line)
          super
        end
      end

      module ProviderHooks
        def provide(name, options = {}, &block)
          Probes.current&.provider_loaded(self.name, name, caller_locations(1, 1).first&.path)
          super
        end
      end

      # A control repo's config_version script would run during the compile;
      # the catalog's version is set from the repo instead.
      module ConfigVersionHooks
        def config_version
          Probes.current ? nil : super
        end
      end

      module ExecutionGuard
        def execute(command, options = {})
          rec = Probes.current
          return super unless rec

          line = command.is_a?(Array) ? command.flatten.join(' ') : command.to_s
          action, stdout = rec.guard('execute', line)
          (action == :stub) ? Puppet::Util::Execution::ProcessOutput.new(stdout, 0) : super
        end

        def execpipe(command, failonfail = true, &block)
          rec = Probes.current
          return super unless rec

          line = command.respond_to?(:join) ? command.join(' ') : command.to_s
          action, stdout = rec.guard('execpipe', line)
          return super unless action == :stub

          block ? yield(StringIO.new(stdout)) : stdout
        end
      end

      module FacterExecutionGuard
        def execute(command, options = {})
          rec = Probes.current
          return super unless rec

          action, stdout = rec.guard('facter-execute', command.to_s)
          (action == :stub) ? stdout : super
        end

        def exec(command)
          rec = Probes.current
          return super unless rec

          action, stdout = rec.guard('facter-exec', command.to_s)
          (action == :stub) ? stdout : super
        end
      end

      FactValue = Struct.new(:name, :value)

      module FacterGuard
        def value(user_query)
          rec = Probes.current
          return super unless rec

          rec.facter_value(user_query).last
        end

        def fact(user_query)
          rec = Probes.current
          return super unless rec

          found, value = rec.facter_value(user_query)
          found ? FactValue.new(user_query.to_s.downcase, value) : nil
        end

        def to_hash
          rec = Probes.current
          rec ? rec.instance_variable_get(:@factset).values : super
        end
      end
    end
  end
end
