Puppet::Functions.create_function(:'stdlib::shout') do
  dispatch(:shout) do
    param 'String', :text
    optional_param 'Integer', :times
  end
  def shout(text, times = 1)
    (text.upcase + ' ') * times
  end
end
