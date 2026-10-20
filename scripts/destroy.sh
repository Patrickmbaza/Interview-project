#!/usr/bin/env bash
set -Eeuo pipefail

# Destroy application infrastructure created by Terraform.
# Backend and Jenkins data are preserved unless explicitly requested.

usage() {
    cat <<'EOF'
Usage:
  scripts/destroy.sh [options]

Options:
  --region REGION          AWS region (default: us-east-1)
  --var-file FILE          Terraform variable file, relative to terraform/
  --project-name NAME      Terraform project name (default: devops-microservice)
  --environment NAME       Terraform environment (default: dev)
  --include-backend        Delete the Terraform state bucket and lock table
  --state-bucket NAME      Required with --include-backend
  --lock-table NAME        Required with --include-backend
  --stop-jenkins           Stop the Jenkins container, preserving its volume
  --remove-jenkins-data    Stop Jenkins and remove its Docker volume
  --yes                    Skip the confirmation prompt
  -h, --help               Show this help

Examples:
  scripts/destroy.sh --var-file dev.tfvars
  scripts/destroy.sh --var-file dev.tfvars --stop-jenkins
  scripts/destroy.sh --include-backend \
    --state-bucket my-terraform-state-bucket \
    --lock-table devops-microservice-locks
EOF
}

REGION="us-east-1"
VAR_FILE=""
PROJECT_NAME="devops-microservice"
ENVIRONMENT="dev"
INCLUDE_BACKEND=false
STATE_BUCKET=""
LOCK_TABLE=""
STOP_JENKINS=false
REMOVE_JENKINS_DATA=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region) REGION="${2:?Missing value for --region}"; shift 2 ;;
        --var-file) VAR_FILE="${2:?Missing value for --var-file}"; shift 2 ;;
        --project-name) PROJECT_NAME="${2:?Missing value for --project-name}"; shift 2 ;;
        --environment) ENVIRONMENT="${2:?Missing value for --environment}"; shift 2 ;;
        --include-backend) INCLUDE_BACKEND=true; shift ;;
        --state-bucket) STATE_BUCKET="${2:?Missing value for --state-bucket}"; shift 2 ;;
        --lock-table) LOCK_TABLE="${2:?Missing value for --lock-table}"; shift 2 ;;
        --stop-jenkins) STOP_JENKINS=true; shift ;;
        --remove-jenkins-data) REMOVE_JENKINS_DATA=true; STOP_JENKINS=true; shift ;;
        --yes) ASSUME_YES=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERRAFORM_DIR="$ROOT_DIR/terraform"
JENKINS_COMPOSE="$ROOT_DIR/jenkins/docker-compose.yml"
REPOSITORY_NAME="${PROJECT_NAME}-${ENVIRONMENT}"

need_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required command: $1" >&2
        exit 1
    }
}

need_command aws
need_command terraform
need_command python3

if [[ "$STOP_JENKINS" == true ]]; then
    need_command docker
fi

if [[ "$INCLUDE_BACKEND" == true && ( -z "$STATE_BUCKET" || -z "$LOCK_TABLE" ) ]]; then
    echo "--state-bucket and --lock-table are required with --include-backend." >&2
    exit 2
fi

echo "Checking AWS credentials and region: $REGION"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "Authenticated AWS account: $ACCOUNT_ID"

echo
echo "This destructive operation will remove:"
echo "  Terraform application resources: $REPOSITORY_NAME"
[[ "$STOP_JENKINS" == true ]] && echo "  Jenkins container: yes"
[[ "$REMOVE_JENKINS_DATA" == true ]] && echo "  Jenkins Docker volume/data: yes"
[[ "$INCLUDE_BACKEND" == true ]] && echo "  Terraform state bucket and lock table: yes"
[[ "$INCLUDE_BACKEND" == false ]] && echo "  Terraform state bucket and lock table: no"

if [[ "$ASSUME_YES" == false ]]; then
    read -r -p "Type DESTROY to continue: " confirmation
    [[ "$confirmation" == "DESTROY" ]] || { echo "Cancelled."; exit 0; }
fi

echo "Removing ECR images so the immutable repository can be destroyed..."
if aws ecr describe-repositories --repository-names "$REPOSITORY_NAME" --region "$REGION" >/dev/null 2>&1; then
    while IFS= read -r digest; do
        [[ -n "$digest" ]] || continue
        aws ecr batch-delete-image \
            --repository-name "$REPOSITORY_NAME" \
            --image-ids "imageDigest=$digest" \
            --region "$REGION" >/dev/null
    done < <(aws ecr list-images \
        --repository-name "$REPOSITORY_NAME" \
        --filter tagStatus=ANY \
        --query 'imageIds[?imageDigest!=null].imageDigest' \
        --output text \
        --region "$REGION" | tr '\t' '\n')
fi

destroy_args=(-auto-approve -input=false -var="aws_region=$REGION")
if [[ -n "$VAR_FILE" ]]; then
    destroy_args+=("-var-file=$VAR_FILE")
fi

echo "Destroying Terraform application infrastructure..."
terraform -chdir="$TERRAFORM_DIR" destroy "${destroy_args[@]}"

if [[ "$STOP_JENKINS" == true ]]; then
    [[ -f "$JENKINS_COMPOSE" ]] || {
        echo "Jenkins Compose file not found: $JENKINS_COMPOSE" >&2
        exit 1
    }
    if [[ "$REMOVE_JENKINS_DATA" == true ]]; then
        docker compose -f "$JENKINS_COMPOSE" down -v
    else
        docker compose -f "$JENKINS_COMPOSE" down
    fi
fi

if [[ "$INCLUDE_BACKEND" == true ]]; then
    echo "Deleting all versioned Terraform state objects..."
    for object_type in Versions DeleteMarkers; do
        while IFS=$'\t' read -r key version_id; do
            [[ -n "$key" && -n "$version_id" ]] || continue
            aws s3api delete-object \
                --bucket "$STATE_BUCKET" \
                --key "$key" \
                --version-id "$version_id" \
                --region "$REGION" >/dev/null
        done < <(aws s3api list-object-versions \
            --bucket "$STATE_BUCKET" \
            --query "${object_type}[].[Key,VersionId]" \
            --output text \
            --region "$REGION")
    done

    aws s3api delete-bucket --bucket "$STATE_BUCKET" --region "$REGION"
    aws dynamodb delete-table --table-name "$LOCK_TABLE" --region "$REGION" >/dev/null
    echo "Terraform backend resources deleted."
fi

echo "Destroy completed."
