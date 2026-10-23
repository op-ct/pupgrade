require 'json'

require 'pupgrade/cli/base'
require 'pupgrade/cli/root'
require 'pupgrade/config_keys'
require 'driftless/control_repo'
require 'pupgrade/surface'
require 'pupgrade/surface/diff'
require 'pupgrade/surface/targets'

module Pupgrade
  module CLI
    # `pupgrade surface`
    #
    # Modules' API surfaces as JSON documents in the cache directory: a
    # module directory or a module of the control repo by name, at the
    # deployed version or at a ref of its clone, several at once, or every
    # module on the modulepath. `module diff` compares two.
    class Surface < Base
      extend ::Pupgrade::ConfigKeys::DSL

      register_command name: 'surface', subcommand_of: Root
      positional '[<module>[:<ref>] ...]'
      desc 'Read modules\' API surfaces (classes, functions, types, providers, facts) into the cache `module diff` and `impact` use'
      runs_without_subcommand

      config_key 'surface.cache_dir', type: :string, default: 'pupgrade/cache/api_surfaces',
                 about: 'Where `surface` keeps each module\'s document, named by module, version, and ref, relative to ' \
                        'the control repo; read from there unless --refresh, or the document is of an older schema'

      # What is shared with `module diff`: finding the repo and building the
      # target reader from the options.
      module Shared
        def repo_option(o)
          o.on('-d', '--repo-dir=DIR', 'The control repo whose modulepath names resolve on',
               "Default: '.' (if environment.conf and hiera.yaml exist)") { |v| @options[:repo_dir] = v }
          o.on('--cache-dir=DIR', 'Where documents are kept (config: surface.cache_dir)') { |v| @options[:cache_dir] = v }
          o.on('--refresh[=WHAT]', %w[all schema], 'Extract again, ignoring the cache (all, the default), or only the cached',
               'documents of an older schema (schema)') { |v| @options[:refresh] = (v || 'all').to_sym }
          o.on('--fetch', 'Fetch a clone\'s origin before reading it at a ref') { @options[:fetch] = true }
        end

        # @return [Driftless::ControlRepo, nil] nil when none is given or found
        def control_repo
          repo = @options[:repo_dir] ? ::Driftless::ControlRepo.new(@options[:repo_dir]) : ::Driftless::ControlRepo.detect(Dir.pwd)
          fatal!("repo-dir not readable: #{repo.dir}", 3) if repo && !repo.readable?
          repo
        end

        def targets
          ::Pupgrade::Surface::Targets.new(repo_dir: control_repo&.dir, cache_dir: @options[:cache_dir],
                                           fetch: @options[:fetch], refresh: @options[:refresh], logger: ::Pupgrade.logger)
        end

        def surface_config_defaults
          { cache_dir: ::Pupgrade.config.dig('surface', 'cache_dir') || 'pupgrade/cache/api_surfaces' }
        end
      end

      include Shared

      def execute(argv)
        reader = targets
        list   = target_list(reader, argv)
        fatal!('surface: -o takes one module', help: true) if @options[:output] && list.size > 1
        ::Pupgrade.logger.notice("surface: reading #{list.size} module(s)#{', ignoring the cache' if (@options[:refresh] == :all)}") if list.size > 1

        list.each_with_index do |target, i|
          puts '' if i.positive?
          doc, path, cached = reader.document(target)
          if @options[:output] == '-'
            print JSON.pretty_generate(doc) + "\n"
          elsif @options[:output]
            File.write(File.expand_path(@options[:output]), JSON.pretty_generate(doc) + "\n")
            puts File.expand_path(@options[:output])
          else
            puts path
          end
          ::Pupgrade.logger.notice(summary(target, doc, cached))
        end
        exit 0
      rescue ::Pupgrade::Surface::Targets::Error, ::Pupgrade::Surface::Error => e
        fatal!("surface: #{e.message}", 3)
      end

      protected

      def configure_parser(o)
        o.on('-o', '--output=FILE', 'Write one module\'s document to FILE instead of the cache; - for stdout') { |v| @options[:output] = v }
        o.on('--all', 'Every module on the control repo\'s modulepath') { @options[:all] = true }
        o.on('--ref=REF', 'Read each module at this ref of its clone, unless the module names its own') { |v| @options[:ref] = v }
        o.on('--git=URL', 'Read the module at --ref of this git remote instead') { |v| @options[:git] = v }
        repo_option(o)
        o.separator ''
        o.separator 'A module is a directory, or a name resolved on the control repo\'s modulepath like'
        o.separator '`module gitlog` does; `stdlib:v9.6.0` reads a ref of the deployed clone. Documents land'
        o.separator 'in the cache as <module>-<version>--<tag>__<sha>.json, keyed on the commit read (the'
        o.separator 'tag is for the eye; a module that is no git checkout is keyed on its version alone), and'
        o.separator 'are reused until --refresh, or until pupgrade\'s document schema moves on, when they are'
        o.separator 'extracted again as read.'
        o.separator 'Loading a module\'s Ruby is how its functions, types, providers, and facts are read, so'
        o.separator 'extraction runs in a process of its own, with the repo\'s modulepath in reach. Files that'
        o.separator 'fail to load are listed under "errors" in the document and warned about. The'
        o.separator 'document also carries what metadata.json declares; `module diff` compares two.'
      end

      private

      def target_list(reader, argv)
        if @options[:git]
          fatal!('surface: --git needs --ref', help: true) if @options[:ref].nil?
          fatal!('surface: --git takes no modules', help: true) unless argv.empty? && !@options[:all]
          return [reader.remote(@options[:git], @options[:ref])]
        end
        return reader.all if @options[:all] && argv.empty?
        fatal!('surface takes modules, --all, or --git URL --ref REF', help: true) if argv.empty?

        argv.map { |spec| reader.resolve(spec, ref: @options[:ref]) }
      end

      def summary(target, doc, cached)
        counts = ::Pupgrade::Surface::Diff::SECTIONS.map { |s| "#{doc[s].size} #{s.tr('_', ' ')}" }.join(', ')
        "surface: #{doc.dig('module', 'name') || target.spec} #{doc.dig('module', 'version')}#{' (cached)' if cached}: #{counts}"
      end

      def config_defaults
        surface_config_defaults
      end
    end
  end
end
