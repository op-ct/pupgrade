require 'pupgrade/cli/base'
require 'pupgrade/cli/root'

module Pupgrade
  module CLI
    # `pupgrade params`: the parent of the commands on recorded class-param
    # schemas, the documents driftless's `params record` writes.
    class Params < Base
      register_command name: 'params', subcommand_of: Root
      desc 'Compare recorded schemas of class params (see subcommands)'
    end
  end
end

Dir[File.join(__dir__, 'params', '*.rb')].sort.each { |f| require f }
