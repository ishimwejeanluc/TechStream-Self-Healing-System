# Generates an SSH key pair, registers the public half with EC2, and writes the
# private half to the repo root with 0600 permissions.
#
# SECURITY: the private key is stored in Terraform state, in plaintext. The state
# bucket has encryption and public access blocked, but anyone who can read the
# state can read this key. That is unavoidable when Terraform generates the key.
# For anything beyond a lab, create the key outside Terraform with ssh-keygen or
# use EC2 Instance Connect, and pass only key_name in.
#
# The instance also has SSM Session Manager, which needs no key at all:
#   aws ssm start-session --target $(terraform output -raw instance_id)
# That remains the more secure way in, and it works even if this key is lost.

resource "tls_private_key" "instance" {
  count = var.create_key_pair ? 1 : 0

  # RSA 4096 rather than ED25519 for the widest client compatibility, including
  # older SSH clients and GUI tools like Termius.
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "instance" {
  count = var.create_key_pair ? 1 : 0

  key_name   = "${local.name}-key"
  public_key = tls_private_key.instance[0].public_key_openssh

  tags = {
    Name = "${local.name}-key"
  }
}

# local_sensitive_file, not local_file: it keeps the key out of plan and apply
# output. local_file would print the whole private key to the terminal.
resource "local_sensitive_file" "private_key" {
  count = var.create_key_pair ? 1 : 0

  content  = tls_private_key.instance[0].private_key_pem
  filename = "${path.module}/../../${var.private_key_dir}/${var.private_key_filename}"

  # 0600 on the key: owner read and write only.
  file_permission = "0600"
  # 0700 on the directory it creates: owner only, so the key cannot even be
  # listed by another user on the machine. The provider creates missing parent
  # directories, so the folder does not need to exist beforehand.
  directory_permission = "0700"
}
