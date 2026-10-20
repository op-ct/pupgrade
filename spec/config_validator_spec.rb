require 'spec_helper'

require 'pupgrade/config'
require 'pupgrade/config_validator'

RSpec.describe Pupgrade::ConfigValidator do
  def validate(hash)
    described_class.new(Pupgrade::Config.new(merged: hash)).validate!
  end

  it 'accepts declared keys and anchor holders' do
    expect { validate('logging' => { 'level' => 'warn' }, 'output' => { 'color' => false }, '.anchors' => { 'x' => 1 }) }.not_to raise_error
  end

  it 'rejects unknown subsystems and keys, suggesting a close match' do
    expect { validate('loging' => {}) }.to raise_error(Pupgrade::ConfigValidationError, /unknown top-level config key: "loging" \(did you mean "logging"\?\)/)
    expect { validate('logging' => { 'levle' => 'debug' }) }.to raise_error(Pupgrade::ConfigValidationError, /unknown logging config key: "levle" \(did you mean "level"\?\)/)
    expect { validate('scan' => {}) }.to raise_error(Pupgrade::ConfigValidationError, /unknown top-level config key: "scan" \(known: .*\blogging\b.*\)/)
  end
end
