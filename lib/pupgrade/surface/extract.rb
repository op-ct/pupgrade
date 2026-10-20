require 'json'
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
      SCHEMA_VERSION = 1

      module_function

      # @param dir [String] the module directory
      # @return [String] the document as JSON
      def json(dir)
        JSON.pretty_generate(document(dir)) + "\n"
      end

      # @param dir [String] the module directory
      # @return [Hash] the document; `errors` lists files that could not be read
      def document(dir)
        dir = File.expand_path(dir)
        boot!
        errors = []
        classes, defines = manifests(dir, errors)
        {
          'document'       => 'surface',
          'schema_version' => SCHEMA_VERSION,
          'puppet_version' => Puppet.version,
          'module'         => module_info(dir),
          'classes'        => classes,
          'defined_types'  => defines,
          'functions'      => puppet_functions(dir, errors).merge(ruby_functions(dir, errors), legacy_functions(dir, errors)).sort.to_h,
          'type_aliases'   => type_aliases(dir, errors),
          'types'          => types(dir, errors),
          'providers'      => providers(dir, errors),
          'facts'          => facts(dir, errors),
          'errors'         => errors,
        }
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

      # 4.x functions: each file evaluates to its function class, whose
      # dispatcher holds the signatures.
      def ruby_functions(dir, errors)
        found = {}
        Dir.glob(File.join(dir, 'lib/puppet/functions/**/*.rb')).sort.each do |path|
          rel = relative(path, dir)
          begin
            klass = Object.class_eval(File.read(path), path, 1)
            raise "did not define a function (#{klass.class})" unless klass.is_a?(Class) && klass < Puppet::Functions::Function

            name = (klass.respond_to?(:name) && klass.name.is_a?(String)) ? klass.name : name_from_path(rel, 'lib/puppet/functions/')
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

      def types(dir, errors)
        found = {}
        Dir.glob(File.join(dir, 'lib/puppet/type/*.rb')).sort.each do |path|
          rel  = relative(path, dir)
          name = File.basename(path, '.rb')
          begin
            load path
            klass = Puppet::Type.type(name)
            raise "did not define type #{name}" unless klass

            attributes = (klass.parameters + klass.validproperties).map(&:to_s).uniq.sort
            found[name] = {
              'file'      => rel,
              'ensurable' => klass.validattr?(:ensure),
              'namevars'  => klass.key_attributes.map(&:to_s),
              'features'  => klass.features.map(&:to_s).sort,
              'params'    => attributes.to_h { |a| [a, attribute(klass.attrclass(a.to_sym))] },
            }
          rescue StandardError, ScriptError => e
            errors << "#{rel}: #{e.class}: #{e.message.lines.first.to_s.strip}"
          end
        end
        found
      end

      def attribute(klass)
        values = klass.respond_to?(:value_collection) ? klass.value_collection.values.map(&:to_s) : []
        {
          'kind'     => (klass < Puppet::Property) ? 'property' : 'param',
          'required' => (klass.respond_to?(:required?) && klass.required?) ? true : nil,
          'values'   => values.empty? ? nil : values,
        }.compact
      end

      def providers(dir, errors)
        found = {}
        Dir.glob(File.join(dir, 'lib/puppet/provider/*/*.rb')).sort.each do |path|
          rel       = relative(path, dir)
          type_name = File.basename(File.dirname(path))
          name      = File.basename(path, '.rb')
          begin
            type = Puppet::Type.type(type_name)
            raise "type #{type_name} is not loadable here" unless type

            load path
            klass = type.provider(name)
            raise "did not define provider #{name} for #{type_name}" unless klass

            found["#{type_name}/#{name}"] = {
              'type'     => type_name,
              'name'     => name,
              'file'     => rel,
              'confines' => confines(klass),
              'commands' => (klass.instance_variable_get(:@commands) || {}).keys.map(&:to_s).sort,
              'defaults' => Array(klass.instance_variable_get(:@defaults)).map { |h| h.to_h { |k, v| [k.to_s, Array(v).map(&:to_s)] } },
              'features' => Array(klass.instance_variable_get(:@declared_features)).map(&:to_s).sort,
            }
          rescue StandardError, ScriptError => e
            errors << "#{rel}: #{e.class}: #{e.message.lines.first.to_s.strip}"
          end
        end
        found
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
