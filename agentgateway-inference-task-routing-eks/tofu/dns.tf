# The certificates, and the records that validate them.
#
# Order matters and OpenTofu enforces it here, which is the reason this is not two
# kubectl commands: an ELB refuses to come up with a certificate ARN that is still
# PENDING_VALIDATION, so the Services in services.tf depend on the validation resources
# below rather than on the certificates themselves.

data "aws_route53_zone" "lab" {
  name         = var.route53_zone_name
  private_zone = false
}

locals {
  gateway_fqdn = "${var.gateway_subdomain}.${var.route53_zone_name}"
  ui_fqdn      = "${var.ui_subdomain}.${var.route53_zone_name}"
}

# ---------------------------------------------------------------------------
# The model endpoint
# ---------------------------------------------------------------------------

resource "aws_acm_certificate" "gateway" {
  domain_name       = local.gateway_fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# One domain per certificate and no SANs, so this is a single record rather than a
# for_each over domain_validation_options. That matters beyond tidiness: keying a
# for_each on an attribute of a certificate that does not exist yet leaves the map keys
# unknown at plan time, which is fine on a first apply and fails on any targeted plan or
# import.
resource "aws_route53_record" "gateway_validation" {
  zone_id         = data.aws_route53_zone.lab.zone_id
  name            = one(aws_acm_certificate.gateway.domain_validation_options).resource_record_name
  type            = one(aws_acm_certificate.gateway.domain_validation_options).resource_record_type
  records         = [one(aws_acm_certificate.gateway.domain_validation_options).resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "gateway" {
  certificate_arn         = aws_acm_certificate.gateway.arn
  validation_record_fqdns = [aws_route53_record.gateway_validation.fqdn]
}

# ---------------------------------------------------------------------------
# The Enterprise UI
# ---------------------------------------------------------------------------

resource "aws_acm_certificate" "ui" {
  domain_name       = local.ui_fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# One domain per certificate and no SANs, so this is a single record rather than a
# for_each over domain_validation_options. That matters beyond tidiness: keying a
# for_each on an attribute of a certificate that does not exist yet leaves the map keys
# unknown at plan time, which is fine on a first apply and fails on any targeted plan or
# import.
resource "aws_route53_record" "ui_validation" {
  zone_id         = data.aws_route53_zone.lab.zone_id
  name            = one(aws_acm_certificate.ui.domain_validation_options).resource_record_name
  type            = one(aws_acm_certificate.ui.domain_validation_options).resource_record_type
  records         = [one(aws_acm_certificate.ui.domain_validation_options).resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "ui" {
  certificate_arn         = aws_acm_certificate.ui.arn
  validation_record_fqdns = [aws_route53_record.ui_validation.fqdn]
}

# ---------------------------------------------------------------------------
# The names themselves, pointed at whatever ELB the Services produced
# ---------------------------------------------------------------------------
#
# CNAME rather than an alias record: the in-tree AWS cloud provider creates a classic
# ELB and reports only its DNS name, and an alias needs the zone id of the load
# balancer, which the Service status does not carry.

resource "aws_route53_record" "gateway" {
  zone_id = data.aws_route53_zone.lab.zone_id
  name    = local.gateway_fqdn
  type    = "CNAME"
  ttl     = 60
  records = [kubernetes_service.gateway_public.status[0].load_balancer[0].ingress[0].hostname]
}

resource "aws_route53_record" "ui" {
  zone_id = data.aws_route53_zone.lab.zone_id
  name    = local.ui_fqdn
  type    = "CNAME"
  ttl     = 60
  records = [kubernetes_service.ui_public.status[0].load_balancer[0].ingress[0].hostname]
}
