require 'pupgrade/cli/base'
require 'pupgrade/cli/root'

module Pupgrade
  module CLI
    class Help < Base
      register_command name: 'help', subcommand_of: Root
      desc 'Show help for a command (e.g. `pupgrade help module`)'

      def run(argv)
        argv = argv.dup

        # `pupgrade help --help` — describe ourselves, don't try to walk.
        if %w[-h --help].include?(argv.first)
          print_help
          exit 0
        end

        cursor = Root
        path   = []
        until argv.empty?
          sub_name = argv.shift
          child =
            begin
              cursor.find_subcommand(sub_name)
            rescue Base::AmbiguousSubcommand => e
              ::Pupgrade.logger.fatal(e.message)
              Root.new.print_help($stderr)
              exit 2
            end

          unless child
            ::Pupgrade.logger.fatal("unknown command: #{(path + [sub_name]).join(' ')}")
            Root.new.print_help($stderr)
            exit 2
          end
          cursor = child
          path << sub_name
        end

        cursor.new.print_help
        exit 0
      end
    end
  end
end
