require 'stringio'
require 'tmpdir'
require 'yaml'

require 'spec_helper'
require 'pupgrade/cli/config/new'
require 'pupgrade/config_validator'

RSpec.describe Pupgrade::CLI::Config::New do
  def generate(argv = [], **options)
    dir     = Dir.mktmpdir
    path    = File.join(dir, 'pupgrade.yaml')
    status  = nil
    cli     = described_class.new
    cli.instance_variable_set(:@options, { path: path }.merge(options))
    begin
      capture_stdout { cli.execute(argv) }
    rescue SystemExit => e
      status = e.status
    end
    [path, (File.exist?(path) ? File.read(path) : nil), status]
  end

  def capture_stdout
    original = $stdout
    $stdout  = StringIO.new
    yield
  ensure
    $stdout = original
  end

  # Every line carries one "# " of commenting; stripping it must yield a
  # usable config, with prose lines surviving as ordinary YAML comments.
  def uncommented(text)
    text.lines.map { |l| l.sub(/\A# ?/, '') }.join
  end

  it 'writes an inert file that is valid, validator-clean YAML once uncommented' do
    path, content, status = generate
    expect(status).to eq(0)
    expect(File.exist?(path)).to be(true)
    expect(content).to include('pupgrade configuration', '/etc/puppetlabs/pupgrade/config.yaml')
    expect(YAML.safe_load(content)).to be_nil
    cfg = Pupgrade::Config.new(merged: YAML.safe_load(uncommented(content)))
    expect { Pupgrade::ConfigValidator.new(cfg).validate! }.not_to raise_error
  end

  it 'lists every settable key under its subsystem, compile first, logging last' do
    _path, content, = generate
    Pupgrade::ConfigKeys.all.each do |key|
      expect(content).to match(/^#   #{Regexp.escape(key.name)}:/), key.path
    end
    indexes = %w[compile modules solve impact output logging].map { |name| content.index(/^# #{name}:/) }
    expect(indexes).to all(be_an(Integer))
    expect(indexes).to eq(indexes.sort)
  end

  describe '<subsystem.key>=<value> arguments' do
    # [exit status, log] of a run expected to stop before writing
    def attempt(argv)
      cli = described_class.new
      cli.instance_variable_set(:@options, { path: '--' })
      status = nil
      log = capture_log do
        expect { capture_stdout { cli.execute(argv) } }
          .to raise_error(SystemExit) { |e| status = e.status }
          .and output.to_stderr
      end
      [status, log]
    end

    it 'renders exactly the given keys live, arrays split on commas, with the comment one layer removed' do
      _path, content, status = generate(['compile.factsets=spec/factsets,more', 'compile.on_leak=allow'])
      expect(status).to eq(0)
      expect(YAML.safe_load(content)).to eq('compile' => { 'factsets' => ['spec/factsets', 'more'], 'on_leak' => 'allow' })
      expect(content).to match(/^  # Factset files or directories/)
      expect(content).not_to match(/^#   # Factset files or directories/)
      cfg = Pupgrade::Config.new(merged: YAML.safe_load(uncommented(content)))
      expect { Pupgrade::ConfigValidator.new(cfg).validate! }.not_to raise_error
    end

    it 'rejects an unknown key with a suggestion, a mapping key, and a malformed argument, before writing' do
      status, log = attempt(['compile.factset=x'])
      expect(status).to eq(2)
      expect(log).to include('did you mean "factsets"')
      status, log = attempt(['modules.operatingsystems=RedHat'])
      expect(status).to eq(2)
      expect(log).to include('takes a mapping; set it in the file')
      status, log = attempt(['compile.factsets'])
      expect(status).to eq(2)
      expect(log).to include('expected <subsystem.key>=<value>')
    end
  end

  it 'refuses to clobber an existing file unless --force, and replaces a malformed one' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'pupgrade.yaml')
      File.write(path, "{\n")
      _path, _content, status = generate([], path: path)
      expect(status).to eq(3)
      expect(File.read(path)).to eq("{\n")
      Dir.chdir(dir) do
        expect { capture_stdout { described_class.new.run(['--path', path, '--force']) } }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      end
      expect(File.read(path)).to include('pupgrade configuration')
    end
  end
end
