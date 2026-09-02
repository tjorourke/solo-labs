data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs           = slice(data.aws_availability_zones.available.names, 0, 3)
  cluster_names = sort(keys(var.clusters))
  all_cidrs     = [for c in var.clusters : c.vpc_cidr]
}

# One VPC per cluster: three AZs, public + private subnets, one NAT gateway.
# The role tags let the in-tree Kubernetes cloud provider find subnets for
# LoadBalancer Services (internal for the east-west gateways, public for the UI).
module "vpc" {
  source   = "terraform-aws-modules/vpc/aws"
  version  = "6.7.2"
  for_each = var.clusters

  name = each.key
  cidr = each.value.vpc_cidr
  azs  = local.azs

  private_subnets = [for i in range(3) : cidrsubnet(each.value.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(3) : cidrsubnet(each.value.vpc_cidr, 8, 100 + i)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"            = "1"
    "kubernetes.io/cluster/${each.key}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"   = "1"
    "kubernetes.io/cluster/${each.key}" = "shared"
  }
}

# VPC peering between the two cluster VPCs. This is what lets the east-west
# gateways sit on INTERNAL load balancers and lets every mesh pod reach the VM
# by its private IP. Nothing in the mesh path touches the internet.
resource "aws_vpc_peering_connection" "a_b" {
  vpc_id      = module.vpc[local.cluster_names[0]].vpc_id
  peer_vpc_id = module.vpc[local.cluster_names[1]].vpc_id
  auto_accept = true

  accepter { allow_remote_vpc_dns_resolution = true }
  requester { allow_remote_vpc_dns_resolution = true }

  tags = { Name = "${local.cluster_names[0]}-${local.cluster_names[1]}" }
}

locals {
  # every route table in A gets a route to B's CIDR and vice versa
  peer_routes = merge(
    {
      for idx, rt in concat(
        module.vpc[local.cluster_names[0]].private_route_table_ids,
        module.vpc[local.cluster_names[0]].public_route_table_ids,
      ) : "a-${idx}" => { rt = rt, cidr = var.clusters[local.cluster_names[1]].vpc_cidr }
    },
    {
      for idx, rt in concat(
        module.vpc[local.cluster_names[1]].private_route_table_ids,
        module.vpc[local.cluster_names[1]].public_route_table_ids,
      ) : "b-${idx}" => { rt = rt, cidr = var.clusters[local.cluster_names[0]].vpc_cidr }
    },
  )
}

resource "aws_route" "peer" {
  for_each                  = local.peer_routes
  route_table_id            = each.value.rt
  destination_cidr_block    = each.value.cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.a_b.id
}
