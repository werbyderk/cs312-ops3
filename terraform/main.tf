terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.41.0"
    }
  }
}

# -----------------------------------------------------------------
# AWS account information
# -----------------------------------------------------------------
data "aws_caller_identity" "current" {}

provider "aws" {
  region = "us-east-1"
}

/* -----------------------------------------------------------------
   INPUT VARIABLES
   ----------------------------------------------------------------- */
variable "ssh_user" {
  description = "OS user that Ansible will SSH as."
  type        = string
  default     = "ubuntu"
}

variable "ssh_private_key_path" {
  description = "Path to the private key."
  type        = string
  default     = "~/.ssh/cs312-key.pem"
}

/* -----------------------------------------------------------------
   VPC MODULE
   ----------------------------------------------------------------- */
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "ops-3"
  cidr = "10.0.0.0/16"

  azs            = ["us-east-1a"]
  public_subnets = ["10.0.1.0/24"]

  map_public_ip_on_launch = true
}

/* -----------------------------------------------------------------
   Security Group
   ----------------------------------------------------------------- */
resource "aws_security_group" "allow_web" {
  name        = "ops-3-web"
  description = "Ops 3 SG"
  vpc_id      = module.vpc.vpc_id

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

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "web-sg" }
}

/* -----------------------------------------------------------------
   Key‑pair & AMI
   ----------------------------------------------------------------- */
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

/* -----------------------------------------------------------------
   EC2 Instance
   ----------------------------------------------------------------- */
resource "aws_instance" "ops-3-instance" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.small" # Upgraded for Java 25 / 1.21+
  subnet_id                   = module.vpc.public_subnets[0]
  associate_public_ip_address = true
  key_name                    = data.aws_key_pair.ops3_key.key_name
  vpc_security_group_ids      = [aws_security_group.allow_web.id]
  iam_instance_profile        = "LabInstanceProfile"

  tags = {
    Name = "web-instance"
  }
}

/* -----------------------------------------------------------------
   ECR Repository
   ----------------------------------------------------------------- */
resource "aws_ecr_repository" "minecraft" {
  name                 = "minecraft-server"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

/* -----------------------------------------------------------------
   S3 bucket for Minecraft world backups
   ----------------------------------------------------------------- */
resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "world_backups" {
  bucket        = "ops-3-mc-backups-${random_id.suffix.hex}"
  force_destroy = true
  tags = {
    Name = "ops-3-mc-backups"
  }
}

resource "aws_s3_bucket_versioning" "world_backups" {
  bucket = aws_s3_bucket.world_backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "world_backups" {
  bucket                  = aws_s3_bucket.world_backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "world_backup_policy" {
  statement {
    sid    = "AllowBackupReadWrite"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/LabRole"]
    }

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket"
    ]

    resources = [
      "${aws_s3_bucket.world_backups.arn}",
      "${aws_s3_bucket.world_backups.arn}/*"
    ]
  }
}

resource "aws_s3_bucket_policy" "world_backups" {
  bucket = aws_s3_bucket.world_backups.id
  policy = data.aws_iam_policy_document.world_backup_policy.json
}

/* -----------------------------------------------------------------
   1️⃣ Write an Ansible inventory file
   ----------------------------------------------------------------- */
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/inventory.ini"

  content = <<-EOT
   [managed]
   ec2 ansible_host=${aws_instance.ops-3-instance.public_ip} ansible_user=${var.ssh_user}

   [managed:vars]
   ansible_ssh_private_key_file=${var.ssh_private_key_path}
   ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new'
   s3_bucket=${aws_s3_bucket.world_backups.id}
   EOT

  depends_on = [aws_instance.ops-3-instance, aws_s3_bucket.world_backups]
}

/* -----------------------------------------------------------------
   2️⃣ Null resource that runs the Ansible playbook
   ----------------------------------------------------------------- */
resource "null_resource" "run_ansible" {
  provisioner "local-exec" {
    command = <<-EOC
      # Wait for SSH (max 180s)
      for i in $(seq 1 30); do
        nc -z -w5 ${aws_instance.ops-3-instance.public_ip} 22 && break
        echo "Waiting for SSH... ($i/30)"
        sleep 6
      done

      ansible-playbook -i ${local_file.ansible_inventory.filename} ${path.module}/../ansible/minecraft.yml
    EOC

    environment = {
      ANSIBLE_HOST_KEY_CHECKING = "False"
    }
    interpreter = ["sh", "-c"]
  }

  triggers = {
    instance_id = aws_instance.ops-3-instance.id
    public_ip   = aws_instance.ops-3-instance.public_ip
    # Forces a rerun whenever anything in the playbook logic needs refreshing
    always_run = timestamp()
  }

  depends_on = [local_file.ansible_inventory]
}

output "ansible_inventory_path" {
  value = local_file.ansible_inventory.filename
}

output "s3_bucket" {
  value = aws_s3_bucket.world_backups.id
}
