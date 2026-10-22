require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'

require 'pupgrade/logging'
require 'pupgrade/surface/extract'

module Pupgrade
  # A module's API surfaces as a document, and the difference between two.
  # Extraction loads the module's Ruby, so it happens in a process of its
  # own ({Surface.extract}); the document comes back as JSON.
  module Surface
    class Error < StandardError; end

    LIB = File.expand_path('..', __dir__)

    module_function

    # @param dir [String] a module directory
    # @param modulepath [Array<String>] directories whose modules the
    #   module's Ruby may need: types its providers extend, libraries its
    #   code requires
    # @return [Hash] the surface document (see {Extract.document})
    # @raise [Error] when the extracting process fails
    def extract(dir, modulepath: [])
      dir = File.expand_path(dir)
      raise Error, "#{dir}: no such directory" unless File.directory?(dir)

      Pupgrade.logger.info("surface: extracting #{dir}")
      Pupgrade.logger.debug("surface: modulepath #{modulepath.empty? ? '(none)' : modulepath.map { |m| File.expand_path(m) }.join(':')}")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out, err, status = Open3.capture3(RbConfig.ruby, '-I', LIB, '-r', 'pupgrade/surface/extract',
                                        '-e', 'print Pupgrade::Surface::Extract.json(ARGV[0], ARGV[1..])', '--', dir,
                                        *modulepath.map { |m| File.expand_path(m) })
      Pupgrade.logger.debug("surface: extracted #{dir} in #{'%.1f' % (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)}s, exit #{status.exitstatus}")
      err.lines.reject { |l| l.strip.empty? }.each { |l| Pupgrade.logger.trace("surface: #{File.basename(dir)}: #{l.rstrip}") }
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

      version = data['schema_version']
      unless version == Extract::SCHEMA_VERSION
        side = (version.to_i > Extract::SCHEMA_VERSION) ? 'newer than this pupgrade reads' : 'older than this pupgrade reads'
        raise Error, "#{path}: surface document schema #{version.inspect} is #{side} (#{Extract::SCHEMA_VERSION}); extract again with this pupgrade"
      end
      data
    rescue JSON::ParserError => e
      raise Error, "#{path}: #{e.message}"
    end

    # A module at a ref of a git remote (or of a clone, given its path),
    # checked out shallow into a scratch directory for the block, which is
    # removed afterwards. The checkout is named after the module, so Puppet's
    # loaders find it by name.
    #
    # @param url [String] anything `git fetch` accepts
    # @param ref [String] tag, branch, or sha
    # @yieldparam dir [String]
    # @raise [Error] when the fetch fails
    def checkout(url, ref)
      Pupgrade.logger.debug("surface: checking out #{url} at #{ref}")
      Dir.mktmpdir('pupgrade-surface') do |tmp|
        work = File.join(tmp, 'checkout')
        FileUtils.mkdir_p(work)
        git(work, 'init', '-q')
        git(work, 'fetch', '-q', '--depth', '1', url, ref)
        git(work, 'checkout', '-q', 'FETCH_HEAD')
        name = module_name_in(work) || File.basename(url.to_s, '.git').split(/[-\/]/).last
        dir  = File.join(tmp, name)
        FileUtils.mv(work, dir)
        yield dir
      end
    end

    # @return [String, nil] the module's short name from its metadata.json
    def module_name_in(dir)
      data = JSON.parse(File.read(File.join(dir, 'metadata.json')))
      data['name'].to_s.split(/[-\/]/).last if data.is_a?(Hash) && data['name']
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end

    def git(dir, *args)
      out, err, status = Open3.capture3({ 'GIT_TERMINAL_PROMPT' => '0' }, 'git', '-C', dir, *args)
      Pupgrade.logger.trace("git -C #{dir} #{args.join(' ')}: exit #{status.exitstatus}#{"; #{err.strip.lines.last.strip}" unless err.strip.empty?}")
      return out if status.success?

      line = err.lines.find { |l| l.start_with?('fatal:') } || err.lines.last
      raise Error, "git #{args.first}: #{line.to_s.strip}"
    rescue Errno::ENOENT
      raise Error, 'git is not installed'
    end
  end
end
