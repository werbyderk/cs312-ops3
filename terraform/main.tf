terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.41.0"
    }
  }

  # -----------------------------------------------------------------
  # OPTIONAL – Remote state backend (extra‑credit #3)
  # -----------------------------------------------------------------
  # backend "s3" {
  #   bucket         = "ops-3-tfstate"
  #   key            = "terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "ops-3-locks"
  #   encrypt        = true
  # }
}

# -----------------------------------------------------------------
# AWS account information (needed for the bucket policy)
# -----------------------------------------------------------------
data "aws_caller_identity" "current" {}

provider "aws" {
  region = "us-east-1"
}

/* -----------------------------------------------------------------
   INPUT VARIABLES – make the Terraform run reusable for any user
   ----------------------------------------------------------------- */
variable "ssh_user" {
  description = "OS user that Ansible will SSH as (default is ubuntu for the official Ubuntu AMI)."
  type        = string
  default     = "ubuntu"
}

variable "ssh_private_key_path" {
  description = "Absolute path on the machine running `terraform apply` to the private key that matches the EC2 key pair."
  type        = string
  default     = "~/.ssh/cs312-key.pem"
}

/* -----------------------------------------------------------------
   VPC MODULE (unchanged)
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
   Security Group (unchanged)
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
   Key‑pair & AMI (unchanged)
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
   EC2 Instance – add a `connection` block (optional)
   ----------------------------------------------------------------- */
resource "aws_instance" "ops-3-instance" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.small"
  subnet_id                   = module.vpc.public_subnets[0]
  associate_public_ip_address = true
  key_name                    = data.aws_key_pair.ops3_key.key_name
  vpc_security_group_ids      = [aws_security_group.allow_web.id]
  iam_instance_profile        = "LabInstanceProfile"

  tags = {
    Name = "web-instance"
  }

  # This block is only used by Terraform‑native provisioners.
  # It is *not* required for the Ansible provisioner below,
  # but keeping it makes the config future‑proof.
  connection {
    type        = "ssh"
    host        = self.public_ip
    user        = var.ssh_user
    private_key = file(var.ssh_private_key_path)
    timeout     = "2m"
  }
}

/* -----------------------------------------------------------------
   ECR Repository (unchanged)
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
   1️⃣ Write an Ansible inventory file that points at the new host
   ----------------------------------------------------------------- */
resource "local_file" "ansible_inventory" {
  # The file will be written to the same directory where you run `terraform`
  filename = "${path.module}/inventory.ini"

  # NOTE: we use the *public* IP because the instance is in a public subnet.
  # If you move to a private subnet behind a load‑balancer, replace
  # `public_ip` with `private_ip`.
  content = <<-EOT
[minecraft]
${aws_instance.ops-3-instance.public_ip} ansible_user=${var.ssh_user} ansible_ssh_private_key_file=${var.ssh_private_key_path}
EOT

  # Force recreation if the IP changes (e.g., after a `terraform destroy`/`apply`)
  depends_on = [aws_instance.ops-3-instance]
}

/* -----------------------------------------------------------------
   2️⃣ Null resource that runs the Ansible playbook
   ----------------------------------------------------------------- */
resource "null_resource" "run_ansible" {
  # The provisioner must wait until the instance is reachable via SSH.
  # A simple `sleep` + retry loop is enough for a demo; for production
  # you could use the `remote-exec` provisioner or a `null_resource`
  # with a `triggers` map that watches the instance ID.
  provisioner "local-exec" {
    command = <<-EOC
      # Wait for SSH to become available (max 180 s)
      for i in $(seq 1 30); do
        nc -z -w5 ${aws_instance.ops-3-instance.public_ip} 22 && break
        echo "Waiting for SSH... ($i/30)"
        sleep 6
      done

      # Run the Ansible playbook
      ansible-playbook -i ${local_file.ansible_inventory.filename} ${path.module}/../ansible/minecraft.yml
    EOC

    # Pass the environment variables that Ansible may need (optional)
    environment = {
      ANSIBLE_HOST_KEY_CHECKING = "False"
    }

    # Only run when the instance ID changes (i.e., on a fresh apply)
    # This prevents the playbook from re‑running on every `terraform plan`.
    interpreter = ["sh", "-c"]
  }

  # Trigger on any change to the instance (new ID or new public IP)
  triggers = {
    instance_id = aws_instance.ops-3-instance.id
    public_ip   = aws_instance.ops-3-instance.public_ip
  }

  # Ensure the inventory file exists before we try to run Ansible
  depends_on = [local_file.ansible_inventory]
}

/* -----------------------------------------------------------------
   3️⃣ OPTIONAL – expose the inventory path as an output (handy for CI)
   ----------------------------------------------------------------- */
output "ansible_inventory_path" {
  description = "Path to the generated inventory file."
  value       = local_file.ansible_inventory.filename
}


# -----------------------------------------------------------------
# S3 bucket for Minecraft world backups
# -----------------------------------------------------------------
resource "aws_s3_bucket" "world_backups" {
  bucket = "ops-3-mc-backups-${random_id.suffix.hex}"
  # The bucket name must be globally unique, so we tack on a short random suffix.
  force_destroy = true # Allows `terraform destroy` to delete the bucket even if objects exist.
  tags = {
    Name = "ops-3-mc-backups"
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

/* Enable versioning so a broken restore can be rolled back */
resource "aws_s3_bucket_versioning" "world_backups" {
  bucket = aws_s3_bucket.world_backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

/* Block all public access – the bucket is only reachable via IAM role */
resource "aws_s3_bucket_public_access_block" "world_backups" {
  bucket                  = aws_s3_bucket.world_backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

/* Grant the LabInstanceProfile / LabRole permission to read/write the bucket */
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
   OPTIONAL – Remote‑state backend (extra credit #3)
   ----------------------------------------------------------------- */
# resource "aws_s3_bucket" "tfstate" {
#   bucket = "ops-3-tfstate-${random_id.suffix.hex}"
#   force_destroy = true
#   tags = { Name = "ops-3-tfstate" }
# }
#
# resource "aws_dynamodb_table" "tfstate_lock" {
#   name         = "ops-3-locks"
#   billing_mode = "PAY_PER_REQUEST"
#   hash_key     = "LockID"
#
#   attribute {
#     name = "LockID"
#     type = "S"
#   }
#
#   tags = { Name = "ops-3-locks" }
# }
