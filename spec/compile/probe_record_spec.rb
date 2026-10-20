require 'spec_helper'
require 'tmpdir'
require 'json'

require 'pupgrade/compile/probe_record'

RSpec.describe Pupgrade::Compile::ProbeRecord do
  def write(dir, data)
    path = File.join(dir, 'probes.json')
    File.write(path, data.is_a?(String) ? data : JSON.generate(data))
    path
  end

  it 'reads a record of its own schema and refuses any other' do
    Dir.mktmpdir do |dir|
      good = write(dir, 'document' => 'probes', 'schema_version' => described_class::SCHEMA_VERSION, 'certname' => 'a')
      expect(described_class.read(good)['certname']).to eq('a')

      newer = write(dir, 'document' => 'probes', 'schema_version' => described_class::SCHEMA_VERSION + 1)
      expect { described_class.read(newer) }.to raise_error(described_class::Error, /schema 2 is newer than this pupgrade reads \(1\); compile again/)
      older = write(dir, 'document' => 'probes', 'schema_version' => 0)
      expect { described_class.read(older) }.to raise_error(described_class::Error, /schema 0 is older/)
      other = write(dir, 'document' => 'catalog', 'schema_version' => 1)
      expect { described_class.read(other) }.to raise_error(described_class::Error, /not a probe record \(document "catalog"\)/)
      broken = write(dir, '{')
      expect { described_class.read(broken) }.to raise_error(described_class::Error, /probes\.json: /)
      expect { described_class.read(File.join(dir, 'nope.json')) }.to raise_error(described_class::Error, /no such file/)
    end
  end
end
