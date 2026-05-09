variable "ssh_user" {
  description = "OS user that Ansible will SSH as."
  type        = string
  default     = "ubuntu"
}

variable "ssh_private_key_path" {
  description = "Path to the default private key."
  type        = string
}

variable "run_ansible_playbook" {
  description = "Whether or not to run the ansible playbook. If creating infrastructure for first time, CI/CD must run first."
  type        = bool
  default     = true
}

variable "mc_server_motd" {
  description = "The Minecraft server MOTD"
  type        = string
}

variable "key_pair" {
  description = "The AWS Keypair used to authenticate with EC2 Instance"
  type        = string
}
