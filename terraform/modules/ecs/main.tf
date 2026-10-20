variable "name" { type = string }
variable "aws_region" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "private_subnet_ids" { type = list(string) }
variable "image_uri" { type = string }
variable "desired_count" { type = number }
variable "container_cpu" { type = number }
variable "container_memory" { type = number }
variable "log_retention_days" { type = number }

resource "aws_security_group" "alb" {
  name   = "${var.name}-alb"
  vpc_id = var.vpc_id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "tasks" {
  name   = "${var.name}-tasks"
  vpc_id = var.vpc_id
  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_lb" "this" {
  name               = substr("${var.name}-alb", 0, 32)
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids
}
resource "aws_lb_target_group" "this" {
  name        = substr("${var.name}-tg", 0, 32)
  port        = 8000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id
  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}
resource "aws_ecs_cluster" "this" {
  name = var.name
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}
resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days
}
data "aws_iam_policy_document" "task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "execution" {
  name               = "${var.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
}
resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
}
resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.container_cpu
  memory                   = var.container_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions = jsonencode([{
    name             = var.name
    image            = var.image_uri
    essential        = true
    portMappings     = [{ containerPort = 8000, hostPort = 8000, protocol = "tcp" }]
    environment      = [{ name = "APP_NAME", value = var.name }, { name = "ENVIRONMENT", value = "dev" }, { name = "PORT", value = "8000" }]
    logConfiguration = { logDriver = "awslogs", options = { "awslogs-group" = aws_cloudwatch_log_group.this.name, "awslogs-region" = var.aws_region, "awslogs-stream-prefix" = "ecs" } }
    healthCheck      = { command = ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health')\""], interval = 30, timeout = 5, retries = 3, startPeriod = 10 }
  }])
}
resource "aws_ecs_service" "this" {
  name                               = var.name
  cluster                            = aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.this.arn
  desired_count                      = var.desired_count
  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 30
  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = var.name
    container_port   = 8000
  }
  depends_on = [aws_lb_listener.http]
}
output "application_url" { value = "http://${aws_lb.this.dns_name}" }
output "cluster_name" { value = aws_ecs_cluster.this.name }
output "service_name" { value = aws_ecs_service.this.name }
output "target_group_arn" { value = aws_lb_target_group.this.arn }
output "log_group_name" { value = aws_cloudwatch_log_group.this.name }
