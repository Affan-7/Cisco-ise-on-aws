# Create vpc with 10.0.0.0/16 CIDR block
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = {
    Name = "ISE-Demo"
  }
}

# Create Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

# Attach the exisiting vgw to the VPC
resource "aws_vpn_gateway_attachment" "vpn_attachment" {
  vpc_id         = aws_vpc.main.id
  vpn_gateway_id = "vgw-0ff2b6227f0c822c7"
}

# Create a custom route table
resource "aws_default_route_table" "route" {
  default_route_table_id = aws_vpc.main.default_route_table_id
  propagating_vgws       = ["vgw-0ff2b6227f0c822c7"]
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

# Create a Subnet1
resource "aws_subnet" "subnet-1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true
  tags = {
    Name = "subnet-1"
  }
}

# Create a Subnet2
resource "aws_subnet" "subnet-2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = true
  tags = {
    Name = "subnet-2"
  }
}

# Associate subnet with route table
resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.subnet-1.id
  route_table_id = aws_vpc.main.default_route_table_id
}
resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.subnet-2.id
  route_table_id = aws_vpc.main.default_route_table_id
}

# Create Security Group
resource "aws_security_group" "ise-demo" {
  name   = "ISE-Demo"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "Within VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
  ingress {
    description = "From on-premises"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["${var.on_prem_network}"]
  }
  ingress {
    description = "SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "ISE-Demo"
  }
}


# Create Load balancer
resource "aws_lb" "ise-lb" {
  name                             = "ise-lb"
  internal                         = true
  load_balancer_type               = "network"
  enable_cross_zone_load_balancing = true
  subnet_mapping {
    subnet_id            = aws_subnet.subnet-1.id
    private_ipv4_address = "10.0.1.4"
  }

  subnet_mapping {
    subnet_id            = aws_subnet.subnet-2.id
    private_ipv4_address = "10.0.2.4"
  }
}

# S3 as ISE repository
resource "aws_s3_bucket" "ise-repository" {
  bucket        = "ise-repository"
}

resource "aws_s3_bucket_acl" "ise-repository-s3-acl" {
  bucket = aws_s3_bucket.ise-repository.id
  acl    = "private"
}

#Transfer Family server
resource "aws_transfer_server" "ise-repository" {
  identity_provider_type = "SERVICE_MANAGED"
  endpoint_type          = "VPC"
  endpoint_details {
    subnet_ids         = [aws_subnet.subnet-1.id, aws_subnet.subnet-2.id]
    vpc_id             = aws_vpc.main.id
    security_group_ids = [aws_security_group.ise-demo.id]
  }
  protocols = ["SFTP"]
}

# Transfer Family user
resource "aws_iam_role" "sftp-access" {
  name               = "sftp-access"
  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
        "Effect": "Allow",
        "Principal": {
            "Service": "transfer.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
        }
    ]
}
EOF
}

resource "aws_iam_role_policy" "sftp-access-policy" {
  name   = "sftp-access-policy"
  role   = aws_iam_role.sftp-access.id
  policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowFullAccesstoS3",
            "Effect": "Allow",
            "Action": [
                "s3:*"
            ],
            "Resource": "*"
        }
    ]
}
POLICY
}

resource "aws_transfer_user" "sftp-user" {
  server_id = aws_transfer_server.ise-repository.id
  user_name = "sftp-user"
  role      = aws_iam_role.sftp-access.arn

  home_directory_type = "PATH"
  home_directory      = join("", ["/", aws_s3_bucket.ise-repository.bucket])
}

data "aws_ami" "cisco_ise" {
  most_recent      = true
  owners           = ["679593333241"] # AWS marketplace
    filter {
      name   = "name"
      values = ["Cisco Identity Services Engine*"]
  }
}

variable "pan-zone-a" {
  default = 1   # Number of PPAN/PMNT in zone-a
}

# Create PPAN/PMNT in zone-a
module "ise-zone-a" {
  count           = var.pan-zone-a
  source          = "./ise"
  subnet_id       = aws_subnet.subnet-1.id
  security_groups = aws_security_group.ise-demo.id
  ami             = data.aws_ami.cisco_ise.id
  volume_size     = "1200"
  instance_type   = "m5.4xlarge"
  key_name        = "ssh-key"
  hostname        = "ise${(count.index + 1)}"
  user_data       = "ise${(count.index + 1)}.txt"
  forward_zone    = "Z05698913VLHUT470MQK5"
  reverse_zone    = "Z05939853HVUGGVVBF2UG"
  domain_name     = var.ise_domain
}

variable "pan-zone-b" {
  default = 1   # Number of PPAN/PMNT in zone-b
}

# Create SPAN/SMNT in zone-b
module "ise-zone-b" {
  count           = var.pan-zone-b
  source          = "./ise"
  subnet_id       = aws_subnet.subnet-2.id
  security_groups = aws_security_group.ise-demo.id
  ami             = data.aws_ami.cisco_ise.id
  volume_size     = "1200"
  instance_type   = "m5.4xlarge"
  key_name        = "ssh-key"
  hostname        = "ise${(count.index + 1) + var.pan-zone-a}"
  user_data       = "ise${(count.index + 1) + var.pan-zone-a}.txt"
  forward_zone    = "Z05698913VLHUT470MQK5"
  reverse_zone    = "Z05939853HVUGGVVBF2UG"
  domain_name     = var.ise_domain
}

variable "psn-zone-a" {
  default = 2   # Number of psn in zone-a
}

# Create 2 PSNs in zone-a
module "psn-zone-a" {
  count                 = var.psn-zone-a
  source                = "./ise-lb"
  subnet_id             = aws_subnet.subnet-1.id
  security_groups       = aws_security_group.ise-demo.id
  ami                   = data.aws_ami.cisco_ise.id
  volume_size           = "600"
  instance_type         = "c5.4xlarge"
  key_name              = "ssh-key"
  hostname              = "ise${(count.index + 1) + var.pan-zone-a + var.pan-zone-b}-psn"
  user_data             = "ise${(count.index + 1) + var.pan-zone-a + var.pan-zone-b}.txt"
  forward_zone          = "Z05698913VLHUT470MQK5"
  reverse_zone          = "Z05939853HVUGGVVBF2UG"
  domain_name           = var.ise_domain
  target_group_arn-1812 = aws_lb_target_group.radius-1812.arn
  target_group_arn-1813 = aws_lb_target_group.radius-1813.arn
  target_group_arn-49   = aws_lb_target_group.tacacs-49.arn
}

variable "psn-zone-b" {
  default = 2   # Number of psn in zone-b
}

# Create 2 PSNs in zone-b
module "psn-zone-b" {
  count                 = var.psn-zone-b
  source                = "./ise-lb"
  subnet_id             = aws_subnet.subnet-2.id
  security_groups       = aws_security_group.ise-demo.id
  ami                   = data.aws_ami.cisco_ise.id
  volume_size           = "600"
  instance_type         = "c5.4xlarge"
  key_name              = "ssh-key"
  hostname              = "ise${(count.index + 1) + var.pan-zone-a + var.pan-zone-b + var.psn-zone-a}-psn"
  user_data             = "ise${(count.index + 1) + var.pan-zone-a + var.pan-zone-b + var.psn-zone-a}.txt"
  forward_zone          = "Z05698913VLHUT470MQK5"
  reverse_zone          = "Z05939853HVUGGVVBF2UG"
  domain_name           = var.ise_domain
  target_group_arn-1812 = aws_lb_target_group.radius-1812.arn
  target_group_arn-1813 = aws_lb_target_group.radius-1813.arn
  target_group_arn-49   = aws_lb_target_group.tacacs-49.arn
}


# Route53 DNS Records for forward and reverse zone
resource "aws_route53_zone_association" "authc" {
  zone_id = "Z05698913VLHUT470MQK5"
  vpc_id  = aws_vpc.main.id
}

resource "aws_route53_zone_association" "reverse" {
  zone_id = "Z05939853HVUGGVVBF2UG"
  vpc_id  = aws_vpc.main.id
}


# Create Target Group
resource "aws_lb_target_group" "radius-1812" {
  name                 = "radius-1812"
  port                 = 1812
  protocol             = "UDP"
  target_type          = "ip"
  deregistration_delay = 60
  stickiness {
    enabled = "true"
    type    = "source_ip"
  }
  health_check {
    enabled  = "true"
    port     = 443
    protocol = "TCP"
  }
  vpc_id = aws_vpc.main.id
}
resource "aws_lb_target_group" "radius-1813" {
  name                 = "radius-1813"
  port                 = 1813
  protocol             = "UDP"
  target_type          = "ip"
  deregistration_delay = 60
  stickiness {
    enabled = "true"
    type    = "source_ip"
  }
  health_check {
    enabled  = "true"
    port     = 443
    protocol = "TCP"
  }
  vpc_id = aws_vpc.main.id
}
resource "aws_lb_target_group" "tacacs-49" {
  name                 = "tacacs-49"
  port                 = 49
  protocol             = "TCP"
  target_type          = "ip"
  deregistration_delay = 60

  stickiness {
    enabled = "true"
    type    = "source_ip"
  }
  health_check {
    enabled  = "true"
    port     = 49
    protocol = "TCP"
  }
  vpc_id = aws_vpc.main.id
}

# Create LB listener
resource "aws_lb_listener" "radius-1812" {
  load_balancer_arn = aws_lb.ise-lb.arn
  port              = "1812"
  protocol          = "UDP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.radius-1812.arn
  }
}
resource "aws_lb_listener" "radius-1813" {
  load_balancer_arn = aws_lb.ise-lb.arn
  port              = "1813"
  protocol          = "UDP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.radius-1813.arn
  }
}
resource "aws_lb_listener" "radius-1645" {
  load_balancer_arn = aws_lb.ise-lb.arn
  port              = "1645"
  protocol          = "UDP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.radius-1812.arn
  }
}
resource "aws_lb_listener" "radius-1646" {
  load_balancer_arn = aws_lb.ise-lb.arn
  port              = "1646"
  protocol          = "UDP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.radius-1813.arn
  }
}
resource "aws_lb_listener" "tacacs-49" {
  load_balancer_arn = aws_lb.ise-lb.arn
  port              = "49"
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tacacs-49.arn
  }
}


# Print IP addresses of ISE instances
output "ise1-ppan_pmnt" {
  value = "https://${module.ise-zone-a[0].nic.private_ip}"
}
output "ise2-span_smnt" {
  value = "https://${module.ise-zone-b[0].nic.private_ip}"
}
output "ise3-psn" {
  value = "https://${module.psn-zone-a[0].nic.private_ip}"
}
output "ise4-psn" {
  value = "https://${module.psn-zone-b[0].nic.private_ip}"
}
output "ise5-psn" {
  value = "https://${module.psn-zone-a[1].nic.private_ip}"
}
output "ise6-psn" {
  value = "https://${module.psn-zone-b[1].nic.private_ip}"
}