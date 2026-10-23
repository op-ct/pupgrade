require 'json'
require 'open3'
require 'tmpdir'
require 'yaml'
require 'puppet'
require 'facter'

require 'driftless/inputs/manifest_parser'
require 'driftless/inputs/module_metadata'

module Pupgrade
  module Surface
    # Reads one module's API surfaces into a document: classes and defined
    # types with their parameters, functions of every kind with their
    # signatures, type aliases, resource types with their attributes,
    # providers with their confines and commands, and facts by name.
    #
    # Ruby surfaces are read by loading the module's code, so this runs in a
    # process of its own (see {Surface.extract}); nothing here is undone.
    module Extract
      SCHEMA_VERSION = 2

      module_function

      # @param dir [String] the module directory
      # @param modulepath [Array<String>] see {#document}
      # @return [String] the document as JSON
      def json(dir, modulepath = [])
        JSON.pretty_generate(document(dir, modulepath: modulepath)) + "\n"
      end

      # @param dir [String] the module directory
      # @param modulepath [Array<String>] directories whose modules the
      #   module's Ruby may need: types its providers extend, libraries it
      #   requires. The module's own parent directory is always first.
      # @return [Hash] the document; `errors` lists files that could not be read
      def document(dir, modulepath: [])
        dir = File.expand_path(dir)
        boot!
        hook_definitions!
        errors = []
        within_environment(dir, modulepath) do |loaders|
          classes, defines = manifests(dir, errors)
          loaded = load_plugins(dir, errors)
          {
            'document'       => 'surface',
            'schema_version' => SCHEMA_VERSION,
            'puppet_version' => Puppet.version,
            'module'         => module_info(dir),
            'metadata'       => metadata_info(dir),
            'source'         => source(dir),
          'classes'        => classes,
          'defined_types'  => defines,
            'functions'      => puppet_functions(dir, errors).merge(ruby_functions(dir, errors, loaders), legacy_functions(dir, errors)).sort.to_h,
            'type_aliases'   => type_aliases(dir, errors),
            'types'          => types(loaded),
            'providers'      => providers(dir),
            'facts'          => facts(dir, errors),
            'errors'         => errors,
          }
        end
      end

      # An environment whose modulepath starts with the module's own parent
      # directory, so Puppet's autoloader and loaders see the module by name
      # and the modules it depends on, and every module's lib on the load
      # path for what its Ruby requires.
      #
      # @yieldparam loaders [Puppet::Pops::Loaders]
      def within_environment(dir, modulepath)
        dirs = ([File.dirname(dir)] + modulepath.map { |m| File.expand_path(m) }).uniq
        dirs.each { |d| Dir.glob(File.join(d, '*', 'lib')).each { |lib| $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib) } }
        env     = Puppet::Node::Environment.create(:pupgrade_surface, dirs)
        loaders = Puppet::Pops::Loaders.new(env)
        Puppet.override(environments: Puppet::Environments::Static.new(env), current_environment: env, loaders: loaders) do
          yield loaders
        end
      end

      # Where the module came from: its git commit and tag when it is a clone.
      def source(dir)
        return { 'dir' => dir } unless File.exist?(File.join(dir, '.git'))

        sha = git(dir, 'rev-parse', 'HEAD')
        tag = git(dir, 'describe', '--tags', '--exact-match', 'HEAD')
        { 'dir' => dir, 'sha' => sha, 'ref' => tag }.compact
      end

      def git(dir, *args)
        out, _err, status = Open3.capture3('git', '-C', dir, *args)
        status.success? ? out.strip : nil
      rescue Errno::ENOENT
        nil
      end

      # Puppet's settings under a scratch directory, once per process.
      def boot!
        return if Puppet.settings.global_defaults_initialized?

        scratch = Dir.mktmpdir('pupgrade-surface')
        Puppet.initialize_settings([])
        %i[confdir vardir codedir logdir rundir statedir].each { |s| Puppet[s] = scratch }
      end

      def module_info(dir)
        metadata = ::Driftless::Inputs::ModuleMetadata.load(dir)
        { 'name' => metadata.name, 'version' => metadata.version }
      end

      # What metadata.json declares about the module's place among others:
      # the surfaces `module diff` compares beside the code's.
      def metadata_info(dir)
        metadata = ::Driftless::Inputs::ModuleMetadata.load(dir)
        {
          'dependencies'            => metadata.dependencies.sort.to_h,
          'requirements'            => metadata.requirements.sort.to_h,
          'operatingsystem_support' => metadata.operatingsystem_support.sort.to_h { |os, rel| [os, Array(rel).map(&:to_s)] },
        }
      end

      # ---- Puppet-language surfaces -----------------------------------------

      # @return [Array(Hash, Hash)] classes and defined types by name
      def manifests(dir, errors)
        classes = {}
        defines = {}
        each_program(dir, 'manifests/**/*.pp', errors) do |program, rel|
          program._pcore_all_contents([]) do |node|
            case node
            when Puppet::Pops::Model::HostClassDefinition
              classes[node.name] = { 'file' => rel, 'params' => parameters(node.parameters) }
            when Puppet::Pops::Model::ResourceTypeDefinition
              defines[node.name] = { 'file' => rel, 'params' => parameters(node.parameters) }
            end
          end
        end
        [classes.sort.to_h, defines.sort.to_h]
      end

      def puppet_functions(dir, errors)
        found = {}
        each_program(dir, 'functions/**/*.pp', errors) do |program, rel|
          program._pcore_all_contents([]) do |node|
            next unless node.is_a?(Puppet::Pops::Model::FunctionDefinition)

            found[node.name] = { 'kind' => 'puppet', 'file' => rel, 'params' => parameters(node.parameters),
                                 'return_type' => text(node.return_type) }
          end
        end
        found
      end

      # The parser gives an alias's type expression no extent of its own, so
      # its text is taken from the source: from its first positioned part to
      # the next alias in the file, or the file's end, trailing comments
      # dropped.
      def type_aliases(dir, errors)
        found = {}
        each_program(dir, 'types/**/*.pp', errors) do |program, rel|
          aliases = []
          program._pcore_all_contents([]) { |node| aliases << node if node.is_a?(Puppet::Pops::Model::TypeAlias) }
          aliases.sort_by!(&:offset)
          aliases.each_with_index do |node, i|
            source = node.locator.string
            start  = first_offset(node.type_expr) || (node.offset + node.length)
            stop   = aliases[i + 1]&.offset || source.length
            body   = source[start...stop].sub(/\A\s*=\s*/, '')
            body   = body.lines.reverse.drop_while { |l| l.strip.empty? || l.strip.start_with?('#') }.reverse.join.strip
            found[node.name] = { 'file' => rel, 'type' => body }
          end
        end
        found.sort.to_h
      end

      # The smallest offset of any part of the expression that has an extent.
      def first_offset(expr)
        offsets = []
        offsets << expr.offset if expr.respond_to?(:length) && expr.length.to_i.positive?
        expr._pcore_all_contents([]) { |n| offsets << n.offset if n.respond_to?(:length) && n.length.to_i.positive? }
        offsets.min
      end

      def each_program(dir, glob, errors)
        Dir.glob(File.join(dir, glob)).sort.each do |path|
          program, findings = ::Driftless::Inputs::ManifestParser.parse(path)
          rel = relative(path, dir)
          if program.nil?
            findings.each { |f| errors << "#{rel}: #{f.message}" }
            next
          end
          yield program, rel
        end
      end

      # Parameters as the source writes them: type and default text, or nil.
      def parameters(params)
        Array(params).to_h do |p|
          [p.name, { 'type' => text(p.type_expr), 'default' => text(p.value), 'captures_rest' => (p.captures_rest ? true : nil) }.compact]
        end
      end

      def text(expr)
        return nil if expr.nil?
        return expr.to_s unless expr.respond_to?(:locator) && expr.locator

        expr.locator.extract_text(expr.offset, expr.length)
      end

      # ---- Ruby surfaces ----------------------------------------------------------

      # 4.x functions: loaded through the module's own loader, which is what
      # gives a function its local types; a file the loader does not know
      # by its path is evaluated directly instead.
      def ruby_functions(dir, errors, loaders)
        found  = {}
        loader = module_loader(loaders, dir)
        Dir.glob(File.join(dir, 'lib/puppet/functions/**/*.rb')).sort.each do |path|
          rel = relative(path, dir)
          begin
            name = name_from_path(rel, 'lib/puppet/functions/')
            func = loader&.load(:function, name)
            klass = func ? func.class : Object.class_eval(File.read(path), path, 1)
            raise "did not define a function (#{klass.class})" unless klass.is_a?(Class) && klass < Puppet::Functions::Function

            name = klass.name if klass.respond_to?(:name) && klass.name.is_a?(String)
            found[name] = {
              'kind'       => 'ruby4x',
              'file'       => rel,
              'signatures' => klass.dispatcher.signatures.map { |d| signature(d) },
            }
          rescue StandardError, ScriptError => e
            errors << "#{rel}: #{e.class}: #{e.message.lines.first.to_s.strip}"
          end
        end
        found
      end

      # @return [Puppet::Pops::Loader::Loader, nil] the module's private loader
      def module_loader(loaders, dir)
        loaders.private_loader_for_module(File.basename(dir))
      rescue StandardError
        nil
      end

      def signature(dispatch)
        {
          'params'      => dispatch.param_names.map(&:to_s),
          'type'        => dispatch.type.to_s,
          'return_type' => dispatch.type.return_type&.to_s,
          'block'       => dispatch.block_name&.to_s,
        }.compact
      end

      # 3.x functions: the file registers through newfunction, which is
      # replaced to record the name and options instead.
      def legacy_functions(dir, errors)
        found = {}
        captured = []
        hook = Module.new do
          define_method(:newfunction) do |name, options = {}, &_block|
            captured << [name, options]
            nil
          end
        end
        Puppet::Parser::Functions.singleton_class.prepend(hook)
        Dir.glob(File.join(dir, 'lib/puppet/parser/functions/*.rb')).sort.each do |path|
          rel = relative(path, dir)
          captured.clear
          begin
            load path
            raise 'did not call newfunction' if captured.empty?

            captured.each do |name, options|
              found[name.to_s] = { 'kind' => 'ruby3x', 'file' => rel, 'arity' => options[:arity] || -1,
                                   'type' => (options[:type] || :statement).to_s }
            end
          rescue StandardError, ScriptError => e
            errors << "#{rel}: #{e.class}: #{e.message.lines.first.to_s.strip}"
          end
        end
        found
      end

      # ---- resource types and providers -------------------------------------

      # What `provide` and `newtype` were called for, by the file calling
      # them: `[type, provider] => file` and `type => file`. Filled by the
      # hooks for everything loaded in this process, this module's or not.
      PROVIDERS = {} # rubocop:disable Style/MutableConstant
      TYPES     = {} # rubocop:disable Style/MutableConstant

      # Records every type and provider definition as it happens. Puppet
      # loads a type's providers itself when the type loads, from every
      # module on the modulepath, so reading them means watching, not
      # loading: a file loaded twice redefines features and runtime types.
      def hook_definitions!
        return if @hooked

        @hooked = true
        providers = PROVIDERS
        types     = TYPES
        Puppet::Type.singleton_class.prepend(Module.new do
          define_method(:provide) do |provider_name, options = {}, &block|
            providers[[name.to_s.downcase.to_sym, provider_name.to_s.downcase.to_sym]] = Extract.defining_file(block)
            super(provider_name, options, &block)
          end
          define_method(:newtype) do |type_name, options = {}, &block|
            types[type_name.to_s.downcase.to_sym] = Extract.defining_file(block)
            super(type_name, options, &block)
          end
        end)
      end

      # The file a definition came from: the block's, else the nearest
      # plugin file on the stack.
      def defining_file(block)
        file = block&.source_location&.first
        file ||= caller_locations.map(&:path).find { |path| path.include?('/lib/puppet/') }
        file && File.expand_path(file)
      end

      # Loads the module's types, and the types of other modules it ships
      # providers for, through Puppet's autoloader, which loads a type's
      # providers as it goes. Each file loads once.
      #
      # @return [Hash{Symbol => Class}] this module's type classes by name
      def load_plugins(dir, errors)
        env   = Puppet.lookup(:current_environment)
        found = {}
        Dir.glob(File.join(dir, 'lib/puppet/type/*.rb')).sort.each do |path|
          name  = File.basename(path, '.rb').to_sym
          klass = load_type(name, errors, dir)
          next if klass.nil?

          defined_in = TYPES[name]
          if defined_in && !same_file?(defined_in, path)
            errors << "#{relative(path, dir)}: not read; #{name} is defined by #{defined_in}"
            next
          end
          load_providers(klass, errors, dir, env)
          found[name] = klass
        end
        provider_dirs = Dir.glob(File.join(dir, 'lib/puppet/provider/*/*.rb')).map { |f| File.basename(File.dirname(f)).to_sym }.uniq.sort
        provider_dirs.each do |name|
          next if found.key?(name)

          klass = load_type(name, errors, dir, provider_dir: true)
          load_providers(klass, errors, dir, env) if klass
        end
        found
      end

      # @return [Class, nil] the type, loaded by Puppet; on a failure inside
      #   the load, the class `newtype` registered before it, if any
      def load_type(name, errors, dir, provider_dir: false)
        rel   = provider_dir ? "lib/puppet/provider/#{name}" : "lib/puppet/type/#{name}.rb"
        klass = Puppet::Type.type(name)
        errors << "#{rel}: #{provider_dir ? "type #{name} is not loadable here" : "did not define type #{name}"}" if klass.nil?
        klass
      rescue StandardError, ScriptError => e
        errors << "#{failed_file(dir) || rel}: #{e.class}: #{e.message.lines.first.to_s.strip}"
        registered_type(name)
      end

      # The type `newtype` stored, without asking Puppet to load anything.
      def registered_type(name)
        Puppet::Type.enum_for(:eachtype).find { |t| t&.name == name }
      end

      # The file the autoloader marked last: it marks a file just before
      # loading it, so after an exception that is the file that raised, or
      # one it loaded in turn.
      def failed_file(dir)
        file = Puppet::Util::Autoload.loaded.values.last&.first
        return nil unless file

        file.start_with?("#{dir}/") ? relative(file, dir) : file
      end

      # Loads what the type's own loading did not reach: Puppet stops at the
      # first provider file that raises; this records each failure and goes
      # on. Nothing to do when every file loaded.
      def load_providers(klass, errors, dir, env)
        loader = klass.providerloader
        return unless loader

        loader.files_to_load(env).each do |rel|
          name = File.basename(rel, '.rb')
          next if loader.loaded?(name)

          loader.load(name, env)
        rescue StandardError, ScriptError => e
          errors << "#{failed_file(dir) || rel}: #{e.class}: #{e.message.lines.first.to_s.strip}"
        end
        klass.providify unless klass.providers.empty?
      end

      def same_file?(a, b)
        File.expand_path(a) == File.expand_path(b) || (File.exist?(a) && File.exist?(b) && File.realpath(a) == File.realpath(b))
      end

      def types(loaded)
        loaded.sort.to_h do |name, klass|
          attributes = (klass.parameters + klass.validproperties).map(&:to_s).uniq.sort
          [name.to_s, {
            'file'      => "lib/puppet/type/#{name}.rb",
            'ensurable' => klass.validattr?(:ensure),
            'namevars'  => klass.key_attributes.map(&:to_s),
            'features'  => klass.features.map(&:to_s).sort,
            'params'    => attributes.to_h { |a| [a, attribute(klass.attrclass(a.to_sym))] },
          }]
        end
      end

      def attribute(klass)
        values = klass.respond_to?(:value_collection) ? klass.value_collection.values.map(&:to_s) : []
        {
          'kind'     => (klass < Puppet::Property) ? 'property' : 'param',
          'required' => (klass.respond_to?(:required?) && klass.required?) ? true : nil,
          'values'   => values.empty? ? nil : values,
        }.compact
      end

      # The providers this module's files defined, from what the hook saw;
      # a file that defined none is a helper, noted on stderr.
      def providers(dir)
        found = {}
        Dir.glob(File.join(dir, 'lib/puppet/provider/*/*.rb')).sort.each do |path|
          rel     = relative(path, dir)
          entries = PROVIDERS.select { |_, file| same_file?(file, path) }.keys
          if entries.empty?
            warn "surface: #{rel}: defines no provider; taken as a helper"
            next
          end
          entries.each do |type_name, provider|
            type = Puppet::Type.type(type_name)
            next unless type&.providers&.include?(provider)

            klass = type.provider(provider)
            found["#{type_name}/#{provider}"] = {
              'type'     => type_name.to_s,
              'name'     => provider.to_s,
              'file'     => rel,
              'confines' => confines(klass),
              'commands' => (klass.instance_variable_get(:@commands) || {}).keys.map(&:to_s).sort,
              'defaults' => Array(klass.instance_variable_get(:@defaults)).map { |h| h.to_h { |k, v| [k.to_s, Array(v).map(&:to_s)] } },
              'features' => Array(klass.instance_variable_get(:@declared_features)).map(&:to_s).sort,
            }
          end
        end
        found.sort.to_h
      end

      # Each confine as "kind: values", e.g. "exists: /usr/bin/x" or
      # "feature: posix"; a command's own existence check is left out.
      def confines(klass)
        collection = klass.confine_collection
        Array(collection.instance_variable_get(:@confines)).filter_map { |c|
          next if c.respond_to?(:for_binary) && c.for_binary

          kind = c.class.name.to_s.split('::').last.downcase
          "#{kind}: #{Array(c.values).map(&:to_s).join(', ')}"
        }.sort
      end

      # Custom facts by the names they register; external facts by the keys
      # their files hold.
      def facts(dir, errors)
        found = {}
        captured = []
        hook = Module.new do
          define_method(:add) do |name, _options = {}, &_block|
            captured << name
            nil
          end
        end
        Facter.singleton_class.prepend(hook)
        Dir.glob(File.join(dir, 'lib/facter/**/*.rb')).sort.each do |path|
          rel = relative(path, dir)
          captured.clear
          begin
            load path
            captured.each { |name| found[name.to_s.downcase] = { 'file' => rel, 'kind' => 'custom' } }
          rescue StandardError, ScriptError => e
            errors << "#{rel}: #{e.class}: #{e.message.lines.first.to_s.strip}"
          end
        end
        Dir.glob(File.join(dir, 'facts.d/*')).sort.each do |path|
          rel = relative(path, dir)
          begin
            external_fact_names(path).each { |name| found[name.downcase] = { 'file' => rel, 'kind' => 'external' } }
          rescue StandardError => e
            errors << "#{rel}: #{e.class}: #{e.message.lines.first.to_s.strip}"
          end
        end
        found.sort.to_h
      end

      def external_fact_names(path)
        case File.extname(path)
        when '.json' then JSON.parse(File.read(path)).keys
        when '.yaml', '.yml' then (YAML.safe_load(File.read(path)) || {}).keys
        when '.txt' then File.readlines(path).filter_map { |l| l.split('=', 2).first&.strip if l.include?('=') }
        else []
        end
      end

      # "stdlib::shout" for lib/puppet/functions/stdlib/shout.rb
      def name_from_path(rel, prefix)
        rel.delete_prefix(prefix).delete_suffix('.rb').tr('/', ':').gsub(':', '::')
      end

      def relative(path, dir)
        path.delete_prefix("#{dir}/")
      end
    end
  end
end
