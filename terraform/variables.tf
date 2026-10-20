variable "aws_region" {
  type    = string
  default = "us-east-1"
}
variable "project_name" {
  type    = string
  default = "devops-microservice"
}
variable "environment" {
  type    = string
  default = "dev"
}
variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}
variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.1.0/24", "10.20.2.0/24"]
}
variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.11.0/24", "10.20.12.0/24"]
}
variable "desired_count" {
  type    = number
  default = 2
}
variable "container_cpu" {
  type    = number
  default = 256
}
variable "container_memory" {
  type    = number
  default = 512
}
variable "image_tag" {
  type    = string
  default = "bootstrap"
}
variable "log_retention_days" {
  type    = number
  default = 30
}
variable "alarm_email" {
  type    = string
  default = ""
}
variable "tags" {
  type    = map(string)
  default = {}
}
locals {
  name = "${var.project_name}-${var.environment}"
}
