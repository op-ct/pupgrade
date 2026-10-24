Puppet::Parser::Functions.newfunction(:legacy_shout, type: :rvalue) do |args|
  Puppet.deprecation_warning('legacy_shout is deprecated; use stdlib::shout')
  args[0].to_s.upcase
end
