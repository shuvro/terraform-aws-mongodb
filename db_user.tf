terraform {
  required_providers {
    mongodbatlas = {
      source = "mongodb/mongodbatlas"
      version = "0.9.0"
    }
  }
}
resource "random_password" "password" {
  length   = 14
  special  = false
  upper    = false
}

resource "aws_ssm_parameter" "db_password" {
  name        = "/infra/${var.app_name}/${var.environment}-db-password"
  description = "terraform_db_password"
  type        = "SecureString"
  value       = random_password.password.result
}

resource "aws_ssm_parameter" "db_username" {
  name        = "/infra/${var.app_name}/${var.environment}-db-username"
  description = "terraform_db_username"
  type        = "SecureString"
  value       = "${var.app_name}-${var.environment}-dbuser"
}

resource "aws_ssm_parameter" "db_name" {
  name        = "/infra/${var.app_name}/${var.environment}-db-name"
  description = "terraform_db_name"
  type        = "String"
  value       = "${var.app_name}-${var.environment}-db"
}

resource "mongodbatlas_database_user" "main" {
  username           = "${var.app_name}-${var.environment}-dbuser"
  password           = random_password.password.result
  project_id         = var.atlasprojectid
  auth_database_name = "admin"

  roles {
    role_name     = "readWrite"
    database_name = "${var.app_name}-${var.environment}-db"
  }
}
