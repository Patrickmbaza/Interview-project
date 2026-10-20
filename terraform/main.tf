module "networking" {
  source               = "./modules/networking"
  name                 = local.name
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
}
module "ecr" {
  source = "./modules/ecr"
  name   = local.name
}
module "ecs" {
  source             = "./modules/ecs"
  name               = local.name
  aws_region         = var.aws_region
  vpc_id             = module.networking.vpc_id
  public_subnet_ids  = module.networking.public_subnet_ids
  private_subnet_ids = module.networking.private_subnet_ids
  image_uri          = "${module.ecr.repository_url}:${var.image_tag}"
  desired_count      = var.desired_count
  container_cpu      = var.container_cpu
  container_memory   = var.container_memory
  log_retention_days = var.log_retention_days
}
module "monitoring" {
  source           = "./modules/monitoring"
  name             = local.name
  cluster_name     = module.ecs.cluster_name
  service_name     = module.ecs.service_name
  target_group_arn = module.ecs.target_group_arn
  alarm_email      = var.alarm_email
}
