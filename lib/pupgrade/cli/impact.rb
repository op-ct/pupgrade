require 'json'

require 'pupgrade/cli/base'
require 'pupgrade/cli/root'
require 'pupgrade/cli/table'
require 'pupgrade/config_keys'
require 'driftless/codebase'
require 'driftless/control_repo'
require 'driftless/module_inventory'
require 'driftless/params_schema'
require 'driftless/params_schema/validate'
require 'pupgrade/module_proposal'
require 'pupgrade/surface'
require 'pupgrade/surface/diff'
require 'pupgrade/surface/targets'
require 'pupgrade/impact/analysis'
require 'pupgrade/impact/evidence'
require 'pupgrade/impact/history'

module Pupgrade
  module CLI
    # `pupgrade impact`
    #
    # What the site would feel from a proposed Puppetfile: for each module
    # it moves, the surface changes between the deployed version and the
    # proposed ref, each mapped to the nodes, resources, call sites, and
    # Hiera keys the evidence shows concerned. Exit 1 when any finding has
    # a use.
    class Impact < Base
      include Table
      extend ::Pupgrade::ConfigKeys::DSL

      register_command name: 'impact', subcommand_of: Root
      positional '<puppetfile>'
      desc 'What a proposed Puppetfile would change for the site: surface changes mapped to their uses'

      config_key 'impact.catalogs_dir', type: :string, default: nil, example: 'pupgrade/cache/catalogs-alt',
                 about: 'A `compile` output directory (catalogs and probe records) to read instead of ' \
                        'compile.catalogs_dir, relative to the control repo: evidence of what each node uses. Unset, ' \
                        'the last compile is read'

      COLUMNS         = %w[module impact subject where detail].freeze
      SUMMARY_COLUMNS = %w[module from to commits findings used].freeze

      def execute(argv)
        reject_extra_args!(argv, max: 1)
        repo = @options[:repo_dir] ? ::Driftless::ControlRepo.new(@options[:repo_dir]) : ::Driftless::ControlRepo.detect(Dir.pwd)
        fatal!('impact requires --repo-dir (auto-detection did not supply it)', help: true) unless repo
        fatal!("repo-dir not readable: #{repo.dir}", 3) unless repo.readable?
        puppetfile = argv.first || @options[:propose]
        fatal!('impact needs the proposed Puppetfile', help: true) unless puppetfile
        check_kinds!

        inventory = ::Driftless::ModuleInventory.new(repo.dir)
        proposal  = ::Pupgrade::ModuleProposal.new(inventory, File.expand_path(puppetfile, repo.dir))
        changes   = proposal.changes.select { |c| c.to && c.from }
        log_warnings(inventory.warnings + proposal.warnings)
        ::Pupgrade.logger.notice("impact: #{puppetfile} moves #{changes.size} module(s)")
        evidence  = load_evidence(repo)
        ::Pupgrade.logger.notice("impact: reading the surfaces of #{changes.size} module(s) at both refs")
        surfaces  = surfaces_for(repo, inventory, proposal, changes)
        ::Pupgrade.logger.notice('impact: checking Hiera data against the proposed classes, then each module\'s history')
        hiera     = hiera_references(repo, inventory, surfaces)
        analysis  = ::Pupgrade::Impact::Analysis.new(evidence: evidence, hiera: hiera)

        modules  = []
        findings = []
        surfaces.each do |change, (from, to)|
          diff  = ::Pupgrade::Surface::Diff.documents(from, to)
          found = analysis.findings(change.name, diff, to)
          ::Pupgrade.logger.info("impact: #{change.name}: #{diff.size} change(s), #{found.size} finding(s)")
          found.each { |f| ::Pupgrade.logger.debug("impact: #{change.name}: #{f.kind} #{f.subject}: #{f.where}") }
          entry = inventory.entries.find { |e| e.path == change.path }
          history = ::Pupgrade::Impact::History.between(File.join(repo.dir, change.path), entry.declared.ref.to_s, proposed_ref(change),
                                                        from_version: from.dig('module', 'version'), to_version: to.dig('module', 'version'))
          modules << [change, history, found]
          findings.concat(found)
        end
        shown = findings.select { |f| shown?(f) }

        if @options[:summary]
          print_table(SUMMARY_COLUMNS, modules.map { |c, h, f| summary_row(c, h, f.select { |x| shown?(x) }) })
        else
          print_table(COLUMNS, shown.map { |f| [f.module, f.kind, f.subject, where_cell(f), detail_cell(f)] })
          print_history(modules) if @options[:changelog] || @options[:gitlog]
        end
        ::Pupgrade.logger.notice("impact: #{modules.size} module(s) move; #{shown.count(&:used?)} finding(s) with a use, " \
                               "#{shown.count { |f| !f.used? }} without#{" (#{::Pupgrade::Ansi.enabled?($stderr) ? ::Pupgrade::Ansi.wrap('no catalogs; uses unknown', :red) : 'no catalogs; uses unknown'})" unless evidence}")
        exit(shown.any?(&:used?) ? 1 : 0)
      rescue ::Pupgrade::ModuleProposal::Error, ::Pupgrade::Surface::Error, ::Pupgrade::Surface::Targets::Error,
             ::Pupgrade::Impact::Evidence::Error => e
        fatal!("impact: #{e.message}", 3)
      end

      protected

      def configure_parser(o)
        o.on('-d', '--repo-dir=DIR', 'Path to the control repo environment',
             "Default: '.' (if environment.conf and hiera.yaml exist)") { |v| @options[:repo_dir] = v }
        o.on('--propose=PUPPETFILE', 'The proposed Puppetfile, as `check` takes it; the same as giving it first') { |v| @options[:propose] = v }
        o.on('--cache-dir=DIR', 'Where surface documents are kept (config: surface.cache_dir)') { |v| @options[:cache_dir] = v }
        o.on('--refresh', 'Extract the surfaces again, ignoring the cache') { @options[:refresh] = :all }
        o.on('--catalogs-dir=DIR', 'A `compile` output directory (config: impact.catalogs_dir, else compile.catalogs_dir)') { |v| @options[:catalogs_dir] = v }
        o.on('--no-catalogs', 'Read no catalogs: every change is a finding with its use unknown') { @options[:no_catalogs] = true }

        o.separator ''
        o.separator 'Row filters (comma-separated, repeatable; globs are case-insensitive):'
        o.on('--modules=GLOBS', Array, 'Only modules whose name matches') { |v| accumulate(:modules, v) }
        o.on('--impacts=KINDS', Array, "Only these kinds (#{::Pupgrade::Impact::Analysis::KINDS.join(', ')})") { |v| accumulate(:kinds, v) }
        o.on('--all', 'Show findings nothing uses too') { @options[:all] = true }

        o.separator ''
        o.separator 'Layout:'
        o.on('--summary', 'One row per moving module: refs, commits, findings') { @options[:summary] = true }
        o.on('--gitlog', 'After the table, each module\'s commits between the refs') { @options[:gitlog] = true }
        o.on('--changelog', 'After the table, each module\'s CHANGELOG sections for the versions crossed') { @options[:changelog] = true }

        o.separator ''
        o.separator '<puppetfile> is what `solve -o` wrote, or an overlay of your own. Surfaces are read'
        o.separator 'from the deployed module and from the proposed ref (through the clone when it has'
        o.separator 'the ref, else the remote), into the cache `surface` keeps, and reused from there.'
        o.separator 'Exits 1 when any finding has a use.'
      end

      private

      def load_evidence(repo)
        return nil if @options[:no_catalogs]

        dir = @options[:catalogs_dir]
        if dir.nil? && File.directory?(File.expand_path(@options[:compile_catalogs_dir], repo.dir))
          dir = @options[:compile_catalogs_dir]
        end
        return nil unless dir

        ::Pupgrade.logger.notice("impact: reading catalogs under #{File.expand_path(dir, repo.dir)}")
        ::Pupgrade::Impact::Evidence.new(File.expand_path(dir, repo.dir))
      end

      # The current and proposed surface of every git module the proposal
      # moves, keyed by the change.
      #
      # @return [Hash{ModuleProposal::Change => Array(Hash, Hash)}]
      def surfaces_for(repo, inventory, proposal, changes)
        reader = ::Pupgrade::Surface::Targets.new(repo_dir: repo.dir, cache_dir: @options[:cache_dir], refresh: @options[:refresh])
        changes.filter_map { |change|
          entry    = inventory.entries.find { |e| e.path == change.path }
          proposed = proposal.entries.find { |e| e.path == change.path }
          next unless entry&.declared&.git && proposed&.declared&.git

          clone = File.join(repo.dir, change.path)
          ref   = proposed_ref(change)
          ::Pupgrade.logger.info("impact: #{change.name}: surfaces at #{entry.declared.ref} and #{ref}")
          from, = reader.document(reader.resolve(clone))
          to,   = reader.document(ref_in?(clone, ref) ? reader.resolve("#{clone}:#{ref}") : reader.remote(proposed.declared.git, ref))
          [change, [from, to]]
        }.to_h
      end

      def ref_in?(clone, ref)
        found = system('git', '-C', clone, 'rev-parse', '--verify', '--quiet', "#{ref}^{commit}", out: File::NULL, err: File::NULL)
        ::Pupgrade.logger.trace("git -C #{clone} rev-parse --verify --quiet #{ref}^{commit} (does the clone have #{ref}): #{found ? 'yes' : 'no'}")
        found
      end

      def proposed_ref(change)
        change.to.to_s.sub(/\A(tag|branch|commit|ref) /, '')
      end

      # Hiera keys and lookups the proposed classes no longer answer, by the
      # class or class::param they name: driftless's validator run against a
      # schema of the current repo with the moving modules' classes replaced
      # by their proposed surfaces.
      def hiera_references(repo, _inventory, surfaces)
        return {} if surfaces.empty?

        code   = ::Driftless::Codebase.load(repo.dir)
        corpus = code.corpus(repo_dir: repo.dir)
        schema = ::Driftless::ParamsSchema.assemble(corpus: corpus)
        surfaces.each_value do |(from, to)|
          (from['classes'].keys + from['defined_types'].keys).each { |c| schema['classes'].delete(c) }
          to['classes'].merge(to['defined_types']).each do |name, entry|
            schema['classes'][name] = { 'file' => entry['file'], 'params' => entry['params'].transform_values { |p| { 'type' => p['type'], 'default' => p['default'] } } }
          end
        end
        issues = ::Driftless::ParamsSchema::Validate.new(schema).call(corpus)
        issues.each_with_object(Hash.new { |h, k| h[k] = [] }) do |issue, refs|
          key = (issue.kind == 'missing-class') ? issue.key.split('::')[0..-2].join('::') : issue.key
          refs[key] << "#{issue.path}:#{issue.line}"
        end
      rescue StandardError => e
        ::Pupgrade.logger.warn("impact: Hiera references not checked: #{e.message}")
        {}
      end

      # How the verb of a change is coloured, as `module diff` colours it.
      VERB_STYLE = { 'added' => [:green], 'removed' => [:red] }.freeze

      def where_cell(finding)
        finding.used? || finding.where.empty? ? finding.where : paint(finding.where, :red)
      end

      # "changed param type: Variant[…] -> Optional[…]": the verb coloured
      # by what happened, what it happened to in cyan.
      def detail_cell(finding)
        phrase, rest = finding.detail.split(': ', 2)
        verb, thing = phrase.split(' ', 2)
        style = phrase.start_with?('added required') ? [:red] : VERB_STYLE.fetch(verb, [:yellow])
        head  = [paint(verb, *style), thing && paint(thing, :cyan)].compact.join(' ')
        rest ? "#{head}: #{rest}" : head
      end

      def summary_row(change, history, findings)
        [change.name, change.from.to_s, change.to.to_s, history.commits ? history.commits.size.to_s : '?',
         findings.size.to_s, findings.count(&:used?).to_s]
      end

      def print_history(modules)
        modules.each do |change, history, _|
          next unless glob_any?(@options[:modules], change.name)

          puts ''
          commits = history.commits ? "#{history.commits.size} commit(s)" : 'commits unknown'
          puts "#{change.name}: #{change.from} -> #{change.to}, #{commits}"
          if @options[:gitlog] && history.commits
            history.commits.each { |c| puts "  #{c}" }
          end
          if @options[:changelog]
            puts(history.changelog ? history.changelog.lines.map { |l| "  #{l}" }.join : '  (no CHANGELOG sections for the versions crossed)')
          end
        end
      end

      def shown?(finding)
        (@options[:all] || finding.used? || finding.where == 'use unknown') &&
          glob_any?(@options[:modules], finding.module) &&
          (Array(@options[:kinds]).empty? || @options[:kinds].include?(finding.kind))
      end

      def glob_any?(globs, value)
        Array(globs).empty? || globs.any? { |g| File.fnmatch?(g, value, File::FNM_CASEFOLD) }
      end

      def check_kinds!
        unknown = Array(@options[:kinds]) - ::Pupgrade::Impact::Analysis::KINDS
        return if unknown.empty?

        fatal!("impact: unknown impact kind #{unknown.first.inspect} (known: #{::Pupgrade::Impact::Analysis::KINDS.join(', ')})", help: true)
      end

      def accumulate(key, values)
        (@options[key] ||= []).concat(values)
      end

      def log_warnings(warnings)
        warnings.each { |w| ::Pupgrade.logger.warn(w) }
      end

      def config_defaults
        cfg = ::Pupgrade.config
        {
          catalogs_dir:         cfg.dig('impact', 'catalogs_dir'),
          compile_catalogs_dir: cfg.dig('compile', 'catalogs_dir') || 'pupgrade/cache/catalogs',
          cache_dir:            cfg.dig('surface', 'cache_dir') || 'pupgrade/cache/api_surfaces',
        }.compact
      end
    end
  end
end
