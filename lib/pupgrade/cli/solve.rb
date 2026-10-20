require 'yaml'

require 'pupgrade/cli/base'
require 'pupgrade/cli/root'
require 'pupgrade/cli/table'
require 'pupgrade/config_keys'
require 'driftless/control_repo'
require 'driftless/module_inventory'
require 'pupgrade/module_resolver'
require 'pupgrade/solve/candidates'
require 'pupgrade/solve/evidence'
require 'pupgrade/solve/solver'

module Pupgrade
  module CLI
    # `pupgrade solve`
    #
    # A version for every deployed git module, from the tags its clone
    # holds: one row per module that moves or is held, a Puppetfile overlay
    # for `check --propose`, and the exclusions a pruned solve relies on.
    # Exit 1 when any module is held.
    class Solve < Base
      include Table
      extend ::Pupgrade::ConfigKeys::DSL

      register_command name: 'solve', subcommand_of: Root
      desc 'Pick a version for every module along its tags, and write the proposed Puppetfile'

      config_key 'solve.order', type: :string, default: 'newest',
                 about: 'newest: move every module as far as its constraints allow; oldest: from the current ' \
                        'version forward to the first that fits, driven by --bump'
      config_key 'solve.include_heads', type: :boolean, default: false,
                 about: 'Whether the tip of a tag-pinned module\'s tracking branch (modules.branchfile) is a candidate'
      config_key 'solve.evidence', type: :string, default: nil, example: 'pupgrade-catalogs',
                 about: 'A `compile` output directory whose probe records say what the site uses, relative to the ' \
                        'control repo; needed by --prune-unused'

      COLUMNS = %w[module current chosen candidates note].freeze

      def execute(argv)
        reject_extra_args!(argv)
        repo = @options[:repo_dir] ? ::Driftless::ControlRepo.new(@options[:repo_dir]) : ::Driftless::ControlRepo.detect(Dir.pwd)
        fatal!('solve requires --repo-dir (auto-detection did not supply it)', help: true) unless repo
        fatal!("repo-dir not readable: #{repo.dir}", 3) unless repo.readable?
        fatal!('solve: --prune-unused needs --evidence DIR (config: solve.evidence)', help: true) if @options[:prune_unused] && @options[:evidence].nil?

        inventory  = ::Driftless::ModuleInventory.new(repo.dir)
        candidates = ::Pupgrade::Solve::Candidates.new(repo.dir, branchfile: @options[:branchfile], include_heads: @options[:include_heads],
                                                                 fetch: @options[:fetch])
        evidence   = @options[:evidence] && ::Pupgrade::Solve::Evidence.new(File.expand_path(@options[:evidence], repo.dir))
        solver     = ::Pupgrade::Solve::Solver.new(operatingsystems: @options[:operatingsystems], requirements: @options[:requirements],
                                                   exclude: exclusions, order: @options[:order], bumps: @options[:bumps] || {},
                                                   holds: @options[:holds] || [], evidence: evidence, prune_unused: @options[:prune_unused])
        entries = inventory.entries
        plan    = solver.solve(entries, entries.to_h { |e| [e.path, candidates.for(e)] })
        log_warnings(inventory.warnings + candidates.warnings)

        shown = plan.choices.select { |c| @options[:all] || c.moved? || c.held? }
        print_table(COLUMNS, shown.map { |c| row(c) })
        plan.implicit.each { |i| ::Pupgrade.logger.warn("solve: #{i}: used, but not a declared dependency") }
        write_puppetfile(plan) if @options[:output]
        write_exclusions(plan) if @options[:exclusions]
        ::Pupgrade.logger.info(summary(plan, evidence))
        exit(plan.choices.any?(&:held?) ? 1 : 0)
      rescue ::Pupgrade::Solve::Evidence::Error, ::Pupgrade::ModuleResolver::Error, ArgumentError => e
        fatal!("solve: #{e.message}", 3)
      end

      protected

      def configure_parser(o)
        o.on('-d', '--repo-dir=DIR', 'Path to the control repo environment',
             "Default: '.' (if environment.conf and hiera.yaml exist)") { |v| @options[:repo_dir] = v }
        o.on('-o', '--output=PUPPETFILE', 'Write the moved modules as a Puppetfile overlay for `check --propose`') { |v| @options[:output] = v }
        o.on('--all', 'Show every module, not only those that move or are held') { @options[:all] = true }

        o.separator ''
        o.separator 'Candidates:'
        o.on('--order=ORDER', ::Pupgrade::Solve::Solver::ORDERS, 'newest (default) or oldest (config: solve.order)') { |v| @options[:order] = v }
        o.on('--bump=MODULE[=REF]', 'Move MODULE to REF, or to its newest candidate; repeatable') { |v| bump(v) }
        o.on('--hold=MODULES', Array, 'Keep these modules at their current version; comma-separated, repeatable') { |v| accumulate(:holds, v) }
        o.on('--branchfile=FILE', 'The branch each tag-pinned module follows (config: modules.branchfile)') { |v| @options[:branchfile] = v }
        o.on('--[no-]include-heads', 'Make a tracking branch\'s tip a candidate (config: solve.include_heads)') { |v| @options[:include_heads] = v }
        o.on('--fetch', 'Fetch each clone\'s origin first, so new tags are seen') { @options[:fetch] = true }

        o.separator ''
        o.separator 'Pruning by what the site uses:'
        o.on('--evidence=DIR', 'A `compile` output directory (config: solve.evidence)') { |v| @options[:evidence] = v }
        o.on('--prune-unused', 'Ignore dependency edges to modules the evidence shows unused') { @options[:prune_unused] = true }
        o.on('--exclusions=FILE', 'Write the pruned edges the result violates as modules.exclude_dependencies YAML') { |v| @options[:exclusions] = v }

        o.separator ''
        o.separator 'Modules are decided dependencies first, each at the first candidate in order that'
        o.separator 'satisfies its dependency ranges, the Puppet requirement, and the operating systems'
        o.separator 'of interest against what is already decided. One with no fit is held at the candidate'
        o.separator 'breaking the fewest, which the note names. Exits 1 when any module is held.'
      end

      private

      def row(choice)
        chosen = choice.chosen
        note   = choice.held? ? "held: #{choice.violations.join('; ')}" : choice.note
        [choice.name, current_text(choice), chosen.current ? '(current)' : chosen.ref,
         (choice.candidates.size - 1).to_s, note]
      end

      def current_text(choice)
        entry = choice.entry
        version = entry.metadata.version
        declared = entry.declared
        return version.to_s if declared.nil?

        declared.git ? "#{declared.ref_type} #{declared.ref}" : "#{declared.version} (forge)"
      end

      # The moved modules as Puppetfile entries, replacing the current ones
      # at the same paths.
      def write_puppetfile(plan)
        lines = ["# Written by `pupgrade solve` #{Time.now.strftime('%Y-%m-%d %H:%M')}: an overlay for `pupgrade check --propose`", '']
        plan.choices.select(&:moved?).each do |c|
          declared = c.entry.declared
          lines << "mod '#{declared.name}',"
          lines << "  git: '#{declared.git}',"
          lines << "  install_path: '#{File.dirname(c.entry.path)}'," unless File.dirname(c.entry.path) == 'modules'
          lines << "  #{c.chosen.ref_type}: '#{c.chosen.ref}'"
        end
        File.write(File.expand_path(@options[:output]), lines.join("\n") + "\n")
        ::Pupgrade.logger.info("solve: wrote #{File.expand_path(@options[:output])}")
      end

      def write_exclusions(plan)
        data = { 'modules' => { 'exclude_dependencies' => plan.pruned } }
        File.write(File.expand_path(@options[:exclusions]), YAML.dump(data))
        ::Pupgrade.logger.info("solve: wrote #{plan.pruned.size} exclusion(s) to #{File.expand_path(@options[:exclusions])}")
      end

      def summary(plan, evidence)
        moved = plan.choices.count(&:moved?)
        held  = plan.choices.count(&:held?)
        text  = "solve: #{moved} of #{plan.choices.size} module(s) move, #{held} held"
        text += "; #{plan.pruned.size} pruned edge(s) violated" if @options[:prune_unused]
        text += "; evidence from #{evidence.nodes} node(s)" if evidence
        text
      end

      def bump(text)
        name, ref = text.split('=', 2)
        fatal!("solve: --bump needs a module, got #{text.inspect}", help: true) if name.nil? || name.empty?
        (@options[:bumps] = (@options[:bumps] || {}).dup)[name] = ref
      end

      def accumulate(key, values)
        (@options[key] ||= []).concat(values)
      end

      def exclusions
        config = @options[:exclude] || {}
        config.transform_values { |v| Array(v) }
      end

      def log_warnings(warnings)
        warnings.each { |w| ::Pupgrade.logger.warn(w) }
      end

      def config_defaults
        cfg = ::Pupgrade.config
        {
          operatingsystems: cfg.dig('modules', 'operatingsystems'),
          requirements:     cfg.dig('modules', 'requirements'),
          branchfile:       cfg.dig('modules', 'branchfile'),
          order:            cfg.dig('solve', 'order') || 'newest',
          include_heads:    cfg.dig('solve', 'include_heads') || false,
          evidence:         cfg.dig('solve', 'evidence'),
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
