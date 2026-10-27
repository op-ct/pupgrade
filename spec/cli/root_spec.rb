require 'spec_helper'
require 'stringio'

RSpec.describe Pupgrade::CLI::Root do
  # [exit status, stdout]
  def run(argv)
    out      = StringIO.new
    original = $stdout
    $stdout  = out
    status   = nil
    begin
      described_class.new.run(argv)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
    end
    [status, out.string]
  end

  around(:each) do |ex|
    original = Pupgrade.instance_variable_get(:@config)
    ex.run
  ensure
    Pupgrade.instance_variable_set(:@config, original)
  end

  it 'prints the version, by flag and by subcommand' do
    expect(run(['--version'])).to eq([0, "#{Pupgrade::VERSION}\n"])
    expect(run(['version'])).to eq([0, "#{Pupgrade::VERSION}\n"])
  end

  it 'lists its subcommands in help' do
    status, out = run(['help'])
    expect(status).to eq(0)
    expect(out).to include('Usage: pupgrade [options] <subcommand>')
    expect(out.lines.grep(/^    (catalog|check|config|help|impact|module|solve|surface|version) /).size).to eq(9)
    expect(out.lines.grep(/^    compile /)).to be_empty
  end

  it 'runs catalog compile as the hidden compile, which no prefix reaches' do
    expect(described_class.find_subcommand('compile').superclass).to eq(Pupgrade::CLI::Catalog::Compile)
    expect(described_class.find_subcommand('co')).to eq(Pupgrade::CLI::Config)
    status, out = run(%w[compile --help])
    expect(status).to eq(0)
    expect(out).to include('Usage: pupgrade compile [options]', 'Compile factsets into catalogs')
  end
end
