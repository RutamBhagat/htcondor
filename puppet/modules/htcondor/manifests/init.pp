# Two-node Ubuntu lab only. Credentials are never values in this catalog.
class htcondor (
  Enum['controller', 'worker'] $role,
  String[1] $cm,
  String[1] $own,
  String[1] $peer,
) {
  if $facts['os']['name'] != 'Ubuntu' or $facts['os']['release']['major'] != '24.04' or $facts['os']['architecture'] != 'amd64' {
    fail('htcondor requires Ubuntu 24.04 amd64')
  }
  # Match the measured bootstrap's canonical IPv4/private classification,
  # including reserved private ranges; do not silently narrow it to RFC1918.
  [$cm, $own, $peer].each |$address| {
    if $address !~ /\A(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}\z/ {
      fail('Pool addresses must be canonical private IPv4')
    }
    $octets = split($address, '[.]').map |$octet| { Integer($octet) }
    $a = $octets[0]
    $b = $octets[1]
    $c = $octets[2]
    $d = $octets[3]
    if $octets.any |$octet| { $octet > 255 } or $a == 127 or ($a == 0 and $b == 0 and $c == 0 and $d == 0) {
      fail('Pool addresses must be canonical private IPv4')
    }
    $private = $a == 0 or $a == 10 or $a >= 240 or ($a == 169 and $b == 254) or
      ($a == 172 and $b >= 16 and $b <= 31) or ($a == 192 and $b == 0 and $c == 0 and $d != 9 and $d != 10) or
      ($a == 192 and $b == 0 and $c == 2) or ($a == 192 and $b == 168) or ($a == 198 and ($b == 18 or $b == 19)) or
      ($a == 198 and $b == 51 and $c == 100) or ($a == 203 and $b == 0 and $c == 113)
    if !$private { fail('Pool addresses must be canonical private IPv4') }
  }
  if $own == $peer or ($role == 'controller' and $cm != $own) or ($role == 'worker' and $cm != $peer) {
    fail('Addresses do not match the two-node topology')
  }

  file { '/etc/apt/keyrings': ensure => directory, owner => 'root', group => 'root', mode => '0755' }
  file { '/etc/apt/keyrings/htcondor.asc':
    ensure => file, owner => 'root', group => 'root', mode => '0644',
    source => 'puppet:///modules/htcondor/htcondor.asc', require => File['/etc/apt/keyrings'],
  }
  file { '/etc/apt/sources.list.d/htcondor.list':
    ensure => file, owner => 'root', group => 'root', mode => '0644',
    content => "deb [signed-by=/etc/apt/keyrings/htcondor.asc] https://htcss-downloads.chtc.wisc.edu/repo/ubuntu/25.0 noble main\ndeb-src [signed-by=/etc/apt/keyrings/htcondor.asc] https://htcss-downloads.chtc.wisc.edu/repo/ubuntu/25.0 noble main\n",
  }
  exec { 'refresh-htcondor-apt':
    command => '/usr/bin/apt-get update --error-on=any', refreshonly => true,
    subscribe => [File['/etc/apt/keyrings/htcondor.asc'], File['/etc/apt/sources.list.d/htcondor.list']],
    timeout => 300,
  }
  # On a fresh host, prevent package postinst from starting the collector and
  # auto-generating a different POOL key before the shared credential exists.
  exec { 'mask-fresh-condor':
    command => '/usr/bin/systemctl mask condor.service',
    unless => '/usr/bin/test -f /etc/condor/condor_config',
  }
  package { 'condor':
    ensure => '25.0.14-1+ubu24', provider => apt,
    require => [Exec['refresh-htcondor-apt'], Exec['mask-fresh-condor']],
  }
  package { ['iptables-persistent', 'netfilter-persistent']: ensure => installed }

  file { '/etc/condor/config.d':
    ensure => directory, owner => 'root', group => 'root', mode => '0755', require => Package['condor'],
  }
  file { '/etc/condor/config.d/00-security':
    ensure => file, owner => 'root', group => 'root', mode => '0644',
    content => "use security:recommended\n", require => Package['condor'], notify => Service['condor'],
  }
  $role_files = {
    '01-central-manager.config' => 'get_htcondor_central_manager',
    '01-submit.config' => 'get_htcondor_submit',
    '01-execute.config' => 'get_htcondor_execute',
  }
  $role_files.each |$filename, $metaknob| {
    $present = ($role == 'controller' and $filename != '01-execute.config') or ($role == 'worker' and $filename == '01-execute.config')
    if $present {
      file { "/etc/condor/config.d/${filename}":
        ensure => file, owner => 'root', group => 'root', mode => '0644',
        content => epp('htcondor/role.epp', { 'cm' => $cm, 'metaknob' => $metaknob }),
        require => File['/etc/condor/config.d'], notify => Service['condor'],
      }
    } else {
      file { "/etc/condor/config.d/${filename}":
        ensure => absent, require => Package['condor'], notify => Service['condor'],
      }
    }
  }
  file { '/etc/condor/config.d/02-private-network.config':
    ensure => file, owner => 'root', group => 'root', mode => '0644',
    content => epp('htcondor/private-network.epp', { 'own' => $own }),
    require => File['/etc/condor/config.d'], notify => Service['condor'],
  }
  # Retain package-owned main/plugin configuration and queued job data.
  file { ['/var/run/condor', '/var/lock/condor']:
    ensure => directory, owner => 'condor', group => 'condor', mode => '0775', require => Package['condor'],
  }
  file { '/var/log/condor':
    ensure => directory, owner => 'condor', group => 'root', mode => '0755', require => Package['condor'],
  }
  file { ['/var/spool/condor', '/var/lib/condor/execute']:
    ensure => directory, owner => 'condor', group => 'condor', mode => '0755', require => Package['condor'],
  }
  file { '/etc/condor/condor_config.local': ensure => absent, require => Package['condor'], notify => Service['condor'] }
  file { ['/etc/condor/passwords.d', '/etc/condor/tokens.d']:
    ensure => directory, owner => 'root', group => 'root', mode => '0700', require => Package['condor'],
  }
  file { '/usr/local/sbin/htcondor-credentials':
    ensure => file, owner => 'root', group => 'root', mode => '0700', source => 'puppet:///modules/htcondor/credentials.sh',
  }
  exec { 'provision-pool-key':
    command => '/usr/local/sbin/htcondor-credentials key /run/htcondor-pool-password /etc/condor/passwords.d/POOL',
    unless => "/bin/bash -c 'test -f /etc/condor/passwords.d/POOL && test ! -L /etc/condor/passwords.d/POOL && test -s /etc/condor/passwords.d/POOL'",
    require => [File['/usr/local/sbin/htcondor-credentials'], File['/etc/condor/passwords.d'], File['/etc/condor/config.d/00-security'],
      File['/etc/condor/config.d/01-central-manager.config'], File['/etc/condor/config.d/01-submit.config'],
      File['/etc/condor/config.d/01-execute.config'], File['/etc/condor/config.d/02-private-network.config']],
    logoutput => false, notify => Service['condor'],
  }
  file { '/etc/condor/passwords.d/POOL':
    ensure => file, owner => 'root', group => 'root', mode => '0600', show_diff => false,
    require => Exec['provision-pool-key'], notify => Service['condor'],
  }
  $token = "/etc/condor/tokens.d/condor@${cm}"
  exec { 'provision-daemon-token':
    command => "/usr/local/sbin/htcondor-credentials token condor@${cm} ${token}",
    unless => "/bin/bash -c 'test -f ${token} && test ! -L ${token} && test -s ${token}'",
    require => [File['/etc/condor/passwords.d/POOL'], File['/etc/condor/tokens.d'], File['/usr/local/sbin/htcondor-credentials']],
    logoutput => false, notify => Service['condor'],
  }
  file { $token:
    ensure => file, owner => 'root', group => 'root', mode => '0600', show_diff => false,
    require => Exec['provision-daemon-token'], notify => Service['condor'],
  }

  file { '/usr/local/sbin/htcondor-firewall':
    ensure => file, owner => 'root', group => 'root', mode => '0700', source => 'puppet:///modules/htcondor/firewall.sh',
  }
  $rule = "-A INPUT -s ${peer}/32 -d ${own}/32 -p tcp -m tcp --dport 9618 -j ACCEPT"
  exec { 'private-condor-firewall':
    command => "/usr/local/sbin/htcondor-firewall ${peer} ${own}",
    unless => "/bin/bash -c '[ \"$(/usr/sbin/iptables -w -S INPUT | /usr/bin/awk \"/^-A INPUT/ {print;exit}\")\" = \"${rule}\" ] && [ \"$(/usr/bin/awk \"/^-A INPUT/ {print;exit}\" /etc/iptables/rules.v4)\" = \"${rule}\" ]'",
    require => [File['/usr/local/sbin/htcondor-firewall'], Package['iptables-persistent'], Package['netfilter-persistent']],
  }
  service { 'netfilter-persistent': ensure => running, enable => true, require => Package['netfilter-persistent'] }
  exec { 'unmask-configured-condor':
    command => '/usr/bin/systemctl unmask condor.service',
    onlyif => "/bin/bash -c '[[ $(/usr/bin/systemctl is-enabled condor.service) == masked ]]'",
    require => [Package['condor'], File[$token], Exec['private-condor-firewall']],
  }
  service { 'condor':
    ensure => running, enable => true, provider => systemd,
    require => [Exec['unmask-configured-condor'], File['/var/run/condor'], File['/var/lock/condor'],
      File['/var/log/condor'], File['/var/spool/condor'], File['/var/lib/condor/execute'],
      File['/etc/condor/condor_config.local'], File['/etc/condor/config.d/00-security'],
      File['/etc/condor/config.d/01-central-manager.config'], File['/etc/condor/config.d/01-submit.config'],
      File['/etc/condor/config.d/01-execute.config'], File['/etc/condor/config.d/02-private-network.config']],
  }
}
