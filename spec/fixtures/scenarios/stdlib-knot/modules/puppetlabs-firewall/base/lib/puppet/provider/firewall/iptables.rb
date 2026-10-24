Puppet::Type.type(:firewall).provide(:iptables) do
  KERNEL = Facter.value(:kernel)
  commands iptables: 'iptables'
  def self.instances
    []
  end
end
