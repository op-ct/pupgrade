require 'pupgrade/cli/base'
require 'pupgrade/cli/module_command'
require 'pupgrade/cli/table'
require 'driftless/git_clone'
require 'driftless/module_inventory'
require 'pupgrade/release_constraints'
require 'pupgrade/solve/candidates'

module Pupgrade
  module CLI
    class ModuleCommand
      # `pupgrade module release`
      #
      # One module's releases: every tag naming a version on the branch it
      # follows, past and future, oldest first, with the date of each and
      # the deployed one marked; on request, whether each meets a
      # dependency version, a Puppet version, or an operating system.
      class Release < Base
        include Table
        include ModuleCommand::Shared

        register_command name: 'release', subcommand_of: ModuleCommand
        positional '<module>'
        desc 'List one module\'s releases, past and future: version, tag, and date, the deployed one marked'

        COLUMNS = %w[version tag released].freeze

        # How a constraint cell is colored by its first word.
        STYLE = { 'ok' => [:green], 'needs' => [:red], 'missing' => [:red] }.freeze

        def execute(argv)
          fatal!('module release takes a module', help: true) unless argv.size == 1
          repo      = control_repo!('module release')
          inventory = ::Driftless::ModuleInventory.new(repo.dir)
          entry     = inventory.find(argv.first)
          fatal!("module release: no module #{argv.first.inspect} on the modulepath or in the Puppetfile", 3) unless entry

          branch     = @options[:branch] && given_branch('module release', repo, entry)
          candidates = ::Pupgrade::Solve::Candidates.new(repo.dir, branchfile: @options[:branchfile], include_heads: @options[:include_heads],
                                                         fetch: @options[:fetch])
          list = candidates.releases(entry, branch: branch)
          candidates.warnings.each { |w| ::Pupgrade.logger.warn(w) }
          fatal!("module release: #{entry.path}: #{list.reason}", 3) if list.is_a?(::Pupgrade::Solve::Candidates::Unsolvable)

          constraints = constraints(inventory)
          clone = ::Driftless::GitClone.new(File.join(repo.dir, entry.path))
          print_table(COLUMNS + constraints.map(&:heading) + [''], list.map { |c| row(clone, c, constraints) })
          name = entry.metadata.name || entry.declared&.name || File.basename(entry.path)
          branch ||= (entry.declared.ref_type == 'branch') ? entry.declared.ref.to_s : branch_for(repo, entry)
          ::Pupgrade.logger.notice("module release: #{name}: #{list.size} release(s)#{" on #{branch}" if branch}")
          exit 0
        end

        protected

        def configure_parser(o)
          declare_repo_option(o)
          o.on('--branch=BRANCHES', Array, 'Follow the first of these branches the clone has; with a branchfile, record it there') { |v| @options[:branch] = v }
          o.on('--branchfile=FILE', 'The branchfile naming the branch the module follows (config: modules.branchfile)') { |v| @options[:branchfile] = v }
          o.on('--fetch', 'Fetch the clone\'s origin first') { @options[:fetch] = true }
          o.on('--include-heads', 'The tip of the branch as a last row') { @options[:include_heads] = true }
          o.separator ''
          o.separator 'Constraints, a column each (comma-separated, repeatable):'
          o.on('--with=DEP[,…]', Array, 'Each release\'s range on DEP against its deployed version, or DEP=VERSION') { |v| accumulate(:with, v) }
          o.on('--puppet=VERSION', 'Each release\'s Puppet requirement against VERSION (8 reads as 8.0.0)') { |v| @options[:puppet] = v }
          o.on('--os=NAME[,…]', Array, 'Each release\'s support for the OS, or a release of it as NAME=RELEASE') { |v| accumulate(:os, v) }
          o.separator ''
          o.separator 'A constraint cell reads ok, needs RANGE (newer or older: which way the version would'
          o.separator 'have to move), missing, none (no such dependency), or undeclared.'
        end

        private

        # @return [Array<#heading, #check>] from --with, --puppet, and --os
        def constraints(inventory)
          out = Array(@options[:with]).map do |spec|
            name, _, version = spec.partition('=')
            if version.empty?
              version = inventory.find(name)&.metadata&.version
              fatal!("module release: --with #{name}: not deployed, so no version to hold against; give #{name}=VERSION", 3) unless version
            end
            ::Pupgrade::ReleaseConstraints::Dependency.new(name, parse_version(version, "--with #{spec}"))
          end
          out << ::Pupgrade::ReleaseConstraints::Puppet.new(parse_version(@options[:puppet], '--puppet')) if @options[:puppet]
          out + Array(@options[:os]).map do |spec|
            os, _, release = spec.partition('=')
            ::Pupgrade::ReleaseConstraints::OperatingSystem.new(os, release.empty? ? nil : release)
          end
        end

        def parse_version(text, what)
          ::Pupgrade::ReleaseConstraints.version(text)
        rescue ArgumentError => e
          fatal!("module release: #{what}: #{e.message}", help: true)
        end

        def accumulate(key, values)
          (@options[key] ||= []).concat(values)
        end

        # A tag cyan and a branch tip magenta, the colors `module list` gives
        # a declaration; a constraint met green, missed red; the deployed
        # row marked green.
        def row(clone, candidate, constraints)
          ref   = paint(candidate.ref, (candidate.ref_type == 'tag') ? :cyan : :magenta)
          date  = clone.log('-1', '--format=%cs', "#{candidate.ref}^{commit}") || ''
          cells = constraints.map do |c|
            verdict = c.check(candidate.metadata)
            paint(verdict, *STYLE.fetch(verdict.split.first, []))
          end
          [candidate.version.to_s, ref, date] + cells + [candidate.current ? paint('(deployed)', :green) : '']
        end

        def config_defaults
          { branchfile: ::Pupgrade.config.dig('modules', 'branchfile') }.compact
        end
      end
    end
  end
end
