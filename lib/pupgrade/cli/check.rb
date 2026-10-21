require 'pupgrade/cli/base'
require 'pupgrade/cli/root'
require 'pupgrade/cli/table'
require 'pupgrade/config_keys'
require 'driftless/control_repo'
require 'driftless/module_inventory'
require 'pupgrade/module_proposal'
require 'pupgrade/module_resolver'
require 'pupgrade/module_name'

module Pupgrade
  module CLI
    # `pupgrade check`
    #
    # One row per conflict between the modules' metadata; exit 1 when any
    # remain. With --propose or --ignore, the conflicts a changed set of
    # modules would leave: those the change introduces and resolves, or
    # every one with --all-conflicts, marked against the current ones.
    class Check < Base
      include Table
      extend ::Pupgrade::ConfigKeys::DSL

      register_command name: 'check', subcommand_of: Root
      desc 'Check modules against each other, or what a proposed Puppetfile would change'

      # The columns --order and --sort-by may name, in their default order;
      # detail always comes last.
      COLUMNS = %w[conflict module subject].freeze

      config_key 'modules.check_order', type: :array, default: nil, example: COLUMNS,
                 about: 'Left-to-right order of the conflict, module, and subject columns in `check`; ' \
                        'columns left out keep their place after those named'
      config_key 'modules.check_sort', type: :array, default: nil, example: COLUMNS,
                 about: 'Which of conflict, module, and subject `check` sorts rows by, in precedence; ' \
                        'columns left out break ties in their default order'

      # The one-row-per-module table: counts per conflict kind, then all.
      SUMMARY_COLUMNS = (['module'] + ::Pupgrade::ModuleResolver::KINDS + ['total']).freeze

      # What each named column shows for a conflict.
      CELL = { 'conflict' => :kind, 'module' => :module, 'subject' => :subject }.freeze

      # Prefixed to each row under --propose: how the conflict relates to
      # the current Puppetfile's.
      CHANGE_MARK = { new: '+', gone: '-', same: ' ' }.freeze

      # How each mark is coloured when stdout takes colour.
      MARK_STYLE = { new: [:red], gone: [:green], same: [] }.freeze

      # The sign each mark carries in a --summary cell under --propose.
      COUNT_SIGN = { new: '+', gone: '-', same: '=' }.freeze

      # The group under --by-change for rows no changed entry accounts for.
      OTHER_GROUP = '(no changed entry involved)'.freeze

      # A conflict and how it relates to the current Puppetfile's.
      #
      # @!attribute [r] mark
      #   @return [Symbol] :new (the proposal introduces it), :gone (the
      #     proposal resolves it), or :same
      # @!attribute [r] conflict
      #   @return [ModuleResolver::Conflict]
      Row = Data.define(:mark, :conflict)

      def execute(_argv)
        repo = @options[:repo_dir] ? ::Driftless::ControlRepo.new(@options[:repo_dir]) : ::Driftless::ControlRepo.detect(Dir.pwd)
        fatal!('check requires --repo-dir (auto-detection did not supply it)', help: true) unless repo
        fatal!("repo-dir not readable: #{repo.dir}", 3) unless repo.readable?
        check_kinds!
        check_layout_flags!
        @order = columns_from(@options[:order], '--order')
        @sort  = columns_from(@options[:sort], '--sort-by')

        inventory = ::Driftless::ModuleInventory.new(repo.dir)
        resolver  = ::Pupgrade::ModuleResolver.new(operatingsystems: @options[:operatingsystems], exclude: exclusions,
                                                   requirements: @options[:requirements])
        current   = resolver.resolve(inventory.entries)
        log_warnings(inventory.warnings + current.warnings)

        if @options[:propose] || @options[:ignore]
          proposal = ::Pupgrade::ModuleProposal.new(inventory, @options[:propose] && File.expand_path(@options[:propose]),
                                                    ignore: @options[:ignore] || [])
          result   = resolver.resolve(proposal.entries)
          log_warnings(proposal.warnings + result.warnings)
          shown = shown_rows(result)
          rows  = change_rows(shown_rows(current), shown)
          print_proposal(rows.reject { |r| hidden_mark?(r.mark) }, proposal.changes)
          ::Pupgrade.logger.info(proposal_summary(result, shown, rows))
        else
          result = current
          shown  = shown_rows(result)
          if @options[:summary]
            print_table(SUMMARY_COLUMNS, summary_rows(shown.map { |c| Row.new(mark: :same, conflict: c) }, marked: false))
          else
            print_table(@order + ['detail'], shown.map { |c| row(c) })
          end
          ::Pupgrade.logger.info(summary(result, shown))
        end

        exit(shown.empty? ? 0 : 1)
      rescue ::Pupgrade::ModuleProposal::Error, ::Pupgrade::ModuleResolver::Error => e
        fatal!("check: #{e.message}")
      end

      protected

      def configure_parser(o)
        o.on('-d', '--repo-dir=DIR',
             'Path to the control repo environment',
             "Default: '.' (if environment.conf and hiera.yaml exist)") { |v| @options[:repo_dir] = v }
        o.on('--propose=PUPPETFILE',
             'Resolve as if PUPPETFILE replaced the current entries at the same paths;',
             'metadata for a changed module is read from its git remote.',
             'Rows are marked + (introduced), - (resolved), or blank (unchanged)') { |v| @options[:propose] = v }
        o.on('--ignore=MODULES', Array,
             'Resolve as if these modules were removed from the Puppetfile: a what-if, so their',
             'dependents then miss them (globs on any spelling of the name, or the deploy path;',
             'comma-separated, repeatable), with or without --propose. Not an exclusion:',
             'modules.exclude_modules leaves a module out of every check instead') { |v| accumulate(:ignore, v) }
        o.on('--changed-only', 'With --propose or --ignore, show only the rows the change introduces or resolves') { @options[:changed_only] = true }
        o.on('--hide-resolved', 'With --propose or --ignore, drop the rows the change resolves (-)') { @options[:hide_resolved] = true }

        o.separator ''
        o.separator 'Row filters (comma-separated, repeatable; globs are case-insensitive). Hidden rows'
        o.separator 'do not count for the exit status:'
        o.on('--modules=GLOBS', Array, 'Only rows whose module matches') { |v| accumulate(:modules, v) }
        o.on('--subjects=GLOBS', Array, 'Only rows whose subject matches') { |v| accumulate(:subjects, v) }
        o.on('--conflicts=KINDS', Array, "Only these kinds (#{::Pupgrade::ModuleResolver::KINDS.join(', ')})") do |v|
          accumulate(:conflicts, v)
        end
        o.on('--skip-conflicts=KINDS', Array, 'Drop these kinds') { |v| accumulate(:skip_conflicts, v) }

        o.separator ''
        o.separator 'Exclusions (comma-separated, repeatable; each adds to its modules.exclude_* list):'
        o.on('--exclude-modules=GLOBS', Array, 'Leave these modules out of every check') { |v| exclude('modules', v) }
        o.on('--exclude-deps=GLOBS', '--exclude-dependencies=GLOBS', Array,
             'Drop dependency conflicts matching module, dependency, or module:dependency') { |v| exclude('dependencies', v) }
        o.on('--exclude-requirements=GLOBS', Array,
             'Drop Puppet-version conflicts matching the module or a module it disagrees with') { |v| exclude('requirements', v) }
        o.on('--exclude-os=GLOBS', '--exclude-operatingsystems=GLOBS', Array,
             'Drop operating-system conflicts matching module, "OS release", or module:OS release') { |v| exclude('operatingsystems', v) }

        o.separator ''
        o.separator "Layout (columns: #{COLUMNS.join(', ')}; those left out follow in that order):"
        o.on('--summary', 'One row per module with conflicts: a count per kind, after the filters;',
             'under --propose or --ignore, counts of rows introduced (+) and resolved (-)') { @options[:summary] = true }
        o.on('--by-change', 'Under --propose or --ignore, one table per Puppetfile entry that changed,',
             'the entry introducing the most conflicts first') { @options[:by_change] = true }
        o.on('--order=COLUMNS', Array, 'Column order, left to right (config: modules.check_order)') { |v| @options[:order] = v }
        o.on('--sort-by=COLUMNS', Array, 'Sort rows by these columns, in precedence (config: modules.check_sort)') do |v|
          @options[:sort] = v
        end

        o.separator ''
        o.separator 'Exits 1 when conflicts remain. In pupgrade.yaml, modules.operatingsystems names the'
        o.separator 'operating systems of interest, modules.exclude_modules leaves modules out of every check,'
        o.separator 'and modules.exclude_dependencies|requirements|operatingsystems drop known conflicts.'
      end

      private

      def row(conflict)
        @order.map { |col| conflict.public_send(CELL.fetch(col)) } + [conflict.detail]
      end

      def marked_row(r)
        [paint(CHANGE_MARK.fetch(r.mark), *MARK_STYLE.fetch(r.mark))] + row(r.conflict)
      end

      # Which marks the view drops: unchanged rows under --changed-only,
      # resolved rows under --hide-resolved.
      def hidden_mark?(mark)
        (mark == :same && @options[:changed_only]) || (mark == :gone && @options[:hide_resolved])
      end

      # Rows by the sort columns, then the rest in default order; kinds
      # keep the resolver's order, names compare case-insensitively.
      def sorted(conflicts)
        conflicts.sort_by do |c|
          @sort.map { |col| (col == 'conflict') ? ::Pupgrade::ModuleResolver::KINDS.index(c.kind) : c.public_send(CELL.fetch(col)).downcase }
        end
      end

      # @param given [Array<String>, nil] the columns asked for
      # @param flag [String] named in the usage error
      # @return [Array<String>] the full column list, those given first
      def columns_from(given, flag)
        named = Array(given).map(&:to_s)
        unknown = named - COLUMNS
        fatal!("check: #{flag}: unknown column #{unknown.first.inspect} (known: #{COLUMNS.join(', ')})", help: true) if unknown.any?
        fatal!("check: #{flag}: a column may be named once", help: true) if named.uniq.size != named.size
        named + (COLUMNS - named)
      end

      # The proposed conflicts, then those the proposal resolves, each
      # with its mark. Conflicts match by kind, module, and subject.
      #
      # @param current [Array<Conflict>] from the current Puppetfile
      # @param proposed [Array<Conflict>] from the proposed one
      # @return [Array<Row>]
      def change_rows(current, proposed)
        key = ->(c) { [c.kind, c.module, c.subject] }
        before = current.to_h { |c| [key.call(c), c] }
        after  = proposed.to_h { |c| [key.call(c), c] }
        rows   = proposed.map { |c| Row.new(mark: before.key?(key.call(c)) ? :same : :new, conflict: c) }
        rows + current.reject { |c| after.key?(key.call(c)) }.map { |c| Row.new(mark: :gone, conflict: c) }
      end

      # @param rows [Array<Row>] the rows to show
      # @param changes [Array<ModuleProposal::Change>] what the proposal changes
      def print_proposal(rows, changes)
        if @options[:summary]
          print_table(SUMMARY_COLUMNS, summary_rows(rows, marked: true))
        elsif @options[:by_change]
          print_groups(rows, changes)
        else
          print_table(['change'] + @order + ['detail'], rows.map { |r| marked_row(r) })
        end
      end

      # One table per changed Puppetfile entry, headed by what changed and
      # how many rows it introduces and resolves, the most introduced
      # first. A row involving two changed entries appears under both;
      # unchanged rows appear under none.
      def print_groups(rows, changes)
        by_name = changes.to_h { |c| [normalize(c.name), c] }
        groups  = Hash.new { |h, k| h[k] = [] }
        # an unchanged row is about no change, so it has no group
        rows.reject { |r| r.mark == :same }.each do |r|
          involved = ([r.conflict.module] + r.conflict.parties).filter_map { |n| by_name[normalize(n)] }.uniq
          involved.empty? ? groups[OTHER_GROUP] << r : involved.each { |c| groups[c] << r }
        end
        if groups.empty?
          puts '(nothing changes)'
          return
        end

        ordered = groups.sort_by do |change, rs|
          [-rs.count { |r| r.mark == :new }, -rs.count { |r| r.mark == :gone }, change.is_a?(String) ? "\x7f" : change.name.downcase]
        end
        ordered.each_with_index do |(change, rs), i|
          puts '' if i.positive?
          puts group_heading(change, rs)
          print_table(['change'] + @order + ['detail'], rs.map { |r| marked_row(r) })
        end
      end

      def group_heading(change, rows)
        counts = "+#{rows.count { |r| r.mark == :new }} -#{rows.count { |r| r.mark == :gone }}"
        return "#{OTHER_GROUP} (#{counts})" if change.is_a?(String)

        movement =
          if change.from.nil? then "added at #{change.to}"
          elsif change.to.nil? then "removed (was #{change.from})"
          else "#{change.from} -> #{change.to}"
          end
        "#{change.name} (#{change.path}): #{movement} (#{counts})"
      end

      def summary(result, shown)
        "check: #{count_text(result, shown)}, #{result.excluded} excluded; #{puppet_text(result)}"
      end

      # @param rows [Array<Row>] every change row, before the mark filter
      def proposal_summary(result, shown, rows)
        marks  = rows.group_by(&:mark).transform_values(&:size)
        hidden = @options[:changed_only] ? ' (hidden)' : ''
        "check: the proposal leaves #{count_text(result, shown)}: #{marks.fetch(:new, 0)} introduced, " \
          "#{marks.fetch(:gone, 0)} resolved, #{marks.fetch(:same, 0)} unchanged#{hidden}; " \
          "#{result.excluded} excluded; #{puppet_text(result)}"
      end

      def count_text(result, shown)
        (shown.size == result.conflicts.size) ? "#{result.conflicts.size} conflict(s)" : "#{shown.size} of #{result.conflicts.size} conflict(s) shown"
      end

      def puppet_text(result)
        result.puppet_range ? "puppet #{result.puppet_range} satisfies every requirement" : 'no puppet version satisfies every requirement'
      end

      # One row per module among the rows, by module name: a count per
      # kind and the total. Under a proposal each count reads "+a -b =c"
      # for the rows introduced, resolved, and unchanged, zeros left out.
      def summary_rows(rows, marked:)
        rows.group_by { |r| r.conflict.module }.sort.map do |name, rs|
          groups = ::Pupgrade::ModuleResolver::KINDS.map { |kind| rs.select { |r| r.conflict.kind == kind } } + [rs]
          [name] + groups.map { |group| marked ? marked_count(group) : group.size.to_s }
        end
      end

      def marked_count(rows)
        parts = COUNT_SIGN.filter_map do |mark, sign|
          n = rows.count { |r| r.mark == mark }
          paint("#{sign}#{n}", *MARK_STYLE.fetch(mark)) if n.positive?
        end
        parts.empty? ? '0' : parts.join(' ')
      end

      # The conflicts the row filters let through, in the sort order.
      def shown_rows(result)
        sorted(result.conflicts.select { |c| shown?(c) })
      end

      def shown?(conflict)
        (Array(@options[:modules]).empty? || ::Pupgrade::ModuleName.any?(@options[:modules], conflict.module)) &&
          (Array(@options[:subjects]).empty? || ::Pupgrade::ModuleName.any?(@options[:subjects], conflict.subject)) &&
          (Array(@options[:conflicts]).empty? || @options[:conflicts].include?(conflict.kind)) &&
          !Array(@options[:skip_conflicts]).include?(conflict.kind)
      end

      # An empty list passes everything.
      def glob_any?(globs, value)
        Array(globs).empty? || globs.any? { |g| File.fnmatch?(g, value, File::FNM_CASEFOLD) }
      end

      def normalize(name)
        name.to_s.tr('/', '-').downcase
      end

      def check_kinds!
        unknown = (Array(@options[:conflicts]) + Array(@options[:skip_conflicts])) - ::Pupgrade::ModuleResolver::KINDS
        return if unknown.empty?

        fatal!("check: unknown conflict kind #{unknown.first.inspect} " \
               "(known: #{::Pupgrade::ModuleResolver::KINDS.join(', ')})", help: true)
      end

      def check_layout_flags!
        proposing = @options[:propose] || @options[:ignore]
        fatal!('check: --summary and --by-change are one or the other', help: true) if @options[:summary] && @options[:by_change]
        fatal!('check: --by-change needs --propose or --ignore', help: true) if @options[:by_change] && !proposing
        fatal!('check: --changed-only needs --propose or --ignore', help: true) if @options[:changed_only] && !proposing
        fatal!('check: --hide-resolved needs --propose or --ignore', help: true) if @options[:hide_resolved] && !proposing
      end

      def accumulate(key, values)
        (@options[key] ||= []).concat(values)
      end

      # Adds flag values to one exclusion list, kept apart from the
      # config's until {exclusions} joins them.
      def exclude(list, values)
        ((@options[:exclude_flags] ||= {})[list] ||= []).concat(values)
      end

      # The config's modules.exclude_* lists with the flags' globs added.
      #
      # @return [Hash{String => Array<String>}]
      def exclusions
        config = @options[:exclude] || {}
        flags  = @options[:exclude_flags] || {}
        (config.keys | flags.keys).to_h { |list| [list, Array(config[list]) + Array(flags[list])] }
      end

      def log_warnings(warnings)
        warnings.each { |w| ::Pupgrade.logger.warn(w) }
      end

      def config_defaults
        cfg = ::Pupgrade.config
        {
          operatingsystems: cfg.dig('modules', 'operatingsystems'),
          requirements:     cfg.dig('modules', 'requirements'),
          order:            cfg.dig('modules', 'check_order'),
          sort:             cfg.dig('modules', 'check_sort'),
          exclude:          {
            'modules'          => cfg.dig('modules', 'exclude_modules'),
            'dependencies'     => cfg.dig('modules', 'exclude_dependencies'),
            'requirements'     => cfg.dig('modules', 'exclude_requirements'),
            'operatingsystems' => cfg.dig('modules', 'exclude_operatingsystems'),
          }.compact,
        }.compact
      end
    end
  end
end
