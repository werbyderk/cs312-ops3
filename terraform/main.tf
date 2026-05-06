terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.41.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "ops-3"
  cidr = "10.0.0.0/16"

  azs            = ["us-east-1a"]
  public_subnets = ["10.0.1.0/24"]

  map_public_ip_on_launch = true
}

resource "aws_security_group" "allow_web" {
  name        = "ops-3-web"
  description = "Ops 3 SG"
  vpc_id      = module.vpc.vpc_id

  # Inbound Rules (Ingress)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Minecraft"
    from_port   = 25565
    to_port     = 25565
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound Rules (Egress)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # "-1" means all protocols
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "web-sg" }
}

data "aws_key_pair" "ops3_key" {
  key_name = "cs312-key"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_instance" "ops-3-instance" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = module.vpc.public_subnets[0]
  associate_public_ip_address = true
  key_name                    = data.aws_key_pair.ops3_key.key_name
  vpc_security_group_ids      = [aws_security_group.allow_web.id]
  iam_instance_profile        = aws_iam_instance_profile.lab.name

  tags = {
    Name = "web-instance"
  }
}

resource "aws_ecr_repository" "minecraft" {
  name                 = "minecraft-server"
  image_tag_mutability = "MUTABLE" # Allows re-tagging if needed
  force_delete         = true      # Helpful for clean 'terraform destroy'

  image_scanning_configuration {
    scan_on_push = true
  }
}
