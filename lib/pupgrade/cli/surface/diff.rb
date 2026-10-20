require 'pupgrade/cli/base'
require 'pupgrade/cli/surface'
require 'pupgrade/cli/table'
require 'pupgrade/surface'
require 'pupgrade/surface/diff'

module Pupgrade
  module CLI
    class Surface
      # `pupgrade surface diff`
      #
      # What changed between two surface documents, or two module
      # directories read on the spot: one row per difference; exit 1 when
      # the surfaces differ.
      class Diff < Base
        include Table

        register_command name: 'diff', subcommand_of: Surface
        positional '<from>', '<to>'
        desc 'Compare two modules\' API surfaces (documents or directories)'
        skip_config_load

        COLUMNS         = %w[surface name change detail].freeze
        SUMMARY_COLUMNS = (['surface'] + ::Pupgrade::Surface::Diff::KINDS + ['total']).freeze

        def execute(argv)
          fatal!('surface diff takes two documents or module directories', help: true) unless argv.size == 2
          check_filters!
          from    = ::Pupgrade::Surface.load(argv[0])
          to      = ::Pupgrade::Surface.load(argv[1])
          changes = ::Pupgrade::Surface::Diff.documents(from, to)
          shown   = changes.select { |c| shown?(c) }

          if @options[:summary]
            print_table(SUMMARY_COLUMNS, summary_rows(shown))
          else
            print_table(COLUMNS, shown.map { |c| [c.section, c.name, c.kind, c.detail] })
          end
          count = (shown.size == changes.size) ? "#{changes.size} change(s)" : "#{shown.size} of #{changes.size} change(s) shown"
          ::Pupgrade.logger.info("surface diff: #{count}")
          exit(shown.empty? ? 0 : 1)
        rescue ::Pupgrade::Surface::Error => e
          fatal!("surface diff: #{e.message}", 3)
        end

        protected

        def configure_parser(o)
          o.separator ''
          o.separator 'Row filters (comma-separated, repeatable; globs are case-insensitive). Hidden rows'
          o.separator 'do not count for the exit status:'
          o.on('--surfaces=KINDS', Array, "Only these surfaces (#{(['module'] + ::Pupgrade::Surface::Diff::SECTIONS).join(', ')})") { |v| accumulate(:surfaces, v) }
          o.on('--names=GLOBS', Array, 'Only entries whose name matches') { |v| accumulate(:names, v) }
          o.on('--changes=KINDS', Array, "Only these kinds (#{::Pupgrade::Surface::Diff::KINDS.join(', ')})") { |v| accumulate(:changes, v) }
          o.separator ''
          o.separator 'Layout:'
          o.on('--summary', 'One row per surface with a count per change kind') { @options[:summary] = true }
          o.separator ''
          o.separator 'Each side is a document `surface` wrote, or a module directory to read now.'
          o.separator 'Exits 1 when the surfaces differ.'
        end

        private

        def shown?(change)
          (Array(@options[:surfaces]).empty? || @options[:surfaces].include?(change.section)) &&
            (Array(@options[:changes]).empty? || @options[:changes].include?(change.kind)) &&
            (Array(@options[:names]).empty? || @options[:names].any? { |g| File.fnmatch?(g, change.name, File::FNM_CASEFOLD) })
        end

        def summary_rows(changes)
          changes.group_by(&:section).sort_by { |s, _| (['module'] + ::Pupgrade::Surface::Diff::SECTIONS).index(s) || 99 }.map do |section, rows|
            [section] + ::Pupgrade::Surface::Diff::KINDS.map { |k| rows.count { |r| r.kind == k }.to_s } + [rows.size.to_s]
          end
        end

        def check_filters!
          known_sections = ['module'] + ::Pupgrade::Surface::Diff::SECTIONS
          unknown = Array(@options[:surfaces]) - known_sections
          fatal!("surface diff: unknown surface #{unknown.first.inspect} (known: #{known_sections.join(', ')})", help: true) if unknown.any?
          unknown = Array(@options[:changes]) - ::Pupgrade::Surface::Diff::KINDS
          fatal!("surface diff: unknown change kind #{unknown.first.inspect} (known: #{::Pupgrade::Surface::Diff::KINDS.join(', ')})", help: true) if unknown.any?
        end

        def accumulate(key, values)
          (@options[key] ||= []).concat(values)
        end
      end
    end
  end
end
