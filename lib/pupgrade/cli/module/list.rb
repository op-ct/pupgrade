require 'pupgrade/cli/base'
require 'pupgrade/cli/module_command'
require 'pupgrade/cli/table'
require 'driftless/control_repo'
require 'driftless/module_inventory'
require 'pupgrade/module_name'

module Pupgrade
  module CLI
    class ModuleCommand
      # `pupgrade module list`
      #
      # Every module on the modulepath or in the Puppetfile: where it is,
      # what the Puppetfile declares, what is deployed, and whether they agree.
      class List < Base
        include ModuleCommand::Shared
        include Table

        register_command name: %w[list ls], subcommand_of: ModuleCommand
        positional '[<globs>]'
        desc 'List the modules the control repo deploys: what the Puppetfile declares, and what is on disk'

        COLUMNS = %w[path name declared deployed version].freeze
        STATE_COLORS = { match: :green, differ: :red, unknown: :yellow }.freeze

        def execute(argv)
          reject_extra_args!(argv, max: 1)
          repo = control_repo!('module list')
          require 'driftless/module_inventory'
          inventory = ::Driftless::ModuleInventory.new(repo.dir)
          inventory.warnings.each { |w| ::Pupgrade.logger.warn(w) }
          globs = argv.first.to_s.split(',').map { |g| g.chomp('/') }.reject(&:empty?)
          rows  = inventory.entries.select { |e| globs.empty? || ::Pupgrade::ModuleName.any?(globs, e.metadata.name, e.declared&.name, File.basename(e.path)) }
          @repo = repo
          if @options[:names_only]
            rows.each { |e| puts e.metadata.name || e.declared&.name || File.basename(e.path) }
          else
            print_table(COLUMNS, rows.map { |e| row(e) })
          end
          ::Pupgrade.logger.notice("module list: #{rows.size} module(s)")
          exit 0
        end

        protected

        def configure_parser(o)
          declare_repo_option(o)
          o.on('-1', '--names-only', 'One module name per line, the directory name when it has none, instead of the table') { @options[:names_only] = true }
          o.separator ''
          o.separator '<globs> narrow by any spelling of a module\'s name, comma-separated. "deployed" is how the'
          o.separator 'directory compares with the Puppetfile: match, differ (with what is there), absent, or'
          o.separator 'unknown when nothing is declared or the directory cannot say.'
        end

        private

        def row(entry)
          declared = entry.declared
          what =
            if declared.nil? then paint('(not in the Puppetfile)', :yellow)
            elsif declared.git
              kind, name, why = declared_ref(@repo, entry)
              "#{paint("#{kind} #{name}", *{ 'tag' => :cyan, 'branch' => :magenta }[kind])}#{" (#{why})" if why}"
            elsif declared.local then "#{paint('(no version)', :yellow)} (local)"
            elsif declared.version then "#{declared.version} (forge)"
            else "#{paint('(no version)', :yellow)} (forge)"
            end
          deployed = entry.deployed.to_s
          deployed += " (#{entry.found})" if entry.found
          [entry.path, entry.metadata.name || declared&.name || '', what, paint(deployed, *STATE_COLORS[entry.deployed]), entry.metadata.version.to_s]
        end
      end
    end
  end
end
