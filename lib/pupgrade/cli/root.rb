require 'pupgrade/version'
require 'pupgrade/config'
require 'pupgrade/config_validator'
require 'pupgrade/cli/base'

module Pupgrade
  module CLI
    class Root < Base
      register_command name: 'pupgrade'
      desc 'Puppet/OpenVox control-repo upgrade helper: what would moving a module break?'

      protected

      def configure_parser(o)
        o.on('--version', 'Print the pupgrade version') do
          puts Pupgrade::VERSION
          exit 0
        end
      end
    end
  end
end

# Load Root's siblings — each child registers itself via subcommand_of Root.
Dir[File.join(__dir__, '*.rb')].sort.each do |file|
  next if %w[base.rb root.rb].include?(File.basename(file))
  require file
end
