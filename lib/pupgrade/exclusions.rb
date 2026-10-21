require 'pupgrade/module_name'

module Pupgrade
  # The `modules.exclude_*` lists, read the same way by `check` and `solve`.
  # A module glob names a module by any spelling ({ModuleName}). A
  # dependency glob is either a module glob, matching the depending module
  # or the dependency, or `depender:dependency`, matching the one edge, with
  # an optional version constraint after a space, `a:b < 5.0.0`, matching
  # the edge only while `a` declares that constraint on `b`. An exclusion
  # with a constraint that no longer matches is stale, and says so.
  module Exclusions
    module_function

    # @param globs [Array<String>] `exclude_modules`
    # @param names [Array<String, nil>] the module's spellings
    def module?(globs, *names)
      ModuleName.any?(globs, *names)
    end

    # One dependency edge against `exclude_dependencies`.
    #
    # @param globs [Array<String>]
    # @param depender [Array<String, nil>] the depending module's spellings
    # @param dependency [Array<String, nil>] the dependency's spellings
    # @param requirement [String, nil] the range the depender declares
    # @return [Array(Boolean, Array<String>)] whether the edge is excluded, and
    #   the stale exclusions met on the way
    def dependency?(globs, depender, dependency, requirement)
      stale = []
      hit = Array(globs).any? do |glob|
        left, right = glob.split(':', 2)
        if right.nil?
          ModuleName.any?([glob], *depender) || ModuleName.any?([glob], *dependency)
        else
          dep_glob, constraint = right.strip.split(/\s+/, 2)
          next false unless ModuleName.any?([left], *depender) && ModuleName.any?([dep_glob], *dependency)
          next true if constraint.nil?
          next true if squash(constraint) == squash(requirement)

          stale << "exclusion #{glob.inspect} is stale: #{depender.compact.first} now needs #{dependency.compact.first} #{requirement || '(any version)'}"
          false
        end
      end
      [hit, stale]
    end

    # A module against `exclude_requirements`.
    def requirement?(globs, *names)
      ModuleName.any?(globs, *names)
    end

    # An operating-system row against `exclude_operatingsystems`: a module
    # glob, an "OS release" glob, or `module:OS release`.
    #
    # @param names [Array<String, nil>] the module's spellings
    # @param subject [String] "RedHat 9"
    def operatingsystem?(globs, names, subject)
      Array(globs).any? do |glob|
        left, right = glob.split(':', 2)
        if right.nil?
          ModuleName.any?([glob], *names) || File.fnmatch?(glob, subject, File::FNM_CASEFOLD)
        else
          ModuleName.any?([left], *names) && File.fnmatch?(right, subject, File::FNM_CASEFOLD)
        end
      end
    end

    def squash(text)
      text.to_s.delete(' ')
    end
  end
end
