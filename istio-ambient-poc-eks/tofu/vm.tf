# The "VM" for the enrolment scenario: an EC2 instance in cluster A's VPC with
# Docker (ztunnel runs as a container) and a tiny HTTP app on :8080. Reached
# with SSM Session Manager only: no SSH port, no key pair, no public listener.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_iam_policy_document" "vm_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vm" {
  name               = "istio-ambient-poc-vm"
  assume_role_policy = data.aws_iam_policy_document.vm_assume.json
}

resource "aws_iam_role_policy_attachment" "vm_ssm" {
  role       = aws_iam_role.vm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "vm" {
  name = "istio-ambient-poc-vm"
  role = aws_iam_role.vm.name
}

resource "aws_security_group" "vm" {
  name        = "istio-ambient-poc-vm"
  description = "mesh VM: HBONE in from both cluster VPCs, plain app port for the before/after comparison"
  vpc_id      = module.vpc[local.cluster_names[0]].vpc_id

  ingress {
    description = "HBONE from mesh pods (double-HBONE to the VM gateway)"
    from_port   = 15008
    to_port     = 15008
    protocol    = "tcp"
    cidr_blocks = local.all_cidrs
  }
  ingress {
    description = "the app itself, plaintext, so the lab can show the before state"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = local.all_cidrs
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "vm" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.vm_instance_type
  subnet_id                   = module.vpc[local.cluster_names[0]].public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.vm.id]
  iam_instance_profile        = aws_iam_instance_profile.vm.name
  associate_public_ip_address = true

  user_data = <<-EOT
    #!/bin/bash
    set -eux
    hostnamectl set-hostname mesh-vm
    dnf install -y docker python3 jq
    systemctl enable --now docker
    mkdir -p /etc/ztunnel/tokens /opt/vmapp
    # the workload that will be enrolled: answers with its hostname and the peer that called it
    cat > /opt/vmapp/app.py <<'PY'
    import http.server, socketserver, json, socket
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            b = json.dumps({"app": "vm-app", "host": socket.gethostname(),
                            "peer": self.client_address[0]}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
        def log_message(self, *a): pass
    socketserver.TCPServer.allow_reuse_address = True
    socketserver.ThreadingTCPServer(("0.0.0.0", 8080), H).serve_forever()
    PY
    cat > /etc/systemd/system/vmapp.service <<'UNIT'
    [Unit]
    Description=vm-app (mesh enrolment lab)
    After=network.target
    [Service]
    ExecStart=/usr/bin/python3 /opt/vmapp/app.py
    Restart=always
    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl enable --now vmapp
  EOT

  tags = { Name = "mesh-vm" }
}
