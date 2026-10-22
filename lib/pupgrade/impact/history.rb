require 'open3'
require 'semantic_puppet'

require 'pupgrade/logging'

module Pupgrade
  module Impact
    # What a module's repository says about the move: the commits between
    # the two refs, and the CHANGELOG sections for the versions crossed.
    class History
      # @!attribute [r] commits
      #   @return [Array<String>, nil] `git log --oneline` lines, oldest
      #     last; nil when the clone cannot answer
      # @!attribute [r] changelog
      #   @return [String, nil] the CHANGELOG sections crossed; nil when there
      #     is no CHANGELOG or no section matched
      Record = Data.define(:commits, :changelog)

      CHANGELOG_NAMES = %w[CHANGELOG.md CHANGELOG CHANGELOG.txt Changelog.md changelog.md].freeze

      # A release header: "## [1.2.3] - date", "## v1.2.3", "# 1.2.3 / 2024"
      HEADER = /\A\#{1,3}\s*\[?v?(\d+\.\d+\.\d+)\]?/.freeze

      # @param clone_dir [String] the deployed clone
      # @param from_ref [String] the current ref
      # @param to_ref [String] the proposed ref
      # @param from_version [String, nil] the current metadata version
      # @param to_version [String, nil] the proposed metadata version
      # @return [Record]
      def self.between(clone_dir, from_ref, to_ref, from_version: nil, to_version: nil)
        Pupgrade.logger.info("history: #{clone_dir}: #{from_ref}..#{to_ref}")
        log = git(clone_dir, 'log', '--oneline', '--no-decorate', "#{from_ref}..#{to_ref}")
        commits = log&.lines&.map(&:strip)&.reject(&:empty?)
        changelog = CHANGELOG_NAMES.filter_map { |n| git(clone_dir, 'show', "#{to_ref}:#{n}") }.first
        Pupgrade.logger.debug("history: #{clone_dir}: #{commits ? "#{commits.size} commit(s)" : 'log unavailable'}, changelog #{changelog ? 'found' : 'absent'}")
        Record.new(commits: commits, changelog: changelog && sections(changelog, from_version, to_version))
      end

      # The sections headed by a version above `from` and up to `to`.
      #
      # @return [String, nil]
      def self.sections(text, from, to)
        from_v = parse(from)
        to_v   = parse(to)
        keep   = false
        lines  = text.lines.select do |line|
          if (m = line.match(HEADER))
            v = parse(m[1])
            keep = v && (from_v.nil? || v > from_v) && (to_v.nil? || v <= to_v)
          end
          keep
        end
        lines.empty? ? nil : lines.join.strip
      end

      def self.parse(version)
        return nil if version.nil?

        SemanticPuppet::Version.parse(version.to_s.sub(/\Av/, ''))
      rescue SemanticPuppet::Version::ValidationFailure
        nil
      end

      def self.git(dir, *args)
        out, _err, status = Open3.capture3({ 'GIT_TERMINAL_PROMPT' => '0' }, 'git', '-C', dir, *args)
        status.success? ? out : nil
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
