class { 'htcondor':
  role => 'controller',
  cm   => $facts['htcondor_cm'],
  own  => $facts['htcondor_own'],
  peer => $facts['htcondor_peer'],
}
