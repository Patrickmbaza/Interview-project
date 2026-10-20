variable "name" { type = string }
variable "cluster_name" { type = string }
variable "service_name" { type = string }
variable "target_group_arn" { type = string }
variable "alarm_email" {
  type    = string
  default = ""
}
resource "aws_sns_topic" "alerts" {
  count = var.alarm_email == "" ? 0 : 1
  name  = "${var.name}-alerts"
}
resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}
resource "aws_cloudwatch_metric_alarm" "cpu" {
  alarm_name          = "${var.name}-high-cpu"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = var.cluster_name, ServiceName = var.service_name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = var.alarm_email == "" ? [] : [aws_sns_topic.alerts[0].arn]
}
resource "aws_cloudwatch_metric_alarm" "unhealthy" {
  alarm_name          = "${var.name}-unhealthy-targets"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { TargetGroup = element(split(":", var.target_group_arn), 5), LoadBalancer = "app/${var.name}-alb" }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_actions       = var.alarm_email == "" ? [] : [aws_sns_topic.alerts[0].arn]
}
