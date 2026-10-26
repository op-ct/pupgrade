class profile::base (
  Array[String] $ntp_servers,
  String        $banner,
  Stdlib::Port  $port = 123,
) {
  include ntp
  include timezone
  $family  = $facts['os']['family']
  $legacy  = $osfamily
  $shouted = stdlib::shout('hi')
  $old     = legacy_shout('hi')
  $quiet   = stdlib::whisper('HI')
  $host    = stdlib::run_hostname()
  $servers = lookup('profile::base::ntp_servers')
  $absent  = lookup('profile::base::absent', undef, undef, 'default')
  $legacy_opt = lookup('apache::legacy_opt')
  $major   = $facts.dig('os', 'release', 'major')
  $known   = 'kernel' in $facts
  firewall { "100 allow ntp ${port}":
    ensure   => present,
    action   => 'accept',
    provider => 'iptables',
  }
  concat::fragment { 'motd':
    content => "${banner}: ${family} ${legacy} ${shouted} ${old} ${quiet} ${host} ${servers[0]} ${absent}",
  }
}
