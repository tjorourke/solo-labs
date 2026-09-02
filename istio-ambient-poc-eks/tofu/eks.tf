module "eks" {
  source   = "terraform-aws-modules/eks/aws"
  version  = "21.25.0"
  for_each = var.clusters

  name               = each.key
  kubernetes_version = var.kubernetes_version

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  # the identity running tofu becomes cluster-admin (EKS access entry)
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc[each.key].vpc_id
  subnet_ids = module.vpc[each.key].private_subnets

  addons = {
    coredns                = {}
    kube-proxy             = {}
    eks-pod-identity-agent = { before_compute = true }
    vpc-cni                = { before_compute = true }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = each.value.instance_types
      min_size       = each.value.desired_size
      max_size       = each.value.desired_size + 1
      desired_size   = each.value.desired_size
    }
  }

  # Mesh traffic between the two VPCs and from the VM lands on the nodes:
  # HBONE :15008 and XDS :15012 on the east-west gateway NodePorts, plus the
  # VM gateway's own HBONE. Allow the peer VPC + this VPC on all ports; the
  # mesh authorises at L4/L7 with mTLS identity, not with security groups.
  node_security_group_additional_rules = {
    mesh_from_lab_vpcs = {
      description = "HBONE/XDS from the peer cluster VPC and the VM"
      protocol    = "tcp"
      from_port   = 0
      to_port     = 65535
      type        = "ingress"
      cidr_blocks = local.all_cidrs
    }
  }

  # Cluster / node CloudWatch logs are noise for a POC; keep the bill down.
  enabled_log_types           = []
  create_cloudwatch_log_group = false
}
