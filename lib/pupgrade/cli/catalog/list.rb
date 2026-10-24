require 'json'

require 'pupgrade/cli/base'
require 'pupgrade/cli/catalog'
require 'pupgrade/cli/table'
require 'pupgrade/cli/compile_options'

module Pupgrade
  module CLI
    class Catalog
      # `pupgrade catalog list`
      #
      # The compiles the cache holds: one row per node, from the probes
      # record and the catalog each compile wrote.
      class List < Base
        include Table
        include CompileOptions

        register_command name: %w[list ls], subcommand_of: Catalog
        desc 'List the compiled catalogs in the cache'

        COLUMNS = %w[certname status resources classes warnings leaks compiled].freeze

        def execute(argv)
          reject_extra_args!(argv)
          repo = control_repo!('catalog list')
          dir  = File.expand_path(@options[:cache_dir], repo.dir)
          fatal!("catalog list: #{dir} is not there; `catalog compile` writes it", 3) unless File.directory?(dir)

          rows = nodes(dir).map { |name| row(dir, name) }
          print_table(COLUMNS, rows)
          ::Pupgrade.logger.notice("catalog list: #{rows.size} node(s) in #{dir}")
          exit 0
        end

        protected

        def configure_parser(o)
          o.on('-d', '--repo-dir=DIR', 'Path of deployed control repository (Default: `.`)') { |v| @options[:repo_dir] = v }
          o.on('--cache-dir=DIR', 'The compile cache to list (config: compile.cache_dir)') { |v| @options[:cache_dir] = v }
          o.on('--certname=GLOB[,…]', Array, 'Only nodes whose certname matches') { |v| accumulate(:certnames, v) }
        end

        private

        # The node directories, narrowed by --certname.
        def nodes(dir)
          globs = Array(@options[:certnames])
          Dir.children(dir).select { |n| File.file?(File.join(dir, n, 'probes.json')) }.sort
            .select { |n| globs.empty? || globs.any? { |g| File.fnmatch?(g, n, File::FNM_CASEFOLD) } }
        end

        def row(dir, name)
          probes  = JSON.parse(File.read(File.join(dir, name, 'probes.json')))
          catalog = File.file?(File.join(dir, name, 'catalog.json')) ? JSON.parse(File.read(File.join(dir, name, 'catalog.json'))) : nil
          leaks   = Array(probes['leaks']).count { |l| !l['action'].to_s.start_with?('mocked') }
          status  = (probes['status'] == 'ok') ? paint('ok', :green) : paint(probes['status'].to_s, :red)
          [name, status,
           catalog ? catalog['resources'].size.to_s : '-',
           catalog ? catalog['classes'].size.to_s : '-',
           (Array(probes['warnings']).size + Array(probes['deprecations']).size).to_s,
           leaks.to_s,
           File.mtime(File.join(dir, name, 'probes.json')).strftime('%Y-%m-%d %H:%M')]
        rescue JSON::ParserError => e
          [name, paint('unreadable', :red), '-', '-', '-', '-', e.message[0, 40]]
        end

        def config_defaults
          { cache_dir: ::Pupgrade.config.dig('compile', 'cache_dir') || 'pupgrade/cache/catalogs' }
        end
      end
    end
  end
end
