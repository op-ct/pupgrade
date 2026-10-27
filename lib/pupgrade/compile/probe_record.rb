require 'json'

module Pupgrade
  module Compile
    # The probe record `compile` writes beside each catalog, and the check
    # every reader makes before trusting one: that it is a probe record, and
    # of the schema this pupgrade reads. A record written by another
    # pupgrade is refused with a message saying which side is newer, since
    # `solve` and `impact` read these across releases.
    module ProbeRecord
      DOCUMENT       = 'probes'.freeze
      SCHEMA_VERSION = 2

      class Error < StandardError; end

      module_function

      # @param path [String] a probes.json
      # @return [Hash] the record
      # @raise [Error] when the file is not a probe record of this schema
      def read(path)
        data = JSON.parse(File.read(path))
        raise Error, "#{path}: not a probe record (document #{data['document'].inspect})" unless data.is_a?(Hash) && data['document'] == DOCUMENT

        version = data['schema_version']
        unless version == SCHEMA_VERSION
          side = (version.to_i > SCHEMA_VERSION) ? 'newer than this pupgrade reads' : 'older than this pupgrade reads'
          raise Error, "#{path}: probe record schema #{version.inspect} is #{side} (#{SCHEMA_VERSION}); compile again with this pupgrade"
        end
        data
      rescue JSON::ParserError => e
        raise Error, "#{path}: #{e.message}"
      rescue Errno::ENOENT
        raise Error, "#{path}: no such file"
      end
    end
  end
end
