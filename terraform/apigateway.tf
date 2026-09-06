# The HTTP API, integration, route, stage, custom domain, and API mapping
# below were all originally created by hand in the console (Sept 2, 2026 -
# see the project doc) because API Gateway's custom-domain + ACM flow is
# easiest to click through the first time. This file brings those same
# real resources under Terraform management via `terraform import` - it
# does NOT create new ones. Every argument here is written to match what
# already exists exactly, so `terraform plan` comes back clean (0 to add,
# 0 to change, 0 to destroy) once the imports are done. If a plan ever
# shows a change here unexpectedly, stop and read it carefully before
# applying - some of these resources (aws_lambda_permission's statement_id
# in particular) force replacement rather than updating in place, and a
# replacement of the domain name or API would cause real downtime.
#
# DNS is NOT managed here. api.amberdeneal.dev's DNS lives entirely in
# Cloudflare (see the project doc for why) - Terraform only reads the
# existing ACM certificate as a data source and wires up the AWS-side
# pieces that certificate and CNAME point at.

data "aws_acm_certificate" "api" {
  domain      = var.api_custom_domain_name
  statuses    = ["ISSUED"]
  most_recent = true
}

resource "aws_apigatewayv2_api" "this" {
  name          = var.http_api_name
  protocol_type = "HTTP"

  tags = {
    Name = "${local.name_prefix}-http-api"
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id = aws_apigatewayv2_api.this.id

  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_function.api.arn
  payload_format_version = "2.0"
  connection_type        = "INTERNET"
  timeout_milliseconds   = 30000
}

resource "aws_apigatewayv2_route" "any" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "ANY /"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true
}

# Lets API Gateway invoke the Lambda function. statement_id is pinned to
# the console-generated UUID that already exists (from `aws lambda
# get-policy`) rather than a friendly name - statement_id forces
# replacement on change, and replacing it would briefly break invocation,
# so importing it as-is avoids that entirely.
resource "aws_lambda_permission" "apigw" {
  statement_id  = "a74f23d7-a6fc-57f2-b9fd-a3180ce71d2e"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*/"
}

resource "aws_apigatewayv2_domain_name" "api" {
  domain_name = var.api_custom_domain_name

  domain_name_configuration {
    certificate_arn = data.aws_acm_certificate.api.arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_api_mapping" "api" {
  api_id      = aws_apigatewayv2_api.this.id
  domain_name = aws_apigatewayv2_domain_name.api.id
  stage       = aws_apigatewayv2_stage.default.id
}
