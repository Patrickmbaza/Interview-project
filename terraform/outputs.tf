output "application_url" { value = module.ecs.application_url }
output "ecr_repository_url" { value = module.ecr.repository_url }
output "ecs_cluster_name" { value = module.ecs.cluster_name }
output "ecs_service_name" { value = module.ecs.service_name }
output "cloudwatch_log_group" { value = module.ecs.log_group_name }
