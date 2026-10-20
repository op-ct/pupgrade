require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'

module Pupgrade
  # A module's API surfaces as a document, and the difference between two.
  # Extraction loads the module's Ruby, so it happens in a process of its
  # own ({Surface.extract}); the document comes back as JSON.
  module Surface
    class Error < StandardError; end

    LIB = File.expand_path('..', __dir__)

    module_function

    # @param dir [String] a module directory
    # @return [Hash] the surface document (see {Extract.document})
    # @raise [Error] when the extracting process fails
    def extract(dir)
      dir = File.expand_path(dir)
      raise Error, "#{dir}: no such directory" unless File.directory?(dir)

      out, err, status = Open3.capture3(RbConfig.ruby, '-I', LIB, '-r', 'pupgrade/surface/extract',
                                        '-e', 'print Pupgrade::Surface::Extract.json(ARGV[0])', '--', dir)
      raise Error, "extracting #{dir}: #{err.lines.reject { |l| l.strip.empty? }.last.to_s.strip}" unless status.success?

      JSON.parse(out)
    rescue JSON::ParserError => e
      raise Error, "extracting #{dir}: unreadable output: #{e.message}"
    end

    # The document in a file, or extracted from a module directory.
    #
    # @param path [String]
    # @return [Hash]
    # @raise [Error]
    def load(path)
      path = File.expand_path(path)
      return extract(path) if File.directory?(path)
      raise Error, "#{path}: no such file or directory" unless File.file?(path)

      data = JSON.parse(File.read(path))
      raise Error, "#{path}: not a surface document" unless data.is_a?(Hash) && data['document'] == 'surface'

      data
    rescue JSON::ParserError => e
      raise Error, "#{path}: #{e.message}"
    end

    # A module at a ref of a git remote, checked out shallow into a scratch
    # directory for the block, which is removed afterwards.
    #
    # @param url [String] anything `git fetch` accepts
    # @param ref [String] tag, branch, or sha
    # @yieldparam dir [String]
    # @raise [Error] when the fetch fails
    def checkout(url, ref)
      Dir.mktmpdir('pupgrade-surface') do |dir|
        git(dir, 'init', '-q')
        git(dir, 'fetch', '-q', '--depth', '1', url, ref)
        git(dir, 'checkout', '-q', 'FETCH_HEAD')
        yield dir
      end
    end

    def git(dir, *args)
      out, err, status = Open3.capture3({ 'GIT_TERMINAL_PROMPT' => '0' }, 'git', '-C', dir, *args)
      return out if status.success?

      line = err.lines.find { |l| l.start_with?('fatal:') } || err.lines.last
      raise Error, "git #{args.first}: #{line.to_s.strip}"
    rescue Errno::ENOENT
      raise Error, 'git is not installed'
    end
  end
end
