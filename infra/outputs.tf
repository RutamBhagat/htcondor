output "node_private_ips" {
  description = "Private addresses used for HTCondor pool traffic."
  value       = { for role, node in oci_core_instance.node : role => node.private_ip }
}

output "node_public_ips" {
  description = "Ephemeral public addresses used only for SSH administration."
  value       = { for role, node in oci_core_instance.node : role => node.public_ip }
}
