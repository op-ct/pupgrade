Puppet::Functions.create_function(:'stdlib::run_hostname') do
  dispatch(:run) {}
  def run
    Puppet::Util::Execution.execute(['hostname', '-f']).to_s.strip
  end
end
