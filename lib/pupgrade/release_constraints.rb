require 'semantic_puppet'

require 'driftless/inputs/module_metadata'
require 'pupgrade/module_name'
require 'pupgrade/module_resolver'

module Pupgrade
  # What a release of a module is held against, one column of `module
  # release` each: a dependency at a version, a Puppet version, or an
  # operating system release. Each has a heading and, for a release's
  # metadata, a cell saying whether the release meets it, and when not,
  # which way it misses.
  module ReleaseConstraints
    # A dependency at a version, against the release's range for it.
    class Dependency
      # @param name [String] the dependency, in any spelling
      # @param version [SemanticPuppet::Version]
      def initialize(name, version)
        @short   = ModuleName.short(name)
        @version = version
      end

      # @return [String] "stdlib 8.6.0"
      def heading
        "#{@short} #{@version}"
      end

      # @param metadata [Driftless::Inputs::ModuleMetadata::Result]
      # @return [String] "ok"; "needs RANGE (newer|older)"; "none" when the
      #   release does not depend on it
      def check(metadata)
        found = metadata.dependencies.find { |d, _| ModuleName.short(d) == @short }
        return 'none' unless found

        requirement = found.last
        range = ReleaseConstraints.range(requirement)
        range ? ReleaseConstraints.verdict(range, @version) : "needs #{requirement} (unparsed)"
      end
    end

    # A Puppet version, against the release's requirement.
    class Puppet
      # @param version [SemanticPuppet::Version]
      def initialize(version)
        @version = version
      end

      # @return [String] "puppet 8.0.0"
      def heading
        "puppet #{@version}"
      end

      # @param metadata [Driftless::Inputs::ModuleMetadata::Result]
      # @return [String] "ok"; "needs RANGE (newer|older)"; "undeclared"
      #   when the release requires no Puppet version
      def check(metadata)
        declared = metadata.requirements.values_at(*::Driftless::Inputs::ModuleMetadata::PUPPET_REQUIREMENT_NAMES).compact
        return 'undeclared' if declared.empty?

        ranges = declared.map { |r| ReleaseConstraints.range(r) }
        return "needs #{declared.join(', ')} (unparsed)" if ranges.any?(&:nil?)

        ReleaseConstraints.verdict(ranges.reduce { |a, b| a.intersection(b) }, @version)
      end
    end

    # An operating system, with a release of it or any, against what the
    # release supports.
    class OperatingSystem
      # @param os [String] as metadata names it, case aside
      # @param release [String, nil] nil for any release
      def initialize(os, release = nil)
        @os      = os
        @release = release
      end

      # @return [String] "RedHat 9"
      def heading
        [@os, @release].compact.join(' ')
      end

      # @param metadata [Driftless::Inputs::ModuleMetadata::Result]
      # @return [String] "ok"; "missing"; "missing (has 7, 8)" when the OS
      #   is supported at other releases; "undeclared" when the release
      #   names no operating system
      def check(metadata)
        support = metadata.operatingsystem_support
        return 'undeclared' if support.empty?

        declared = support.find { |name, _| name.casecmp?(@os) }&.last
        return 'missing' if declared.nil?
        return 'ok' if @release.nil? || declared.empty? || declared.any? { |d| ModuleResolver.release_matches?(d, @release) }

        "missing (has #{declared.join(', ')})"
      end
    end

    module_function

    # @return [String] "ok" when the range holds the version; else "needs
    #   RANGE", with "(newer)" when the version is below it and "(older)"
    #   when above
    def verdict(range, version)
      return 'ok' if range.include?(version)

      direction =
        if range.begin && (version < range.begin || (range.exclude_begin? && version == range.begin)) then ' (newer)'
        elsif range.end && version >= range.end then ' (older)'
        else ''
        end
      "needs #{range}#{direction}"
    end

    # @param text [String] a version; "8" and "8.1" read as "8.0.0" and "8.1.0"
    # @return [SemanticPuppet::Version]
    # @raise [ArgumentError] when it is not a version
    def version(text)
      parts = text.to_s.split('.', 3)
      parts.push('0') while parts.size < 3 && parts.all? { |p| p.match?(/\A\d+\z/) }
      SemanticPuppet::Version.parse(parts.join('.'))
    rescue SemanticPuppet::Version::ValidationFailure
      raise ArgumentError, "#{text.inspect} is not a version"
    end

    # @return [SemanticPuppet::VersionRange, nil] nil when the requirement
    #   does not parse; every version when there is none
    def range(requirement)
      return SemanticPuppet::VersionRange.parse('>= 0.0.0') if requirement.nil? || requirement.strip.empty?

      SemanticPuppet::VersionRange.parse(requirement)
    rescue ArgumentError
      nil
    end
  end
end
