# The GCP service account key weather-ai-api uses as its Vertex AI failover
# credential, if/when a Bedrock call fails. Encrypted with the same CMK
# built in kms.tf; readable by the Lambda role via the existing
# "ReadOwnSecretsOnly" statement in iam.tf (no IAM change needed - this
# secret's name falls under the weather-ai/ prefix that statement already
# scopes to).
#
# The key file itself (gcp_vertex_key_path) lives outside this repo and is
# never committed - Terraform reads its contents directly into the secret
# value, so the file only ever needs to exist on whichever machine runs
# `terraform apply`. sensitive() keeps the actual JSON out of plan/apply
# console output (the aws_secretsmanager_secret_version resource doesn't
# redact secret_string on its own).

resource "aws_secretsmanager_secret" "gcp_vertex_failover_key" {
  name        = "${var.secrets_name_prefix}gcp-vertex-failover-key"
  description = "GCP service account key JSON (weather-ai-vertex-failover@${var.gcp_project_id}.iam.gserviceaccount.com) used by weather-ai-api to call Vertex AI when Bedrock is unavailable."
  kms_key_id  = aws_kms_key.secrets.arn

  tags = {
    Name = "${local.name_prefix}-gcp-vertex-failover-key"
  }
}

resource "aws_secretsmanager_secret_version" "gcp_vertex_failover_key" {
  secret_id     = aws_secretsmanager_secret.gcp_vertex_failover_key.id
  secret_string = sensitive(file(pathexpand(var.gcp_vertex_key_path)))
}
