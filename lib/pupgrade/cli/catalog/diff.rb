require 'json'
require 'open3'
require 'tmpdir'

require 'pupgrade/cli/base'
require 'pupgrade/cli/catalog'
require 'pupgrade/cli/table'
require 'pupgrade/cli/catalog/resources'
require 'pupgrade/certname_globs'
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

        # How the change cell is colored by its verb; any other verb is
        # yellow. `module diff` colors its own verbs the same way.
        VERB_STYLE = { 'added' => [:green], 'removed' => [:red] }.freeze

        # How many node names a --group row lists before counting instead.
        NAMED_NODES = 3

        def execute(argv)
          fatal!('catalog diff takes two directories', help: true) unless argv.size == 2
          check_kinds!
          fatal!('catalog diff: --full, --group, and --summary are one of them at most', help: true) if @options.values_at(:full, :group, :summary).count(&:itself) > 1
          from, to = argv.map { |p| File.expand_path(p) }
          changes  = ::Pupgrade::Compile::CatalogDiff.directories(from, to, ignore_params: Array(@options[:ignore_params]))
          shown    = changes.select { |c| shown?(c) }

          if @options[:full]
            print_full(from, to, shown)
          elsif @options[:summary]
            print_table(SUMMARY_COLUMNS, summary_rows(shown))
          elsif @options[:group]
            print_table(GROUP_COLUMNS, group_rows(shown))
          else
            print_table(COLUMNS, shown.map { |c| [c.certname, kind_cell(c.kind), c.resource.to_s, c.param.to_s, c.detail] })
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
          o.on('--certname=GLOB[,…]', Array, 'Only nodes whose certname matches; !GLOB leaves its matches out') { |v| accumulate(:certnames, v) }
          o.on('--resources=GLOBS', Array, 'Only rows whose resource (Type[title]) matches') { |v| accumulate(:resources, v) }
          o.on('--params=GLOBS', Array, 'Only rows whose parameter matches') { |v| accumulate(:params, v) }
          o.on('--changes=KINDS', Array, "Only these kinds (#{::Pupgrade::Compile::CatalogDiff::KINDS.join(', ')}), " \
                                         'globs of them, or entities: `param` is param-*') { |v| accumulate(:changes, v) }
          o.on('--skip-changes=KINDS', Array, 'Drop these kinds, in the forms --changes takes') { |v| accumulate(:skip_changes, v) }
          o.on('--ignore-params=NAMES', Array, 'Parameters never compared') { |v| accumulate(:ignore_params, v) }

          o.separator ''
          o.separator 'Layout:'
          o.on('--group', 'One row per distinct change, with the nodes it appears on') { @options[:group] = true }
          o.on('--summary', 'One row per node with counts: +added -removed ~changed') { @options[:summary] = true }
          o.on('--full', 'Each changed resource whole: a unified diff of its JSON') { @options[:full] = true }

          o.separator ''
          o.separator 'Each directory is what `compile -o DIR` wrote (DIR/<certname>/catalog.json), or one'
          o.separator 'node\'s directory. Nodes in only one of them are node-missing rows. Exits 1 when'
          o.separator 'the catalogs differ.'
        end

        private

        def shown?(change)
          ::Pupgrade::CertnameGlobs.match?(@options[:certnames], change.certname) &&
            glob_any?(Array(@options[:resources]).map { |g| reference_glob(g) }, change.resource.to_s) &&
            (Array(@options[:params]).empty? || (change.param && glob_any?(@options[:params], change.param))) &&
            (Array(@options[:changes]).empty? || @options[:changes].include?(change.kind)) &&
            !Array(@options[:skip_changes]).include?(change.kind)
        end

        # A Type[title] glob with its brackets taken as written, so
        # `Class[profile::*]` is a class and not a character set.
        def reference_glob(glob)
          ref = Resources::REFERENCE.match(glob)
          ref ? "#{ref[1]}\\[#{ref[2]}\\]" : glob
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
            [kind_cell(kind), resource, param, detail, nodes]
          end
        end

        def kind_cell(kind)
          paint(kind, *VERB_STYLE.fetch(kind.split('-', 2).last, [:yellow]))
        end

        # Each changed resource whole: a unified diff of it before and
        # after. A change to no resource (a node, class, or edge) prints
        # its row.
        def print_full(from, to, changes)
          certnames = changes.map(&:certname).uniq
          before    = resources_in(from, certnames)
          after     = resources_in(to, certnames)
          changes.group_by { |c| [c.certname, c.kind.start_with?('resource-', 'param-') ? c.resource : nil] }.each do |(certname, name), rows|
            if name.nil?
              rows.each { |c| puts [certname, kind_cell(c.kind), c.resource, c.detail].compact.join(' ') }
              next
            end

            puts paint("#{certname} #{name}", :bold)
            puts unified(before.dig(certname, name), after.dig(certname, name), File.join(from, certname), File.join(to, certname))
          end
        end

        # @return [Hash{String => Hash{String => Hash}}] certname to Type[title] to resource
        def resources_in(dir, certnames)
          ::Pupgrade::Compile::CatalogDiff.catalogs_in(dir).slice(*certnames).transform_values do |path|
            ::Pupgrade::Compile::CatalogDiff.read(path)['resources'].to_h { |r| [::Pupgrade::Compile::CatalogDiff.key(r), r] }
          end
        end

        # `diff -u` of two resources as JSON, with context enough to show
        # each whole; nil for a side the resource is not on.
        def unified(before, after, from_label, to_label)
          texts = [before, after].map { |r| r ? "#{JSON.pretty_generate(r)}\n" : '' }
          out = Dir.mktmpdir do |dir|
            files = texts.each_with_index.map { |text, i| File.join(dir, i.to_s).tap { |f| File.write(f, text) } }
            context = texts.map { |t| t.lines.size }.max
            Open3.capture2('diff', "-U#{context}", '--label', from_label, '--label', to_label, *files).first
          end
          out.lines.map { |line| paint(line.chomp, *diff_style(line)) }.join("\n")
        rescue Errno::ENOENT
          fatal!('catalog diff: --full needs the `diff` command, which is not on the PATH', 3)
        end

        def diff_style(line)
          if line.start_with?('+++', '---') then [:bold]
          elsif line.start_with?('+') then [:green]
          elsif line.start_with?('-') then [:red]
          elsif line.start_with?('@@') then [:cyan]
          else []
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

        # Replaces each --changes and --skip-changes argument with the kinds
        # it names: itself, those an entity (`param`) prefixes, or those a
        # glob matches. One naming no kind is fatal.
        def check_kinds!
          %i[changes skip_changes].each do |key|
            next unless @options[key]

            kinds = @options[key].flat_map do |arg|
              named = kinds_for(arg)
              next named unless named.empty?

              fatal!("catalog diff: unknown change kind #{arg.inspect} " \
                     "(known: #{::Pupgrade::Compile::CatalogDiff::KINDS.join(', ')})", help: true)
            end
            @options[key] = kinds.uniq
          end
        end

        def kinds_for(arg)
          all = ::Pupgrade::Compile::CatalogDiff::KINDS
          return [arg] if all.include?(arg)

          by_entity = all.select { |k| k.start_with?("#{arg}-") }
          by_entity.empty? ? all.select { |k| File.fnmatch?(arg, k, File::FNM_CASEFOLD) } : by_entity
        end

        def accumulate(key, values)
          (@options[key] ||= []).concat(values)
        end
      end
    end
  end
end
