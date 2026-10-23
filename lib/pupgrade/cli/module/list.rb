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
        desc 'List the modules the control repo deploys, as declared and as found'

        COLUMNS = %w[path name declared deployed version].freeze

        def execute(argv)
          reject_extra_args!(argv, max: 1)
          repo = control_repo!('module list')
          require 'driftless/module_inventory'
          inventory = ::Driftless::ModuleInventory.new(repo.dir)
          inventory.warnings.each { |w| ::Pupgrade.logger.warn(w) }
          globs = argv.first.to_s.split(',').reject(&:empty?)
          rows  = inventory.entries.select { |e| globs.empty? || ::Pupgrade::ModuleName.any?(globs, e.metadata.name, e.declared&.name, File.basename(e.path)) }
          print_table(COLUMNS, rows.map { |e| row(e) })
          ::Pupgrade.logger.notice("module list: #{rows.size} module(s)")
          exit 0
        end

        protected

        def configure_parser(o)
          declare_repo_option(o)
          o.separator ''
          o.separator '<globs> narrow by any spelling of a module\'s name, comma-separated. "deployed" is how the'
          o.separator 'directory compares with the Puppetfile: match, differ (with what is there), absent, or'
          o.separator 'unknown when nothing is declared or the directory cannot say.'
        end

        private

        def row(entry)
          declared = entry.declared
          what =
            if declared.nil? then '(not in the Puppetfile)'
            elsif declared.git then "#{declared.ref_type || 'ref'} #{declared.ref || 'HEAD'}"
            else "#{declared.version || '(no version)'} (forge)"
            end
          deployed = entry.deployed.to_s
          deployed += " (#{entry.found})" if entry.found
          [entry.path, entry.metadata.name || declared&.name || '', what, deployed, entry.metadata.version.to_s]
        end
      end
    end
  end
end
