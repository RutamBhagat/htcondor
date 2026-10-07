mock_provider "oci" {}

variables {
  compartment_id      = "ocid1.tenancy.oc1..example"
  region              = "eu-frankfurt-1"
  availability_domain = "example:EU-FRANKFURT-1-AD-3"
  image_id            = "ocid1.image.oc1.eu-frankfurt-1.example"
  admin_cidr          = "203.0.113.10/32"
  ssh_public_key      = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestOnlyKey"
}

run "free_tier_two_node_plan" {
  command = plan

  assert {
    condition     = length(oci_core_instance.node) == 2
    error_message = "The lab must provision exactly two compute instances."
  }

  assert {
    condition = alltrue([
      for instance in oci_core_instance.node : instance.shape == "VM.Standard.E2.1.Micro"
    ])
    error_message = "Every lab node must use the Always Free E2 micro shape."
  }

  assert {
    condition = alltrue([
      for instance in oci_core_instance.node : tonumber(instance.source_details[0].boot_volume_size_in_gbs) == 50
    ])
    error_message = "Every lab node must use a 50 GB boot volume."
  }

  assert {
    condition = length([
      for rule in oci_core_security_list.lab.ingress_security_rules : rule
      if rule.source == "0.0.0.0/0"
    ]) == 0
    error_message = "The lab security list must not allow unrestricted public ingress."
  }

  assert {
    condition = length([
      for rule in oci_core_security_list.lab.ingress_security_rules : rule
      if rule.source == var.vcn_cidr &&
      rule.protocol == "6" &&
      rule.tcp_options[0].min == 9618 &&
      rule.tcp_options[0].max == 9618
    ]) == 1
    error_message = "TCP/9618 must be allowed exactly once and only from the VCN CIDR."
  }
}
