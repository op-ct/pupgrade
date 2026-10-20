require 'pupgrade/cli/base'
require 'pupgrade/cli/root'

module Pupgrade
  module CLI
    # `pupgrade config`: the parent of the commands on pupgrade.yaml.
    class Config < Base
      register_command name: 'config', subcommand_of: Root
      desc 'Generate pupgrade.yaml (see subcommands)'
    end
  end
end

Dir[File.join(__dir__, 'config', '*.rb')].sort.each { |f| require f }
