FROM jenkins/jenkins:lts-jdk17

USER root

RUN apt-get update && \
    apt-get install -y \
      python3 \
      python3-pip \
      python3-venv \
      curl \
      wget \
      gnupg \
      docker.io \
      ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Install Trivy from the official repository
RUN wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key \
      | gpg --dearmor \
      | tee /usr/share/keyrings/trivy.gpg > /dev/null && \
    echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
      > /etc/apt/sources.list.d/trivy.list && \
    apt-get update && \
    apt-get install -y trivy && \
    rm -rf /var/lib/apt/lists/*

USER jenkins