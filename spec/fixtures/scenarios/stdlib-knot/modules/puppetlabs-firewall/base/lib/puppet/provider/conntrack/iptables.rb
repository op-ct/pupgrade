Puppet::Type.type(:firewall)
Puppet::Type.type(:conntrack).provide(:iptables, parent: Puppet::Type::Firewall::ProviderIptables) do
  commands conntrack: 'conntrack'
end
