variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for main"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  type    = string
  default = "us-east-1a"
}

variable "log_group" {
  type = string
  default = "log-group"
}