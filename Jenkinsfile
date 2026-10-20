pipeline {
    agent any

    triggers {
        githubPush()
    }

    options {
        timestamps()
        disableConcurrentBuilds()
        skipDefaultCheckout(true)
    }

    environment {
        AWS_REGION = 'us-east-1'
        APP_NAME   = 'devops-microservice'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm

                script {
                    env.GIT_SHA = sh(
                        script: 'git rev-parse HEAD',
                        returnStdout: true
                    ).trim()

                    env.IMAGE_TAG = env.GIT_SHA
                }
            }
        }

        stage('Install CI Dependencies') {
            steps {
                sh '''
                    python3 -m venv .venv-ci
                    . .venv-ci/bin/activate

                    python -m pip install --upgrade pip
                    python -m pip install -r requirements-dev.txt
                '''
            }
        }

        stage('Validate') {
            steps {
                sh '''
                    . .venv-ci/bin/activate

                    python -m compileall -q app
                    python -m ruff check app tests

                    terraform -chdir=terraform fmt -check -recursive
                    terraform -chdir=terraform init \
                        -backend=false \
                        -input=false
                    terraform -chdir=terraform validate
                '''
            }
        }

        stage('Test') {
            steps {
                sh '''
                    . .venv-ci/bin/activate
                    pytest -q
                '''
            }
        }

        stage('Build') {
            steps {
                sh '''
                    docker build \
                        --pull \
                        -t "$APP_NAME:$IMAGE_TAG" .
                '''
            }
        }

        stage('Scan') {
            steps {
                sh '''
                    command -v trivy >/dev/null 2>&1 || {
                        echo "Trivy is not installed"
                        exit 1
                    }

                    trivy image \
                        --exit-code 1 \
                        --severity HIGH,CRITICAL \
                        --ignore-unfixed \
                        "$APP_NAME:$IMAGE_TAG"
                '''
            }
        }

        stage('Push') {
            when {
                not {
                    changeRequest()
                }
            }

            steps {
                withCredentials([
                    [
                        $class: 'AmazonWebServicesCredentialsBinding',
                        credentialsId: 'aws-deploy'
                    ]
                ]) {
                    sh '''
                        terraform -chdir=terraform init \
                            -input=false

                        terraform -chdir=terraform apply \
                            -target=module.ecr \
                            -auto-approve \
                            -input=false \
                            -var="aws_region=$AWS_REGION"

                        REPO=$(terraform -chdir=terraform output -raw ecr_repository_url)
                        REGISTRY=$(echo "$REPO" | cut -d/ -f1)

                        aws ecr get-login-password \
                            --region "$AWS_REGION" \
                            | docker login \
                                --username AWS \
                                --password-stdin "$REGISTRY"

                        docker tag \
                            "$APP_NAME:$IMAGE_TAG" \
                            "$REPO:$IMAGE_TAG"

                        docker push "$REPO:$IMAGE_TAG"
                    '''
                }
            }
        }

        stage('Deploy') {
            when {
                not {
                    changeRequest()
                }
            }

            steps {
                withCredentials([
                    [
                        $class: 'AmazonWebServicesCredentialsBinding',
                        credentialsId: 'aws-deploy'
                    ]
                ]) {
                    sh '''
                        terraform -chdir=terraform apply \
                            -auto-approve \
                            -input=false \
                            -var="aws_region=$AWS_REGION" \
                            -var="image_tag=$IMAGE_TAG"
                    '''
                }
            }
        }

        stage('Verify') {
            when {
                not {
                    changeRequest()
                }
            }

            steps {
                withCredentials([
                    [
                        $class: 'AmazonWebServicesCredentialsBinding',
                        credentialsId: 'aws-deploy'
                    ]
                ]) {
                    sh '''
                        URL=$(terraform -chdir=terraform output -raw application_url)

                        for attempt in $(seq 1 30); do
                            if curl --fail --silent --show-error \
                                "$URL/health"; then
                                echo "Application health check passed"
                                exit 0
                            fi

                            echo "Health check attempt $attempt failed"
                            sleep 10
                        done

                        echo "Application health check failed"
                        exit 1
                    '''
                }
            }
        }
    }

    post {
        always {
            sh 'rm -rf .venv-ci || true'
        }
    }
}
