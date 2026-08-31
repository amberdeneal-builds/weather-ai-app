locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = "weather-ai"
    Environment = var.environment
    ManagedBy   = "terraform"
    Repo        = "weather-ai-app"
  }
}
