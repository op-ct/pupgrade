require 'pupgrade/cli/base'
require 'pupgrade/cli/catalog'
require 'pupgrade/cli/table'
require 'pupgrade/compile/catalog_diff'

module Pupgrade
  module CLI
    class Catalog
      # `pupgrade catalog diff`
      #
      # What changed between two `catalog compile` runs: one row per
      # difference, by node; exit 1 when the catalogs differ.
      class Diff < Base
        include Table

        register_command name: 'diff', subcommand_of: Catalog
        positional '<from-dir>', '<to-dir>'
        desc 'Compare the catalogs of two compile runs, node by node'
        skip_config_load

        COLUMNS       = %w[certname change resource parameter detail].freeze
        GROUP_COLUMNS = %w[change resource parameter detail nodes].freeze
        SUMMARY_COLUMNS = %w[certname resources params classes edges total].freeze

        # Which kinds each --summary column counts, with the sign shown.
        SUMMARY = {
          'resources' => { 'resource-added' => '+', 'resource-removed' => '-' },
          'params'    => { 'param-added' => '+', 'param-removed' => '-', 'param-changed' => '~' },
          'classes'   => { 'class-added' => '+', 'class-removed' => '-' },
          'edges'     => { 'edge-added' => '+', 'edge-removed' => '-' },
        }.freeze

        # How many node names a --group row lists before counting instead.
        NAMED_NODES = 3

        def execute(argv)
          fatal!('catalog diff takes two directories', help: true) unless argv.size == 2
          check_kinds!
          fatal!('catalog diff: --group and --summary are one or the other', help: true) if @options[:group] && @options[:summary]
          from, to = argv.map { |p| File.expand_path(p) }
          changes  = ::Pupgrade::Compile::CatalogDiff.directories(from, to, ignore_params: Array(@options[:ignore_params]))
          shown    = changes.select { |c| shown?(c) }

          if @options[:summary]
            print_table(SUMMARY_COLUMNS, summary_rows(shown))
          elsif @options[:group]
            print_table(GROUP_COLUMNS, group_rows(shown))
          else
            print_table(COLUMNS, shown.map { |c| [c.certname, c.kind, c.resource.to_s, c.param.to_s, c.detail] })
          end

          nodes = changes.map(&:certname).uniq.size
          count = (shown.size == changes.size) ? "#{changes.size} change(s)" : "#{shown.size} of #{changes.size} change(s) shown"
          ::Pupgrade.logger.notice("catalog diff: #{count} across #{nodes} node(s)")
          exit(shown.empty? ? 0 : 1)
        rescue ::Pupgrade::Compile::CatalogDiff::Error => e
          fatal!("catalog diff: #{e.message}", 3)
        end

        protected

        def configure_parser(o)
          o.separator ''
          o.separator 'Row filters (comma-separated, repeatable; globs are case-insensitive). Hidden rows'
          o.separator 'do not count for the exit status:'
          o.on('--certname=GLOBS', Array, 'Only nodes whose certname matches') { |v| accumulate(:certnames, v) }
          o.on('--resources=GLOBS', Array, 'Only rows whose resource (Type[title]) matches') { |v| accumulate(:resources, v) }
          o.on('--changes=KINDS', Array, "Only these kinds (#{::Pupgrade::Compile::CatalogDiff::KINDS.join(', ')})") { |v| accumulate(:changes, v) }
          o.on('--skip-changes=KINDS', Array, 'Drop these kinds') { |v| accumulate(:skip_changes, v) }
          o.on('--ignore-params=NAMES', Array, 'Parameters never compared') { |v| accumulate(:ignore_params, v) }

          o.separator ''
          o.separator 'Layout:'
          o.on('--group', 'One row per distinct change, with the nodes it appears on') { @options[:group] = true }
          o.on('--summary', 'One row per node with counts: +added -removed ~changed') { @options[:summary] = true }

          o.separator ''
          o.separator 'Each directory is what `compile -o DIR` wrote (DIR/<certname>/catalog.json), or one'
          o.separator 'node\'s directory. Nodes in only one of them are node-missing rows. Exits 1 when'
          o.separator 'the catalogs differ.'
        end

        private

        def shown?(change)
          glob_any?(@options[:certnames], change.certname) &&
            glob_any?(@options[:resources], change.resource.to_s) &&
            (Array(@options[:changes]).empty? || @options[:changes].include?(change.kind)) &&
            !Array(@options[:skip_changes]).include?(change.kind)
        end

        def glob_any?(globs, value)
          Array(globs).empty? || globs.any? { |g| File.fnmatch?(g, value, File::FNM_CASEFOLD) }
        end

        # One row per distinct change across nodes, in first-seen order, with
        # the nodes named when few and counted when many.
        def group_rows(changes)
          changes.group_by { |c| [c.kind, c.resource.to_s, c.param.to_s, c.detail] }.map do |(kind, resource, param, detail), rows|
            names = rows.map(&:certname).uniq.sort
            nodes = (names.size <= NAMED_NODES) ? names.join(', ') : "#{names.size} nodes"
            [kind, resource, param, detail, nodes]
          end
        end

        def summary_rows(changes)
          changes.group_by(&:certname).sort.map do |certname, rows|
            cells = SUMMARY.values.map do |signs|
              parts = signs.filter_map do |kind, sign|
                n = rows.count { |r| r.kind == kind }
                "#{sign}#{n}" if n.positive?
              end
              parts.empty? ? '0' : parts.join(' ')
            end
            [certname] + cells + [rows.size.to_s]
          end
        end

        def check_kinds!
          unknown = (Array(@options[:changes]) + Array(@options[:skip_changes])) - ::Pupgrade::Compile::CatalogDiff::KINDS
          return if unknown.empty?

          fatal!("catalog diff: unknown change kind #{unknown.first.inspect} " \
                 "(known: #{::Pupgrade::Compile::CatalogDiff::KINDS.join(', ')})", help: true)
        end

        def accumulate(key, values)
          (@options[key] ||= []).concat(values)
        end
      end
    end
  end
end
