# Step 1: Terraform infrastructure

Directory: `infra/stack/` plus `infra/modules/`

## Layout

Everything Terraform lives under `infra/`. The two root modules are separate
directories because they hold separate state.

```
infra/
├── bootstrap/            root module, LOCAL state, creates the state bucket (Step 0)
├── stack/                root module, S3 remote state, composes the modules
└── modules/
    ├── network/          security group and its rules
    ├── compute/          IAM instance profile, EC2 instance, user_data
    └── remediation/      SSM document, Lambda, Function URL, least-privilege IAM
```

`infra/stack/main.tf` is short on purpose. It wires three modules together and
nothing else. Each module owns one concern and declares its own
`required_providers` without a `provider` block, which is the rule for reusable
modules.

## The stack composes three modules

```hcl
module "network" {
  source       = "../modules/network"
  name         = local.name
  vpc_id       = data.aws_vpc.default.id
  allowed_cidr = var.allowed_cidr
  app_port     = var.app_port
}

module "compute" {
  source             = "../modules/compute"
  ami_id             = data.aws_ami.ubuntu_2404.id
  security_group_ids = [module.network.security_group_id]
  ...
}

module "remediation" {
  source       = "../modules/remediation"
  instance_id  = module.compute.instance_id
  instance_arn = module.compute.instance_arn
  ...
}
```

The dependency chain is explicit through those outputs: network produces a
security group ID, compute consumes it and produces an instance ID and ARN,
remediation consumes those to scope its IAM policy.

## Data sources instead of hardcoded IDs

No VPC or AMI IDs are written into the config.

```hcl
data "aws_ami" "ubuntu_2404" {
  most_recent = true
  owners      = ["099720109477"]   # Canonical's published AWS account

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  ...
}
```

Subnet selection is sorted so a re-plan never proposes moving the instance:

```hcl
subnet_id = sort(data.aws_subnets.default.ids)[0]
```

Without `sort`, the API can return subnet IDs in a different order between runs
and Terraform would want to replace the instance.

## Network module

One security group, and one ingress rule per port generated with `for_each`:

| Port | Purpose |
|---|---|
| 22 | SSH from Termius |
| 8080 | Flask app and `/metrics` |
| 3000 | Grafana UI |
| 9090 | Prometheus UI and HTTP API, which `rca.py` queries |
| 9093 | Alertmanager UI |

Every one is scoped to `var.allowed_cidr`. Two validations enforce that:

```hcl
validation {
  condition     = can(cidrhost(var.allowed_cidr, 0))
  error_message = "allowed_cidr must be valid CIDR notation, for example 41.186.176.42/32."
}

validation {
  condition     = var.allowed_cidr != "0.0.0.0/0"
  error_message = "Refusing 0.0.0.0/0. These ports expose unauthenticated dashboards."
}
```

The second one matters. Prometheus and Alertmanager have no login at all. A
wide-open rule would publish them, and would publish Alertmanager's ability to
send test webhooks to the remediation Lambda.

Egress is open to `0.0.0.0/0` so the instance can pull Docker images, install
packages and reach the SSM endpoints. This is a deliberate exception, recorded
in the code with a `# trivy:ignore:AVD-AWS-0104` comment and a note that fixing
it properly needs interface VPC endpoints for `ssm`, `ssmmessages` and
`ec2messages` plus a NAT or proxy.

## Compute module

The instance role carries exactly one managed policy:

```hcl
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
```

That is what registers the box as an SSM managed instance, which is the
precondition for the Lambda's `SendCommand` reaching it. Without it the whole
remediation path silently fails.

Instance hardening:

```hcl
metadata_options {
  http_endpoint = "enabled"
  http_tokens   = "required"    # IMDSv2 only
}

root_block_device {
  volume_type = "gp3"
  encrypted   = true
}
```

`http_tokens = "required"` matters more than usual here. The app deliberately
accepts attacker-shaped input on its chaos endpoints, and IMDSv1 would leave a
server-side request forgery path straight to the instance credentials.

`user_data` installs Docker from Docker's own apt repo, so we get the compose v2
plugin rather than the older standalone `docker-compose`. It makes sure the SSM
agent snap is running, creates `/opt/techstream`, and writes
`/opt/techstream/.user-data-complete` as a marker the verification step reads.

`user_data_replace_on_change = true` means editing that script replaces the
instance rather than leaving a box that silently never ran the new version.

## Remediation module

This is where the least-privilege work is.

### A custom SSM document, not AWS-RunShellScript

```hcl
resource "aws_ssm_document" "restart_app" {
  name          = "${var.name}-restart-app"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2"
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "restartApp"
      inputs = {
        timeoutSeconds = "300"
        runCommand = [
          "set -euxo pipefail",
          "cd ${var.app_dir}/monitoring",
          "docker compose restart ${var.compose_service}",
          "docker compose ps ${var.compose_service}",
        ]
      }
    }]
  })
}
```

The document hardcodes the one command the Lambda is allowed to cause. The
final `docker compose ps` line puts the result in the SSM command output, so the
runbook can show the restart actually happened.

### The IAM policy that makes it least privilege

```hcl
statement {
  sid     = "SendRestartCommandToThisInstanceOnly"
  effect  = "Allow"
  actions = ["ssm:SendCommand"]

  resources = [
    aws_ssm_document.restart_app.arn,
    var.instance_arn,
  ]
}
```

`ssm:SendCommand` authorizes against both the document and the target instance,
so naming both confines the Lambda to that one script on that one box.

This is the mistake to avoid: granting `SendCommand` on `AWS-RunShellScript`
would let the Lambda run any shell command as root on any instance in the
account. Scoping to a custom document removes that entirely.

Log permissions are scoped to the one log group we create, rather than `*`:

```hcl
statement {
  sid       = "WriteOwnLogs"
  actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
  resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
}
```

Creating the log group in Terraform rather than letting Lambda create it lets us
both set retention and scope the policy to it.

The scale-out and EventBridge permissions only appear when their feature flags
are on, using `dynamic "statement"` blocks. When `enable_scale_out = false`, the
Lambda has no autoscaling permissions whatsoever.

### The Lambda

Python 3.12, `boto3` from the runtime so there is no dependency build. The
`archive` provider zips the source at plan time and `source_code_hash` triggers
redeploy when the code changes.

Key handler behaviour:

- Validates the `?token=` shared secret with `hmac.compare_digest`
- Filters **per alert** on `alert["status"] == "firing"`, not the batch's
  top-level `status`. A batch can read `firing` while an individual alert inside
  it has already resolved.
- Only acts on `alertname == HighErrorRate`
- Logs the SSM command ID, returns 200

## The security tradeoff you need to know about

```hcl
resource "aws_lambda_function_url" "remediator" {
  authorization_type = "NONE"
}
```

Alertmanager cannot sign SigV4 requests, so IAM auth on the Function URL is not
an option. The `?token=` shared secret checked inside the handler is therefore
the **only** gate on remediation. Anyone who learns the URL and the token can
restart the instance at will.

Consequences:

- The token lives in `terraform.tfvars`, which is gitignored
- Generate it with `openssl rand -hex 32`
- Rotate by changing the variable and re-applying
- Do not paste the Function URL into anything shared

Restart throttling is also worth calling out honestly. `_last_action_at` in the
handler is a module-level variable, so it only survives while the execution
environment stays warm. It reduces restart storms, it does not prevent them.
Alertmanager's `repeat_interval` is the real guard, set in Step 5.

## Scale-out alternative

Off by default, behind `enable_scale_out`. When true, the Lambda calls
`autoscaling:SetDesiredCapacity` instead of restarting.

The tradeoff:

- **Restart** is the right move for a bad process. It clears the fault in
  seconds. This is the failure the lab injects, so it is the default.
- **Scale-out** only helps when the cause is genuine saturation. It does nothing
  for a process returning 500s on every request, because the new instance runs
  the same broken code and you now have two of them.

Choosing restart for an application fault and scale-out for saturation is the
distinction the RCA in Step 6 is built to make.

## Note on the assignment mapping

The original brief reached the Lambda through a CloudWatch Alarm plus an
EventBridge rule. Alerting now lives in Prometheus, because Prometheus is what
sees the application-level 500s. The Alertmanager webhook replaces the Alarm and
EventBridge hop.

Lambda and SSM are unchanged. If EventBridge is required, set
`enable_eventbridge_audit = true` and the Lambda publishes a custom event
**after** remediating, for audit only, off the critical path.

## How to verify it works

```bash
cd infra/stack
cp terraform.tfvars.example terraform.tfvars   # then edit allowed_cidr and the token
terraform init      # initialises the S3 backend from Step 0
terraform plan
terraform apply

# 1. The instance registered with SSM. This is the precondition for remediation.
#    If the instance is missing here, nothing downstream will work.
aws ssm describe-instance-information \
  --query "InstanceInformationList[].{Id:InstanceId,Ping:PingStatus,Version:AgentVersion}"

# 2. user_data finished
aws ssm start-session --target "$(terraform output -raw instance_id)"
cat /opt/techstream/.user-data-complete
docker --version && docker compose version

# 3. The Lambda policy rendered with both ARNs. plan cannot show this,
#    because it interpolates the instance and log group ARNs.
aws iam get-role-policy \
  --role-name techstream-remediator-role \
  --policy-name techstream-remediator-policy

# 4. The SSM document holds the expected command
aws ssm get-document --name "$(terraform output -raw ssm_document_name)" \
  --query Content --output text

# 5. Collect the URLs
terraform output
```

## Verification results

| Check | Result |
|---|---|
| `terraform fmt -recursive -check` | clean |
| `terraform validate` (stack and 3 modules) | Success |
| `terraform plan` | 17 to add, 0 to change, 0 to destroy |
| `trivy config` | 0 misconfigurations |
| `python3 -m py_compile handler.py` | compiles |
| `bash -n user_data.sh` | parses |

`plan` resolved real data sources, which is what `validate` cannot do:

- AMI `ami-08c7a4b4f234dfa77` (Ubuntu 24.04 noble, gp3)
- VPC `vpc-05780c99ec8f5f79c`, subnet `subnet-00906dd09f012b5c7`
- `t3.medium`, `http_tokens = "required"`, root volume `gp3` and `encrypted`
- Exactly 5 ingress rules on `41.186.176.42/32`, and the only `0.0.0.0/0` is the
  egress rule
- The SSM document rendered its `runCommand` array correctly
- `archive_file` zipped the Lambda without error

Not applied yet. No AWS resources were created during this step.

### How the stack was planned before the backend existed

The backend bucket does not exist until Step 0 is applied, so a normal
`terraform init` in `infra/stack/` fails. To plan anyway, a temporary
`backend_override.tf` containing `backend "local" {}` was dropped in, using
Terraform's `*_override.tf` mechanism, then removed along with the local state
file afterwards.

`infra/stack/` is back to its committed form, so the first real command there
must be `terraform init`, which initialises the S3 backend properly.
