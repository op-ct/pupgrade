require 'pupgrade/cli/base'
require 'pupgrade/cli/module_command'
require 'pupgrade/cli/surface'
require 'pupgrade/cli/table'
require 'pupgrade/surface'
require 'pupgrade/surface/diff'
require 'pupgrade/surface/render'

module Pupgrade
  module CLI
    class ModuleCommand
      # `pupgrade module diff`
      #
      # What changed between two versions of a module: its metadata
      # (dependencies, requirements, operating systems) and its API surfaces,
      # one row per difference, from the documents `surface` keeps. Exit 1
      # when anything differs.
      class Diff < Base
        include Table
        include Surface::Shared

        register_command name: 'diff', subcommand_of: ModuleCommand
        positional '<from>', '<to>'
        desc 'Compare two versions of a module: metadata and API surfaces (documents, directories, or modules at refs)'

        COLUMNS         = %w[item difference detail].freeze
        SUMMARY_COLUMNS = (['surface'] + ::Pupgrade::Surface::Diff::KINDS + ['total']).freeze

        # How the difference column is coloured, by its first word; a
        # required parameter added breaks callers, so it is red too.
        STYLE = { 'added' => [:green], 'removed' => [:red] }.freeze

        def execute(argv)
          fatal!('module diff takes two sides: documents, module directories, or modules at refs', help: true) unless argv.size == 2
          check_filters!
          reader = targets
          ::Pupgrade.logger.notice("module diff: reading #{argv[0]}")
          from, = reader.document(reader.resolve(argv[0]))
          ::Pupgrade.logger.notice("module diff: reading #{argv[1]}")
          to,   = reader.document(reader.resolve(argv[1]))
          changes = ::Pupgrade::Surface::Diff.documents(from, to)
          shown   = changes.select { |c| shown?(c) }

          if @options[:summary]
            print_table(SUMMARY_COLUMNS, summary_rows(shown))
          elsif @options[:full]
            print_blocks(shown)
          else
            print_table(COLUMNS, shown.map { |c| row(c) })
          end
          count = (shown.size == changes.size) ? "#{changes.size} change(s)" : "#{shown.size} of #{changes.size} change(s) shown"
          ::Pupgrade.logger.notice("module diff: #{count}")
          exit(shown.empty? ? 0 : 1)
        rescue ::Pupgrade::Surface::Error, ::Pupgrade::Surface::Targets::Error => e
          fatal!("module diff: #{e.message}", 3)
        end

        protected

        def configure_parser(o)
          o.separator ''
          o.separator 'Row filters (comma-separated, repeatable; globs are case-insensitive). Hidden rows'
          o.separator 'do not count for the exit status:'
          o.on('--surfaces=KINDS', Array, "Only these surfaces (#{::Pupgrade::Surface::Diff::ALL_SECTIONS.join(', ')})") { |v| accumulate(:surfaces, v) }
          o.on('--names=GLOBS', Array, 'Only entries whose name matches') { |v| accumulate(:names, v) }
          o.on('--changes=KINDS', Array, "Only these kinds (#{::Pupgrade::Surface::Diff::KINDS.join(', ')})") { |v| accumulate(:changes, v) }
          o.separator ''
          o.separator 'Layout:'
          o.on('--summary', 'One row per surface with a count per change kind') { @options[:summary] = true }
          o.on('--full', 'Every change as a block with its values in full, however long, instead of a table') { @options[:full] = true }
          repo_option(o)
          o.separator ''
          o.separator 'Each side is a document `surface` wrote, a module directory, or a module of the'
          o.separator 'control repo by name, with `:REF` to read it at a ref of its clone: `stdlib:v9.6.0`.'
          o.separator 'Sides read now are cached as `surface` caches them; --refresh extracts them again.'
          o.separator 'Values in the table are cut to one line, the bracketed part of a Variant, Enum,'
          o.separator 'Pattern, Struct, Tuple, Hash, or Array folded to […]; --full shows them whole. Exits'
          o.separator '1 when the two differ.'
        end

        private

        def row(change)
          phrase = ::Pupgrade::Surface::Render.difference(change)
          [item_cell(change), paint(phrase, *phrase_style(phrase)), ::Pupgrade::Surface::Render.detail(change)]
        end

        # The surface kind cyan, a namespace grey, the leaf plain, so the
        # items scan by kind and the names stand apart from their paths.
        def item_cell(change)
          kind, namespace, leaf = ::Pupgrade::Surface::Render.item_parts(change)
          "#{paint(kind, :cyan)} #{namespace.empty? ? '' : paint(namespace, :grey)}#{leaf}"
        end

        def phrase_style(phrase)
          return [:red] if phrase.start_with?('added required')

          STYLE.fetch(phrase.split.first, [:yellow])
        end

        def print_blocks(changes)
          if changes.empty?
            puts '(nothing matches)'
            return
          end
          changes.each_with_index do |c, i|
            puts '' if i.positive?
            lines = ::Pupgrade::Surface::Render.block(c)
            head, *rest = lines
            item, phrase = head.split(': ', 2)
            puts "#{item}: #{paint(phrase, *phrase_style(phrase))}"
            rest.each { |l| puts l }
          end
        end

        def shown?(change)
          (Array(@options[:surfaces]).empty? || @options[:surfaces].include?(change.section)) &&
            (Array(@options[:changes]).empty? || @options[:changes].include?(change.kind)) &&
            (Array(@options[:names]).empty? || @options[:names].any? { |g| File.fnmatch?(g, change.name, File::FNM_CASEFOLD) })
        end

        def summary_rows(changes)
          changes.group_by(&:section).sort_by { |s, _| ::Pupgrade::Surface::Diff::ALL_SECTIONS.index(s) || 99 }.map do |section, rows|
            [section] + ::Pupgrade::Surface::Diff::KINDS.map { |k| rows.count { |r| r.kind == k }.to_s } + [rows.size.to_s]
          end
        end

        def check_filters!
          known = ::Pupgrade::Surface::Diff::ALL_SECTIONS
          unknown = Array(@options[:surfaces]) - known
          fatal!("module diff: unknown surface #{unknown.first.inspect} (known: #{known.join(', ')})", help: true) if unknown.any?
          unknown = Array(@options[:changes]) - ::Pupgrade::Surface::Diff::KINDS
          fatal!("module diff: unknown change kind #{unknown.first.inspect} (known: #{::Pupgrade::Surface::Diff::KINDS.join(', ')})", help: true) if unknown.any?
        end

        def accumulate(key, values)
          (@options[key] ||= []).concat(values)
        end

        def config_defaults
          surface_config_defaults
        end
      end
    end
  end
end
