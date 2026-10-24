require 'yaml'
require 'json'

require 'pupgrade/cli/base'
require 'pupgrade/cli/root'
require 'pupgrade/cli/compile_options'
require 'pupgrade/cli/table'
require 'pupgrade/config_keys'
require 'pupgrade/module_name'

module Pupgrade
  module CLI
    # `pupgrade lookup`
    #
    # A Hiera lookup as a node would see it: the node from a factset, its
    # top-scope variables from the ENC stand-in, the hierarchy from the
    # deployed control repo, and the manifests compiled first on request.
    # `--list` shows the nodes the factsets describe instead, with the
    # facts and variables that place them in the hierarchy.
    class Lookup < Base
      include Table
      include CompileOptions
      extend ::Pupgrade::ConfigKeys::DSL

      register_command name: 'lookup', subcommand_of: Root
      positional '<key>...'
      desc <<~DESC
Hiera lookup using control repo hierarchy + pupgrade mocks

Mimics `puppet lookup`, but can set top-scope variables *without* compiling
using pupgrades ENC rules or --vars (use --list to preview ENC vars)
      DESC

      config_key 'lookup.columns', type: :array, default: %w[os.name os.release.major],
        about: "Defines the columns displayed by `lookup --list` after the certname:\nColumns can be fact.paths and $vars (every mock ENC-set variable is added)"

      MERGES = %w[first unique hash deep].freeze
      FORMATS = %w[yaml json s].freeze

      def execute(argv)
        repo = control_repo!('lookup')
        return list(repo) if @options[:list]

        explain_options = @options[:explain_options]
        keys = (argv.empty? && explain_options) ? [Puppet::Pops::Lookup::GLOBAL] : argv
        fatal!('lookup takes the keys to look up, with --node CERTNAME; or --list', help: true) if keys.empty?
        fatal!('lookup needs --node CERTNAME: the factset to look up as', help: true) unless @options[:node]

        factset = factset_for(repo, @options[:node])
        session = build_session(repo, 'lookup')
        explain = @options[:explain] || explain_options
        format  = @options[:format] || (explain ? 's' : 'yaml')
        mod     = module_name_for(keys)
        ::Pupgrade.logger.notice("lookup: #{keys.join(', ')} as #{factset.certname}#{" in module #{mod}" if mod}#{', after compiling the manifests' if @options[:compile]}")
        status = 0
        begin
          session.scope(factset, compile: @options[:compile]) do |top, node|
            ::Pupgrade.logger.info("lookup: #{factset.certname}: variables #{node.vars.inspect}")
            scope = class_scope(top, mod)
            invocation = Puppet::Pops::Lookup::Invocation.new(scope, {}, {}, explain ? Puppet::Pops::Lookup::Explainer.new(explain_options, explain_options && !@options[:explain]) : nil)
            begin
              value = Puppet::Pops::Lookup.lookup(keys, nil, nil, false, merge_options, invocation)
              puts render(value, format) unless explain
            rescue Puppet::DataBinding::LookupError => e
              invocation.report_text { e.message }
              status = 1
            end
            puts((format == 's') ? invocation.explainer.explain : render(invocation.explainer.to_hash, format)) if explain
          end
        ensure
          session.close
        end
        exit status
      rescue ::Pupgrade::Compile::Leak, Puppet::Error => e
        fatal!("lookup: #{e.message}", 3)
      end

      protected

      def configure_parser(o)
        declare_repo_and_factsets(o)
        o.on('-n', '--node=CERTNAME', 'The factset to look up as, by certname (case-insensitive)') { |v| @options[:node] = v }
        o.on('--[no-]compile', 'Compile the manifests first, so variables they set reach the hierarchy') { |v| @options[:compile] = v }
        o.on('--module-name=NAME', 'The module $module_name names, as in a class of it (default: the key\'s first segment; "" for none)') { |v| @options[:module_name] = v }
        o.on('--explain', 'Explain how the lookup went and where the value came from, as `puppet lookup --explain`') { @options[:explain] = true }
        o.on('--explain-options', 'Explain the lookup_options for the key, as `puppet lookup --explain-options`') { @options[:explain_options] = true }
        o.on('--merge=STRATEGY', MERGES, "How to merge values found at several levels (#{MERGES.join(', ')}; default: first)") { |v| @options[:merge] = v }
        o.on('--render-as=FORMAT', FORMATS, 'yaml (default), json, or s (default with --explain)') { |v| @options[:format] = v }
        o.separator ''
        o.separator 'Listing nodes:'
        o.on('--list', 'List the nodes the factsets describe, with the columns, instead of looking up') { @options[:list] = true }
        o.on('--columns=COLUMNS[,…]', Array, 'Facts and ENC $vars to show (config: lookup.columns)') { |v| accumulate(:columns, v) }
        o.on('--certname=GLOB[,…]', Array, 'Lookup factsets with matching certnames') { |v| accumulate(:certnames, v) }
        declare_what_to_compile(o,'Puppet/Compiler options')
        declare_guard(o)
        o.separator ''
      end

      private

      # @return [Compile::Factset] the one factset the certname names
      def factset_for(repo, certname)
        found = load_factsets(repo, 'lookup').select { |f| f.certname.casecmp?(certname) }
        fatal!("lookup: no factset is #{certname.inspect} (--list shows them)", 3) if found.empty?
        found.first
      end

      # The module a class of the key's namespace would set $module_name to,
      # so a `%{module_name}` tier applies as it does in a compile; nil for
      # a key with no namespace, or when told none.
      #
      # @return [String, nil]
      def module_name_for(keys)
        return (@options[:module_name].empty? ? nil : @options[:module_name]) if @options.key?(:module_name)

        first = keys.first.to_s
        first.include?('::') ? first.split('::').first : nil
      end

      # A scope below the top one with $module_name set, as a class scope
      # has it; the top scope itself when there is no module.
      def class_scope(top, mod)
        return top unless mod

        scope = top.newscope
        scope['module_name'] = mod
        scope
      end

      def merge_options
        strategy = @options[:merge] || 'first'
        (strategy == 'deep') ? { 'strategy' => 'deep', 'merge_hash_arrays' => true } : strategy
      end

      def render(value, format)
        case format
        when 'json' then JSON.pretty_generate(value)
        when 's'    then value.is_a?(String) ? value : value.inspect
        else YAML.dump(value)
        end
      end

      # One row per factset: the certname, the configured facts, and every
      # top-scope variable the ENC stand-in sets on any node.
      def list(repo)
        factsets = load_factsets(repo, 'lookup')
        enc      = build_enc(repo)
        nodes    = factsets.map { |f| [f, enc.resolve(f)] }
        columns  = Array(@options[:columns]).flat_map { |c| c.split(',') }
        columns  = (@options[:default_columns] || []) if columns.empty?
        columns += nodes.flat_map { |_, n| n.vars.keys.map { |v| "$#{v}" } }.uniq.sort - columns
        rows = nodes.map do |factset, node|
          [factset.certname] + columns.map { |c| c.start_with?('$') ? node.vars[c[1..]].to_s : node.fact(c).to_s }
        end
        print_table(['certname'] + columns, rows)
        ::Pupgrade.logger.notice("lookup: #{rows.size} node(s)")
        exit 0
      rescue ::Pupgrade::Compile::Enc::Error => e
        fatal!("lookup: #{e.message}", 3)
      end

      def config_defaults
        compile_config_defaults.merge(default_columns: ::Pupgrade.config.dig('lookup', 'columns') || %w[os.name os.release.major])
      end
    end
  end
end
