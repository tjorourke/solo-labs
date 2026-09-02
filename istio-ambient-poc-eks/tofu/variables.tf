variable "region" {
  description = "AWS region for both clusters and the VM. One region, two VPCs."
  type        = string
  default     = "eu-west-1"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Solo Istio 1.30 supports 1.32 to 1.36."
  type        = string
  default     = "1.34"
}

variable "clusters" {
  description = "The two clusters. Keys are the cluster (and Istio network) names."
  type = map(object({
    vpc_cidr       = string
    instance_types = list(string)
    desired_size   = number
  }))
  default = {
    # eks-a also hosts the Gloo UI management plane, so it gets the bigger nodes
    eks-a = { vpc_cidr = "10.10.0.0/16", instance_types = ["m6i.xlarge"], desired_size = 2 }
    eks-b = { vpc_cidr = "10.20.0.0/16", instance_types = ["m6i.large"], desired_size = 2 }
  }
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the EKS API servers. Replace 0.0.0.0/0 with your admin egress CIDR before a real run."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "vm_instance_type" {
  description = "Instance type for the VM that joins the mesh (runs ztunnel in Docker + a small app)."
  type        = string
  default     = "t3.small"
}

variable "tags" {
  description = "Extra tags for every resource."
  type        = map(string)
  default     = {}
}
