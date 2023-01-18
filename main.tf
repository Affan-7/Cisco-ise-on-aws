provider "aws" {
  region     = var.aws_region
  # access_key = var.aws_access_key
  # secret_key = var.aws_secret_key
}

variable "aws_region" {}
# variable "aws_access_key" {}
# variable "aws_secret_key" {}
variable "ise_password" {}
variable "ise_domain" {}
variable "on_prem_network" {}