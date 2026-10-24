Puppet::Type.newtype(:firewall) do
  ensurable
  newparam(:name, namevar: true)
  newparam(:action) do
    newvalues(:accept, :drop, :reject)
  end
  newparam(:chain)
end
