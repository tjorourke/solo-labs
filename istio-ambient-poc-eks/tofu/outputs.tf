output "region" { value = var.region }

output "clusters" {
  description = "Cluster name -> VPC CIDR, API endpoint"
  value = {
    for k, m in module.eks : k => {
      vpc_cidr = var.clusters[k].vpc_cidr
      endpoint = m.cluster_endpoint
    }
  }
}

output "kubeconfig_commands" {
  description = "Run these to get a kube context per cluster, named after the cluster."
  value = [
    for k in local.cluster_names :
    "aws eks update-kubeconfig --region ${var.region} --name ${k} --alias ${k}"
  ]
}

output "vm_instance_id" { value = aws_instance.vm.id }
output "vm_private_ip" { value = aws_instance.vm.private_ip }
output "vm_ssm_command" {
  value = "aws ssm start-session --region ${var.region} --target ${aws_instance.vm.id}"
}
