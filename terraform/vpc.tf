# VPC for the API layer. Private-subnet-only by design: the Lambda function
# behind API Gateway never needs a public IP or inbound internet path, and
# every AWS service it talks to (DynamoDB, KMS, Secrets Manager, CloudWatch
# Logs, Bedrock) is reachable through a VPC endpoint. That means no NAT
# Gateway (a real recurring cost) and no route to 0.0.0.0/0 at all.

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # No map_public_ip_on_launch — these subnets are private on purpose.

  tags = {
    Name = "${local.name_prefix}-private-${var.availability_zones[count.index]}"
    Tier = "api-private"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- VPC endpoints -----------------------------------------------------
# Gateway endpoint (free, no hourly charge): DynamoDB.
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "${local.name_prefix}-vpce-dynamodb"
  }
}

# Interface endpoints (hourly + per-GB cost) — gated behind a variable so
# the network layer can be stood up at zero cost when just validating the
# topology. KMS, Secrets Manager, and CloudWatch Logs are the services the
# Lambda role actually calls; Bedrock Runtime is included so model calls
# never leave the VPC either.
locals {
  interface_endpoint_services = var.enable_interface_endpoints ? {
    kms             = "kms"
    secretsmanager  = "secretsmanager"
    logs            = "logs"
    bedrock_runtime = "bedrock-runtime"
  } : {}
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = local.interface_endpoint_services
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${local.name_prefix}-vpce-${each.key}"
  }
}

# --- Security groups (stateful) -----------------------------------------

# Attached to the Lambda function itself. No ingress (Lambda is never a
# connection target); egress limited to HTTPS, and only to the VPC endpoint
# ENIs / DynamoDB prefix list — never 0.0.0.0/0.
resource "aws_security_group" "lambda" {
  name        = "${local.name_prefix}-lambda-sg"
  description = "Weather AI Lambda: HTTPS egress to VPC endpoints only, no ingress"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-lambda-sg"
  }
}

resource "aws_security_group_rule" "lambda_egress_to_interface_endpoints" {
  type                     = "egress"
  security_group_id        = aws_security_group.lambda.id
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.vpc_endpoints.id
  description               = "HTTPS to interface VPC endpoints (KMS, Secrets Manager, Logs, Bedrock)"
}

resource "aws_security_group_rule" "lambda_egress_to_dynamodb_gateway" {
  type              = "egress"
  security_group_id = aws_security_group.lambda.id
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  prefix_list_ids   = [aws_vpc_endpoint.dynamodb.prefix_list_id]
  description       = "HTTPS to the DynamoDB gateway endpoint"
}

# Attached to the interface VPC endpoint ENIs. Only accepts HTTPS from the
# Lambda security group — nothing else in the VPC (or outside it) can reach
# these endpoints.
resource "aws_security_group" "vpc_endpoints" {
  name        = "${local.name_prefix}-vpce-sg"
  description = "Weather AI VPC interface endpoints: HTTPS ingress from the Lambda SG only"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-vpce-sg"
  }
}

resource "aws_security_group_rule" "vpc_endpoints_ingress_from_lambda" {
  type                     = "ingress"
  security_group_id        = aws_security_group.vpc_endpoints.id
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.lambda.id
  description               = "HTTPS from the Lambda SG"
}

resource "aws_security_group_rule" "vpc_endpoints_egress_all" {
  # Interface endpoint ENIs answer over the same established TCP connection;
  # a same-VPC-only egress rule keeps this from ever meaning "the internet".
  type              = "egress"
  security_group_id = aws_security_group.vpc_endpoints.id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = [var.vpc_cidr]
  description       = "Return traffic within the VPC only"
}

# --- Network ACL (stateless, subnet-level) -------------------------------
# Belt-and-suspenders under the security groups above: even if a security
# group were ever misconfigured, the private subnets themselves only permit
# HTTPS + ephemeral-port return traffic within the VPC CIDR. Nothing routes
# to 0.0.0.0/0 from these subnets in the first place (no NAT/IGW route), but
# the NACL makes that explicit rather than incidental.

resource "aws_network_acl" "private" {
  vpc_id     = aws_vpc.this.id
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${local.name_prefix}-private-nacl"
  }
}

resource "aws_network_acl_rule" "private_in_https" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 100
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = 443
  to_port        = 443
}

resource "aws_network_acl_rule" "private_in_ephemeral" {
  # Return traffic for connections *this subnet* initiated outbound on 443.
  network_acl_id = aws_network_acl.private.id
  rule_number    = 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "private_out_https" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 100
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = 443
  to_port        = 443
}

resource "aws_network_acl_rule" "private_out_ephemeral" {
  # Response traffic back to a caller that reached this subnet on 443
  # (e.g. an interface endpoint answering the Lambda function).
  network_acl_id = aws_network_acl.private.id
  rule_number    = 110
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = 1024
  to_port        = 65535
}
