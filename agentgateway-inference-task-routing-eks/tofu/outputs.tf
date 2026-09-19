output "gateway_url" {
  description = "Base URL for clients. scripts/10-claude-code.sh and the Cursor appendix take this."
  value       = "https://${local.gateway_fqdn}"
}

output "gateway_host" {
  description = "Hostname on its own, which is what HOST= expects."
  value       = local.gateway_fqdn
}

output "ui_url" {
  description = "Solo Enterprise UI, reachable only from ui_allowed_cidrs."
  value       = "https://${local.ui_fqdn}/age/"
}

output "ui_allowed_cidrs" {
  description = "What the UI's load balancer will currently accept. A timeout in the browser usually means your address is not in this list."
  value       = var.ui_allowed_cidrs
}

output "gateway_elb_hostname" {
  description = "The ELB behind the gateway name, for when DNS has not caught up yet."
  value       = kubernetes_service.gateway_public.status[0].load_balancer[0].ingress[0].hostname
}

output "ui_elb_hostname" {
  description = "The ELB behind the UI name."
  value       = kubernetes_service.ui_public.status[0].load_balancer[0].ingress[0].hostname
}
