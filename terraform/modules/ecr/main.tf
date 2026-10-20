variable "name" {
  type = string
}
resource "aws_ecr_repository" "this" {
  name                 = var.name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false
  image_scanning_configuration {
    scan_on_push = true
  }
}
resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep newest 20 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}
output "repository_url" {
  value = aws_ecr_repository.this.repository_url
}
