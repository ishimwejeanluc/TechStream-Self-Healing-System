module "network" {
  source = "../modules/network"

  name         = local.name
  vpc_id       = data.aws_vpc.default.id
  allowed_cidr = var.allowed_cidr
  app_port     = var.app_port
}

module "compute" {
  source = "../modules/compute"

  name               = local.name
  ami_id             = data.aws_ami.ubuntu_2404.id
  instance_type      = var.instance_type
  subnet_id          = local.subnet_id
  security_group_ids = [module.network.security_group_id]
  # Prefer the generated key pair. Falls back to var.key_name when
  # create_key_pair is false, and to null when neither is set, in which case
  # access is via SSM Session Manager only.
  key_name         = var.create_key_pair ? aws_key_pair.instance[0].key_name : var.key_name
  root_volume_size = var.root_volume_size
  app_dir          = local.app_dir
}

module "remediation" {
  source = "../modules/remediation"

  name       = local.name
  region     = var.region
  account_id = data.aws_caller_identity.current.account_id

  instance_id  = module.compute.instance_id
  instance_arn = module.compute.instance_arn
  app_dir      = local.app_dir

  webhook_token      = var.remediation_webhook_token
  expected_alertname = "HighErrorRate"
  log_retention_days = var.log_retention_days

  enable_scale_out    = var.enable_scale_out
  asg_name            = var.asg_name
  scale_out_increment = var.scale_out_increment

  enable_eventbridge_audit = var.enable_eventbridge_audit
  event_bus_name           = var.event_bus_name
}
