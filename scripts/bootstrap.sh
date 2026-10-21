#!/usr/bin/env bash
set -Eeuo pipefail

# Bootstrap host prerequisites, Terraform backend, and local Jenkins.
# This script does not deploy the application, destroy resources, or store secrets.

usage() {
    cat <<'EOF'
Usage:
  scripts/bootstrap.sh [options]

Options:
  --region REGION          AWS region (default: us-east-1)
  --state-bucket NAME      Terraform state bucket (required unless --skip-backend)
  --lock-table NAME        DynamoDB lock table (default: devops-microservice-locks)
  --skip-backend           Do not create/configure the Terraform state backend
  --skip-jenkins           Do not start Jenkins with Docker Compose
  --skip-tool-install       Only check host tools; do not install missing packages
  --yes                    Skip the confirmation prompt for AWS backend creation
  -h, --help               Show this help

Examples:
  scripts/bootstrap.sh --region us-east-1 --state-bucket my-unique-tf-state-bucket
  scripts/bootstrap.sh --skip-backend --skip-jenkins
EOF
}

REGION="us-east-1"
STATE_BUCKET=""
LOCK_TABLE="devops-microservice-locks"
SKIP_BACKEND=false
SKIP_JENKINS=false
SKIP_TOOL_INSTALL=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region)
            REGION="${2:?Missing value for --region}"
            shift 2
            ;;
        --state-bucket)
            STATE_BUCKET="${2:?Missing value for --state-bucket}"
            shift 2
            ;;
        --lock-table)
            LOCK_TABLE="${2:?Missing value for --lock-table}"
            shift 2
            ;;
        --skip-backend)
            SKIP_BACKEND=true
            shift
            ;;
        --skip-jenkins)
            SKIP_JENKINS=true
            shift
            ;;
        --skip-tool-install)
            SKIP_TOOL_INSTALL=true
            shift
            ;;
        --yes)
            ASSUME_YES=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERRAFORM_DIR="$ROOT_DIR/terraform"
BACKEND_FILE="$TERRAFORM_DIR/backend.tf"
JENKINS_COMPOSE="$ROOT_DIR/jenkins/docker-compose.yml"

need_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required command: $1" >&2
        exit 1
    }
}

install_host_tools() {
    if [[ "$SKIP_TOOL_INSTALL" == true ]]; then
        return
    fi

    if command -v docker >/dev/null 2>&1 && \
       docker compose version >/dev/null 2>&1 && \
       command -v terraform >/dev/null 2>&1 && \
       command -v aws >/dev/null 2>&1 && \
       command -v python3 >/dev/null 2>&1 && \
       command -v curl >/dev/null 2>&1; then
        echo "All required host tools are already installed."
        return
    fi

    if [[ ! -f /etc/os-release ]]; then
        echo "Cannot identify Linux distribution. Install Docker Compose, Terraform, AWS CLI v2, Python 3, and curl manually." >&2
        exit 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]]; then
        echo "Automatic installation supports Ubuntu and Debian only (detected: ${ID:-unknown}). Install Docker Compose, Terraform, AWS CLI v2, Python 3, and curl manually." >&2
        exit 1
    fi

    local apt_cmd=(apt-get)
    if [[ "$(id -u)" -ne 0 ]]; then
        command -v sudo >/dev/null 2>&1 || {
            echo "Run as root or install sudo to install host tools." >&2
            exit 1
        }
        apt_cmd=(sudo apt-get)
    fi

    echo "Installing host prerequisites on ${PRETTY_NAME:-$ID}..."
    "${apt_cmd[@]}" update
    "${apt_cmd[@]}" install -y ca-certificates curl gnupg python3 python3-venv unzip

    if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
        "${apt_cmd[@]}" install -y docker.io docker-compose-v2
        if command -v systemctl >/dev/null 2>&1; then
            if [[ "$(id -u)" -eq 0 ]]; then
                systemctl enable --now docker
            else
                sudo systemctl enable --now docker
            fi
        fi
    fi

    if ! command -v terraform >/dev/null 2>&1; then
        local keyring=/usr/share/keyrings/hashicorp-archive-keyring.gpg
        local source_list=/etc/apt/sources.list.d/hashicorp.list
        if [[ "$(id -u)" -eq 0 ]]; then
            curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o "$keyring"
            printf 'deb [signed-by=%s] https://apt.releases.hashicorp.com %s main\n' "$keyring" "$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")" > "$source_list"
        else
            curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee "$keyring" >/dev/null
            printf 'deb [signed-by=%s] https://apt.releases.hashicorp.com %s main\n' "$keyring" "$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")" | sudo tee "$source_list" >/dev/null
        fi
        "${apt_cmd[@]}" update
        "${apt_cmd[@]}" install -y terraform
    fi

    if ! command -v aws >/dev/null 2>&1; then
        local install_dir
        if [[ "$(id -u)" -eq 0 ]]; then
            install_dir=/usr/local
        else
            install_dir=/usr/local
        fi
        local aws_zip
        aws_zip="$(mktemp /tmp/awscliv2.XXXXXX.zip)"
        curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o "$aws_zip"
        local aws_extract
        aws_extract="$(mktemp -d /tmp/awscliv2.XXXXXX)"
        unzip -q "$aws_zip" -d "$aws_extract"
        if [[ "$(id -u)" -eq 0 ]]; then
            "$aws_extract/aws/install" --install-dir "$install_dir/aws-cli" --bin-dir /usr/local/bin
        else
            sudo "$aws_extract/aws/install" --install-dir "$install_dir/aws-cli" --bin-dir /usr/local/bin
        fi
        rm -rf "$aws_zip" "$aws_extract"
    fi
}

install_host_tools

echo "Checking host prerequisites..."
need_command aws
need_command terraform
need_command docker
need_command curl
need_command python3
docker compose version >/dev/null 2>&1 || {
    echo "Docker Compose plugin is unavailable. Install the Docker Compose plugin and rerun." >&2
    exit 1
}

if [[ "$SKIP_BACKEND" == false && -z "$STATE_BUCKET" ]]; then
    echo "--state-bucket is required unless --skip-backend is used." >&2
    exit 2
fi

echo "Checking AWS credentials and region: $REGION"
AWS_IDENTITY="$(aws sts get-caller-identity --output json)"
ACCOUNT_ID="$(printf '%s' "$AWS_IDENTITY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Account"])')"
echo "Authenticated AWS account: $ACCOUNT_ID"

if [[ "$SKIP_BACKEND" == false ]]; then
    if [[ "$ASSUME_YES" == false ]]; then
        echo
        echo "This will create or configure the Terraform state resources:"
        echo "  S3 bucket:       $STATE_BUCKET"
        echo "  DynamoDB table:  $LOCK_TABLE"
        echo "  AWS region:      $REGION"
        read -r -p "Continue? [y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
    fi

    echo "Creating/configuring Terraform state bucket..."
    if ! aws s3api head-bucket --bucket "$STATE_BUCKET" --region "$REGION" >/dev/null 2>&1; then
        if [[ "$REGION" == "us-east-1" ]]; then
            aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$REGION" >/dev/null
        else
            aws s3api create-bucket \
                --bucket "$STATE_BUCKET" \
                --region "$REGION" \
                --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
        fi
    fi

    aws s3api put-bucket-versioning \
        --bucket "$STATE_BUCKET" \
        --versioning-configuration Status=Enabled
    aws s3api put-bucket-encryption \
        --bucket "$STATE_BUCKET" \
        --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
    aws s3api put-public-access-block \
        --bucket "$STATE_BUCKET" \
        --public-access-block-configuration \
        BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

    echo "Creating/configuring Terraform lock table..."
    if ! aws dynamodb describe-table --table-name "$LOCK_TABLE" --region "$REGION" >/dev/null 2>&1; then
        aws dynamodb create-table \
            --table-name "$LOCK_TABLE" \
            --attribute-definitions AttributeName=LockID,AttributeType=S \
            --key-schema AttributeName=LockID,KeyType=HASH \
            --billing-mode PAY_PER_REQUEST \
            --region "$REGION" >/dev/null
        aws dynamodb wait table-exists --table-name "$LOCK_TABLE" --region "$REGION"
    fi

    echo "Writing local Terraform backend configuration: $BACKEND_FILE"
    cat > "$BACKEND_FILE" <<EOF
terraform {
  backend "s3" {
    bucket         = "$STATE_BUCKET"
    key            = "devops-microservice/dev/terraform.tfstate"
    region         = "$REGION"
    dynamodb_table = "$LOCK_TABLE"
    encrypt        = true
  }
}
EOF
    echo "Terraform backend configured. backend.tf remains ignored by Git."
fi

if [[ "$SKIP_JENKINS" == false ]]; then
    [[ -f "$JENKINS_COMPOSE" ]] || {
        echo "Jenkins Compose file not found: $JENKINS_COMPOSE" >&2
        exit 1
    }

    echo "Starting Jenkins..."
    DOCKER_GID=999
    if [[ -S /var/run/docker.sock ]]; then
        DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)"
    fi
    export DOCKER_GID
    if docker info >/dev/null 2>&1; then
        docker compose -f "$JENKINS_COMPOSE" up -d --build --force-recreate
    else
        sudo env DOCKER_GID="$DOCKER_GID" \
            docker compose -f "$JENKINS_COMPOSE" up -d --build --force-recreate
    fi
    echo "Jenkins container started. The initial setup password can be retrieved with:"
    echo "  docker exec devops-jenkins cat /var/jenkins_home/secrets/initialAdminPassword"
fi

echo
echo "Bootstrap completed."
echo "Next steps:"
echo "  1. Configure Jenkins credential ID 'aws-deploy' without committing secrets."
echo "  2. Create a Jenkins Pipeline job pointing to Jenkinsfile."
echo "  3. Configure the GitHub webhook: <JENKINS_URL>/github-webhook/"
echo "  4. Push a commit to GitHub and confirm Jenkins starts automatically."
echo "  5. Review the Terraform plan before the first application deployment."
