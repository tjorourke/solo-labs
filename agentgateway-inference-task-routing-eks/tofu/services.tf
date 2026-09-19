# The two public Services.
#
# Everything the lab itself creates is ClusterIP and reached through a port-forward,
# which is deliberate: the endpoint holds a provider key, and yaml/platform/05-gateway.yaml
# pins the Gateway's own Service to ClusterIP for that reason. These two are the
# exception, and they exist so a real client can be pointed at the gateway. Cursor sends
# its chat completions from Cursor's backend rather than from the laptop, so a port-forward
# cannot serve it, and neither can a self-signed certificate.
#
# TLS terminates on the ELB with an ACM certificate and the backend protocol is plain
# HTTP inside the VPC, so neither the Gateway nor the UI needs a certificate of its own.

# ---------------------------------------------------------------------------
# The model endpoint: the intake listener, the first of the two hops
# ---------------------------------------------------------------------------
#
# Both hops are listeners on model-gateway now, so the selector is the same either way and
# the port is what decides. 8080 is the intake listener, which normalises the request: the
# model name the client sent becomes the one the router answers to, and the tool shapes the
# backends reject are filtered out. Pointing this at 80 skips that and gets an editor a 400
# on its first prompt, naming a model nobody here serves.

resource "kubernetes_service" "gateway_public" {
  metadata {
    name      = "model-gateway-public"
    namespace = var.namespace

    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-backend-protocol" = "http"
      "service.beta.kubernetes.io/aws-load-balancer-ssl-ports"        = "443"
      "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"         = aws_acm_certificate_validation.gateway.certificate_arn

      # Agent clients hold a streaming response open while a model thinks. The ELB
      # default is 60s, which drops a long completion mid-stream and reaches the client
      # as a truncated answer rather than as an error.
      "service.beta.kubernetes.io/aws-load-balancer-connection-idle-timeout" = "300"
    }
  }

  spec {
    type                        = "LoadBalancer"
    load_balancer_source_ranges = var.gateway_allowed_cidrs

    selector = {
      "gateway.networking.k8s.io/gateway-name" = "model-gateway"
    }

    port {
      name        = "https"
      port        = 443
      target_port = 8080
      protocol    = "TCP"
    }
  }

  wait_for_load_balancer = true
}

# ---------------------------------------------------------------------------
# The Enterprise UI
# ---------------------------------------------------------------------------
#
# 8090 is the backend container's HTTP port, the same one the in-cluster Service maps
# its port 80 to. The UI also listens on 8091 for gRPC and 5556 for its IdP; neither is
# published here.

resource "kubernetes_service" "ui_public" {
  metadata {
    name      = "solo-enterprise-ui-public"
    namespace = var.namespace

    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-backend-protocol" = "http"
      "service.beta.kubernetes.io/aws-load-balancer-ssl-ports"        = "443"
      "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"         = aws_acm_certificate_validation.ui.certificate_arn
    }
  }

  spec {
    type = "LoadBalancer"

    # The whole of the access control on this endpoint. See ui_allowed_cidrs.
    load_balancer_source_ranges = var.ui_allowed_cidrs

    selector = {
      app = "solo-enterprise-ui"
    }

    port {
      name        = "https"
      port        = 443
      target_port = 8090
      protocol    = "TCP"
    }
  }

  wait_for_load_balancer = true
}
