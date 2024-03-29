terraform {
    required_version = ">= 1.0"
}

# Bring up ISE interfaces
resource "aws_network_interface" "nic" {
  subnet_id       = var.subnet_id
  security_groups = [var.security_groups]
}

#Bring up ISE instance
resource "aws_instance" "ise" {
  ami           = var.ami
  instance_type = var.instance_type
  key_name = var.key_name
  network_interface {
    network_interface_id = aws_network_interface.nic.id
    device_index         = 0
  }
  tags = {
    Name = "${var.hostname}"
  }
  ebs_block_device {
    volume_size = var.volume_size
    device_name = "/dev/sda1"
  }
  lifecycle {
    ignore_changes = [root_block_device,ebs_block_device]
  }
  user_data = "${file(var.user_data)}"
}

resource "aws_route53_record" "forward" {
  zone_id = var.forward_zone
  name    = var.hostname  # example ise1-psn.example.com
  type    = "A"
  ttl     = "300"
  records = [aws_network_interface.nic.private_ip]
}

resource "aws_route53_record" "reverse" {
  zone_id = var.reverse_zone
  name    = join(".", [element(split(".",aws_network_interface.nic.private_ip),3), element(split(".",aws_network_interface.nic.private_ip),2)])
  type    = "PTR"
  ttl     = "300"
  records = [join(".",["${var.hostname}","${var.domain_name}"])] # example ise1-psn.example.com
}

resource "aws_lb_target_group_attachment" "radius-1812" {
  target_group_arn = var.target_group_arn-1812
  target_id        = aws_network_interface.nic.private_ip
  port             = 1812
}
resource "aws_lb_target_group_attachment" "radius-1813" {
  target_group_arn = var.target_group_arn-1813
  target_id        = aws_network_interface.nic.private_ip
  port             = 1813
}
resource "aws_lb_target_group_attachment" "tacacs-49" {
  target_group_arn = var.target_group_arn-49
  target_id        = aws_network_interface.nic.private_ip
  port             = 49
}