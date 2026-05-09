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
  key_name = var.key_pair
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


resource "local_file" "ansible_inventory" {
  filename = "${path.module}/inventory.ini"

  content = <<-EOT
   [managed]
   ec2 ansible_host=${aws_instance.ops-3-instance.public_ip} ansible_user=${var.ssh_user}

   [managed:vars]
   ansible_ssh_private_key_file=${var.ssh_private_key_path}
   ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new'
   s3_bucket=${aws_s3_bucket.world_backups.id}
   mc_server_motd=${var.mc_server_motd}
   EOT

  depends_on = [aws_instance.ops-3-instance, aws_s3_bucket.world_backups]
}

resource "null_resource" "copy_inventory_to_ansible_dir" {
  triggers = {
    # This ensures the copy only happens when the content actually changes
    inventory_md5 = filemd5(local_file.ansible_inventory.filename)
  }

  provisioner "local-exec" {
    command     = "cp ${local_file.ansible_inventory.filename} ${path.module}/../ansible/inventory.ini"
    interpreter = ["sh", "-c"]
  }

  depends_on = [local_file.ansible_inventory]
}

resource "null_resource" "run_ansible" {
  count = var.run_ansible_playbook ? 1 : 0

  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<-EOC
         # Wait for SSH (max 180s)
         for i in $(seq 1 30); do
           nc -z -w5 ${aws_instance.ops-3-instance.public_ip} 22 && break
           echo "Waiting for SSH... ($i/30)"
           sleep 6
         done

         # Note: We now point to the copied inventory in the ansible dir
         ansible-playbook -i ${path.module}/../ansible/inventory.ini ${path.module}/../ansible/minecraft.yml
       EOC
  }

  # CRITICAL: This ensures the file is copied BEFORE ansible runs
  depends_on = [null_resource.copy_inventory_to_ansible_dir]
}

output "ansible_inventory_path" {
  value = local_file.ansible_inventory.filename
}

output "s3_bucket" {
  value = aws_s3_bucket.world_backups.id
}
