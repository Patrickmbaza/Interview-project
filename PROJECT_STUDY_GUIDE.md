# Project Study Guide: FastAPI, Jenkins, Terraform, and AWS ECS

This guide explains the project from a developer push through a live AWS deployment. It describes what each major file does, how the pieces interact, why the design choices were made, how to operate the service, and which limitations are useful to discuss in an interview.

## 1. Project at a glance

The project deploys a small Python FastAPI service as a Docker container on Amazon ECS Fargate. Jenkins runs the delivery pipeline. Terraform provisions the AWS infrastructure. Amazon ECR stores the built image, an Application Load Balancer (ALB) receives public HTTP traffic, and CloudWatch stores container logs and evaluates alarms.

```text
Developer pushes to GitHub
          |
          | GitHub webhook
          v
Jenkins server and pipeline
  checkout -> validate -> test -> build -> scan
          |                            |
          | Terraform                  | Docker image
          v                            v
   AWS infrastructure              Amazon ECR
      |                                  |
      +---- VPC, ALB, ECS, IAM, <---------+
                    CloudWatch
          |
          v
  ALB /health verification
```

The Jenkins server is separate from the ECS application environment. The application tasks run in private subnets without public IP addresses. Users reach the service through the ALB.

## 2. Repository map

| Path | Responsibility |
|---|---|
| `app/main.py` | FastAPI application and HTTP routes |
| `tests/test_api.py` | Basic function-level tests for the routes |
| `requirements.txt` | Runtime Python dependencies installed in the app image |
| `requirements-dev.txt` | CI/test/lint dependencies |
| `Dockerfile` | Builds the production application image |
| `docker-compose.yml` | Runs the application locally |
| `Jenkinsfile` | Pipeline definition for validation through deployment |
| `jenkins/Dockerfile` | Builds Jenkins with tools the pipeline needs |
| `jenkins/docker-compose.yml` | Runs Jenkins and mounts the host Docker socket |
| `terraform/main.tf` | Connects the reusable Terraform modules |
| `terraform/modules/networking/` | VPC, subnets, gateways, and routes |
| `terraform/modules/ecr/` | Container registry and lifecycle policy |
| `terraform/modules/ecs/` | ALB, ECS, security groups, IAM roles, and logs |
| `terraform/modules/monitoring/` | CloudWatch alarms and optional SNS email alerts |
| `terraform/backend.tf.example` | Template for the remote Terraform state backend |
| `scripts/bootstrap.sh` | Installs host prerequisites, prepares state backend, starts Jenkins |
| `scripts/destroy.sh` | Removes application resources, with explicit optional cleanup scopes |
| `scripts/verify.sh` | Small command-line health-check helper |
| `screenshots/` | Jenkins, ECS, ALB, and CloudWatch deployment evidence |

Terraform's `.terraform.lock.hcl` should be committed: it records the provider selection. Generated `.terraform/` contents, state files, local backend settings, credentials, caches, and virtual environments should not be committed.

## 3. The application

`app/main.py` creates the FastAPI application and reads these environment variables:

- `APP_NAME`: displayed service name; default `devops-microservice`.
- `APP_VERSION`: displayed version; default `1.0.0`.
- `ENVIRONMENT`: environment label; default `development`.
- `PORT`: listening port, default `8000` in the container command.

Routes:

| Method and path | Purpose |
|---|---|
| `GET /health` | Returns a simple healthy status and service/environment labels |
| `GET /` | Returns name, version, and environment information |
| `GET /api/v1/message` | Returns a sample JSON message and version |
| `GET /docs` | FastAPI's interactive OpenAPI documentation |

The health endpoint is used at three levels: Docker's image health check, the ECS task health check, and the ALB target group health check. These checks have different roles: Docker/ECS check the container process from inside the task, while the ALB checks whether it can reach the task over the network.

The tests call route functions directly. They confirm basic responses, but they are not full HTTP integration tests. A next testing improvement would use FastAPI's `TestClient` to issue requests through the ASGI application and assert response status codes and JSON payloads.

## 4. Containerization

The application `Dockerfile` uses `python:3.12-slim` as its base. It installs only runtime dependencies, copies the `app/` package, and starts Uvicorn on `0.0.0.0` so traffic can reach the process from outside the container.

Notable choices:

- A system user with UID `10001` runs the app instead of root.
- `PYTHONDONTWRITEBYTECODE` avoids Python bytecode files in the image.
- `PYTHONUNBUFFERED` makes logs appear promptly in container output.
- The image includes a `/health` check.
- `--no-cache-dir` avoids keeping pip's download cache in an image layer.
- The app port is `8000`; the Dockerfile exposes it and ECS maps it to the target group.

The root `docker-compose.yml` is for local application development. It builds the application image, publishes host port 8000, and labels the environment as `local`. It is not the production deployment mechanism; Terraform and ECS handle that.

The Jenkins image is different from the application image. `jenkins/Dockerfile` installs Python, Docker CLI, Terraform, Trivy, and AWS CLI inside Jenkins. Docker Engine and Docker Compose run on the Linux host, and the Docker socket is mounted into Jenkins so pipeline commands can build images using the host daemon.

## 5. CI/CD pipeline, stage by stage

The pipeline is declared in `Jenkinsfile`. A GitHub push trigger is declared with `githubPush()`. Jenkins must also have the relevant GitHub integration configured, and the repository webhook must point to Jenkins.

### Checkout

Jenkins checks out the configured SCM revision and runs `git rev-parse HEAD`. That commit ID becomes `GIT_SHA` and the Docker `IMAGE_TAG`. A unique immutable tag ties the deployed image back to its source revision.

### Install CI dependencies

The pipeline creates an isolated `.venv-ci`, upgrades pip, and installs `requirements-dev.txt`. Runtime packages are included through the requirements file reference. The virtual environment is removed in the pipeline's `post { always { ... } }` block, including after a failed build.

### Validate

- `compileall` checks Python files can be compiled.
- Ruff checks style and common static issues in `app` and `tests`.
- `terraform fmt -check -recursive` checks Terraform formatting without rewriting files.
- `terraform init -backend=false` initializes modules/providers for CI without connecting to the production state backend.
- `terraform validate` checks Terraform configuration structure and types.

This keeps ordinary code validation separate from AWS deployment credentials and backend state.

### Test

`pytest -q` runs the unit tests. A failing test stops later stages.

### Build

Docker builds the application image, pulls the base image with `--pull`, and tags the result with the commit SHA. The image is built on the Jenkins host's Docker daemon through the mounted Docker socket.

### Scan

Trivy scans the built image. `--severity HIGH,CRITICAL` selects findings at those severities; `--ignore-unfixed` excludes findings without a published fix; `--exit-code 1` makes qualifying findings fail the pipeline. Therefore, a passing scan is a policy result under these chosen filters, not a guarantee that the image has no vulnerabilities of any severity.

### Push

This stage is skipped for pull-request builds recognized by Jenkins' `changeRequest()` condition. It binds the Jenkins credential named `aws-deploy`, initializes the Terraform backend, and applies only `module.ecr` first. This targeted apply bootstraps the ECR repository before pushing the first image. The pipeline then obtains the ECR URL, logs in using `aws ecr get-login-password`, tags the image for ECR, and pushes it.

The ECR-only `-target` apply is an intentional first-deployment bootstrap technique. Terraform warns that targeted applies may leave other configuration unapplied; the following full deployment apply reconciles the complete configuration.

### Deploy

The pipeline performs a full Terraform apply with the selected AWS region and image tag. Terraform creates or updates networking, ECS, ALB, IAM, logging, and monitoring resources. `-auto-approve` is used because this is an automated pipeline; it means a production pipeline should have carefully scoped credentials, protected branches, and any required approval gates.

### Verify

Jenkins reads `application_url` from Terraform output and tries `GET /health` up to 30 times, sleeping 10 seconds between failures. This accommodates the time needed for tasks and ALB health checks to become ready. Terraform's ECS service resource does not itself wait for steady state; this pipeline uses the explicit HTTP retry loop as its deployment verification.

### Pull request behavior

The AWS push, deploy, and verify stages use `changeRequest()`. This condition is meaningful when Jenkins is configured as a multibranch pipeline that discovers pull requests. A basic single-branch Pipeline job may not set pull-request metadata, so configure a multibranch job if relying on this guard.

## 6. Terraform and infrastructure modules

The Terraform root module composes the child modules and passes their inputs/outputs between them. `variables.tf` exposes the region, naming, subnet CIDRs, task sizing, desired count, image tag, log retention, optional alarm email, and tags. `versions.tf` sets Terraform `>= 1.6.0`, uses AWS provider `~> 5.0`, and applies common tags.

### Networking module

The networking module provisions:

- A VPC using `10.20.0.0/16` by default, with DNS support and hostnames enabled.
- Two public subnets and two private subnets, distributed over available Availability Zones.
- An Internet Gateway and public route table with a default route to it.
- NAT gateways and Elastic IP addresses in public subnets.
- A private route table for outbound traffic from private subnets.

Important implementation detail: the module creates one NAT gateway for each public subnet, but it creates one shared private route table whose default route uses `aws_nat_gateway.this[0]`. Both private subnets associate with that route table. Thus, the second NAT gateway is provisioned but is not selected by the private subnet routes. This has cost implications and does not provide per-AZ NAT routing/failover. A stronger multi-AZ design would use one private route table per AZ and route each private subnet through its same-AZ NAT gateway; a lower-cost design could use one NAT gateway deliberately or VPC endpoints where suitable.

### ECR module

The ECR module creates the repository named from project and environment, enables image scanning on push, and makes image tags immutable. Its lifecycle policy retains the newest 20 images. `force_delete = false` prevents Terraform from deleting a repository while images remain, which is why `scripts/destroy.sh` deletes ECR images first.

### ECS module

The ECS module creates:

- An internet-facing ALB in the public subnets, accepting HTTP on port 80.
- An ALB target group that routes to IP targets on port 8000 and checks `/health`.
- An ECS cluster with Container Insights enabled.
- A CloudWatch log group with configurable retention (30 days by default).
- An ECS task definition for Fargate using `awsvpc` networking.
- A service with desired task count 2 by default, in the private subnets, with no public IPs.
- A task execution IAM role attached to `AmazonECSTaskExecutionRolePolicy` for image pulls and log delivery.
- A separate task role with no additional permissions configured.

The ALB security group allows inbound TCP 80 from anywhere. The task security group allows inbound TCP 8000 only from the ALB security group. This keeps the task port off the public internet while allowing the load balancer to reach it. The task egress rule is open so it can reach AWS APIs through NAT.

The ECS task definition duplicates a container health check inside the task. It sends container stdout/stderr to `/ecs/<service-name>` with the `ecs` stream prefix.

### Monitoring module

Monitoring creates CloudWatch metric alarms for average ECS CPU utilization above 80% over two five-minute periods and for one or more unhealthy ALB targets over two one-minute periods. If `alarm_email` is set, Terraform creates an SNS topic and email subscription and connects the alarms to it. The email recipient must confirm the SNS subscription. If no email is set, the alarms still exist but have no notification action.

Container Insights is enabled on the ECS cluster, while application logs are delivered via the task's `awslogs` driver.

## 7. State and credentials

Terraform state records the relationship between configuration and deployed AWS resource IDs. The backend example uses S3 for remote state and DynamoDB for state locking. The bootstrap script creates/configures a versioned, encrypted, public-access-blocked S3 bucket and a DynamoDB table, then writes the machine-specific `terraform/backend.tf` locally. That local backend config is ignored by Git.

The pipeline credential `aws-deploy` is stored in Jenkins Credentials, not in source code. It needs permissions for the Terraform-managed resources, ECR operations, state bucket and lock table access, and AWS identity lookup. In a production environment, prefer short-lived role credentials and least privilege. The bootstrap host also needs AWS credentials before it can check identity and create the backend; an EC2 instance profile avoids long-lived keys on that host.

The backend uses an S3 bucket and DynamoDB locking. Terraform has started deprecating the backend's `dynamodb_table` option in favor of S3 lockfiles in newer releases. For a fresh implementation, review the Terraform version in use and consider moving to `use_lockfile`; do not simply remove DynamoDB locking while concurrent runs may still use the backend.

## 8. Bootstrap and teardown scripts

### `scripts/bootstrap.sh`

On Ubuntu or Debian, the bootstrap script can install missing Docker Engine/Compose, Terraform, AWS CLI, Python 3, and curl. It checks whether the `aws` command exists rather than checking its version, so an existing AWS CLI v1 installation will not automatically be upgraded to v2. The AWS CLI installer URLs in both the host bootstrap script and Jenkins image are for x86_64; ARM servers need an architecture-aware installer. The script checks for AWS credentials, optionally creates the remote backend resources after confirmation, writes the ignored backend file, and starts Jenkins with Docker Compose. Trivy is installed in the Jenkins image, not as a host requirement. Git must be available to clone the repository before the script can run.

The script requires root or `sudo` for package installation and AWS permissions for state setup. It does not deploy the application; Jenkins performs that after the job and credentials are configured.

### `scripts/destroy.sh`

The destroy script requires typing `DESTROY` unless `--yes` is supplied. It deletes ECR image digests, then runs Terraform destroy. By default, it preserves the state bucket, lock table, and Jenkins data. Optional flags can stop Jenkins, remove its volume, and—only when explicitly requested—delete the backend resources.

Treat `--include-backend` as final project cleanup: removing the bucket also removes the Terraform state history. Do not remove the backend if the deployment may be managed or recreated later.

## 9. How to run and verify

### Local application

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-dev.txt
pytest -q
ruff check app tests

docker compose up --build -d
curl http://localhost:8000/health
docker compose down
```

### Live environment

1. Clone the repository to an Ubuntu or Debian server and provide AWS credentials (prefer an instance profile on EC2).
2. Run `scripts/bootstrap.sh` with a globally unique state-bucket name.
3. Finish Jenkins' browser setup and install the listed plugins.
4. Create a Pipeline job from SCM using this repository, `main`, and `Jenkinsfile`.
5. Add the `aws-deploy` Jenkins credential and GitHub push webhook.
6. Push to `main` or run the job manually once.
7. Confirm tests, Trivy, image push, Terraform apply, and the health-check stage pass.
8. Read the application URL from Terraform output or the build log.

Example verification commands:

```bash
terraform -chdir=terraform output -raw application_url
curl "$(terraform -chdir=terraform output -raw application_url)/health"
aws logs tail /ecs/devops-microservice-dev --follow --region us-east-1
aws ecs describe-services \
  --cluster devops-microservice-dev \
  --services devops-microservice-dev \
  --region us-east-1
```

Expected health output resembles:

```json
{"status":"healthy","service":"devops-microservice-dev","environment":"dev"}
```

If the ALB initially returns 503, it has no healthy targets yet. Check ECS task state and stopped reasons, then inspect the CloudWatch log group `/ecs/devops-microservice-dev`. Confirm that `/health` returns 200 in the container, the task listens on 8000, and the task security group allows traffic from the ALB security group.

## 10. Cost and security tradeoffs

This is a practical challenge implementation, not a claim that every production control is complete.

- Two NAT gateways, an ALB, Fargate tasks, ECR storage, CloudWatch, and public IPv4 resources can incur ongoing costs. Destroy the application environment after testing if it is no longer needed.
- Jenkins has access to the Docker socket, which grants powerful control over the host daemon. Use a dedicated host, restrict who can run jobs, and avoid untrusted pull-request builds on a privileged agent.
- The ALB uses HTTP on port 80. Add TLS using ACM, an HTTPS listener, and DNS for a real public service.
- There is no WAF, autoscaling policy, secret manager integration, or VPC endpoint configuration in this implementation.
- The task role currently has no application permissions, which is good least-privilege behavior for this API. Add only specific permissions if the application later needs AWS access.
- The bootstrap process has one-time operator steps: AWS identity setup, Jenkins initial configuration, credential creation, job setup, and webhook configuration.
- Jenkins uses an automated Terraform apply. Production environments commonly add review/approval gates, environment separation, protected branches, and plan review.

## 11. Talking points for an interview

### Why ECS Fargate?

Fargate runs containers without managing EC2 worker instances. It reduces server administration for a small service. EKS would provide Kubernetes features but would add operational complexity not required by this project.

### Why ECR and commit-SHA tags?

ECR integrates with AWS IAM and ECS. A commit SHA provides an immutable reference from a deployed image back to the exact source revision. Mutable tags like `latest` are less reliable for auditing or rollback.

### Why private ECS tasks behind an ALB?

The load balancer is the intended public entry point. Tasks have no public IP; their security group accepts application traffic only from the ALB security group. This reduces direct exposure of task addresses and ports.

### Why an ECR-only Terraform apply before the image push?

The first pipeline run needs a registry before it can push an image, while the full ECS task definition references that image. The targeted ECR apply bootstraps the repository; the full apply then creates the rest of the environment using the pushed image.

### What would you improve next?

Good concrete answers include: use per-AZ private route tables and NAT routing (or VPC endpoints) to correct/optimize network egress; enable HTTPS; use short-lived AWS role credentials; add ECS autoscaling; add HTTP integration tests; require Terraform plan review for production; set up SNS subscriptions; and add a multibranch pull-request validation job on an isolated, least-privilege agent.

## 12. Evidence and claims

The `screenshots/` directory contains the Jenkins pipeline/build, ECS service, ALB endpoint, and CloudWatch logs evidence. A previous successful Jenkins run reported three passing tests, a clean HIGH/CRITICAL Trivy policy scan, successful ECR push and Terraform apply, and a passing ALB health check. These results describe that recorded run; later code or dependency changes should be validated by a new pipeline run.

The README is the concise submission overview. This study guide is the deeper explanation for learning and discussion.
