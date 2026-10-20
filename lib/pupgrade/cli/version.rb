require 'pupgrade/version'
require 'pupgrade/cli/base'
require 'pupgrade/cli/root'

module Pupgrade
  module CLI
    class Version < Base
      register_command name: 'version', subcommand_of: Root
      desc 'Print the pupgrade version'
      skip_config_load

      def execute(_argv)
        puts Pupgrade::VERSION
        exit 0
      end
    end
  end
end
