#!/bin/bash
# set -x
set -euo pipefail

# Configuration Variables
AWS_REGION="${AWS_REGION:-us-east-1}"
readonly SECURITY_GROUP_NAME="jenkins-devsecops-sg"
readonly INSTANCE_TYPE_HEAVY="t4g.small"
readonly INSTANCE_TYPE_LIGHT="t4g.micro"
readonly ROLE_NAME="EC2ShutdownRole"
readonly PROFILE_NAME="EC2ShutdownProfile"
readonly TAG_NAME_JENKINS="Jenkins-Server"
readonly TAG_NAME_SONARQUBE="SonarQube-Server"
readonly TAG_NAME_PROM_GRAFANA="Prometheus-Grafana-Server"
readonly S3_BUCKET_NAME="jenkins-sonarqube-binaries-${RANDOM}"
readonly ECS_CLUSTER_NAME="devops-exercise-from-local-to-cloud"
readonly ECS_SERVICE_NAME="devops-exercise-from-local-to-cloud-service"
readonly ECS_TASK_FAMILY="devops-exercise-from-local-to-cloud-task"
readonly ECR_REPO_NAME="myapprepo"
readonly AWS_CLI_PROFILE="${AWS_PROFILE:-default}"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >&2
}

verify_aws_auth() {
    log "Verifying AWS CLI authentication using profile '$AWS_CLI_PROFILE'..."
    if ! aws sts get-caller-identity --profile "$AWS_CLI_PROFILE" >/dev/null 2>&1; then
        log "Error: AWS CLI is not properly authenticated or profile '$AWS_CLI_PROFILE' is missing valid credentials."
        log "Please ensure your credentials are configured correctly (e.g., via 'aws configure' or environment variables)."
        exit 1
    fi
    log "AWS authentication successful."
}

usage() {
    echo "Usage: $0 {provision [jenkins|sonarqube|prometheus]|teardown|update-ip}"
    echo
    echo "Options:"
    echo "  provision  : Deploys IAM roles, S3 bucket, Security Group, ECR, and ECS resources."
    echo "               You can specify individual servers to spin up: jenkins, sonarqube, prometheus."
    echo "               If no server is specified, all of them will be provisioned."
    echo "  teardown   : Terminates EC2 instances, cleans up AWS resources including IAM user, ECR, and ECS resources."
    echo "  update-ip  : Fetches your local machine's current public IP via curl,"
    echo "               clears out stale ingress rules in the Security Group, and"
    echo "               authorizes the new IP (ports 22, 3000, 8080, 9000, 9090) plus"
    echo "               self-referencing traffic between instances."
    exit 1
}

update_security_group_ip() {
    verify_aws_auth
    log "Locating Security Group: $SECURITY_GROUP_NAME..."
    SG_ID=$(aws ec2 describe-security-groups --group-names "$SECURITY_GROUP_NAME" --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)

    if [ -z "$SG_ID" ] || [ "$SG_ID" == "None" ]; then
        log "Security group '$SECURITY_GROUP_NAME' does not exist yet. Run 'provision' first."
        return 1
    fi

    log "Fetching your local public IP address..."
    MY_IP=$(curl -s http://checkip.amazonaws.com || curl -s ifconfig.me)
    if [ -z "$MY_IP" ]; then
        log "Error: Failed to fetch public IP address."
        exit 1
    fi
    MY_IP_CIDR="${MY_IP}/32"
    log "Current local public IP resolved to: $MY_IP_CIDR"

    log "Revoking existing inbound rules..."
    EXISTING_RULES=$(aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" --query 'SecurityGroups[0].IpPermissions' --output json)

    if [ "$EXISTING_RULES" != "[]" ] && [ -n "$EXISTING_RULES" ]; then
        aws ec2 revoke-security-group-ingress --group-id "$SG_ID" --ip-permissions "$EXISTING_RULES" --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" >/dev/null || true
    fi

    log "Authorizing inbound access for your IP ($MY_IP_CIDR) on ports 22, 3000, 8080, 9000, 9090..."
    for port in 22 3000 8080 9000 9090; do
        aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port "$port" --cidr "$MY_IP_CIDR" --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" >/dev/null
    done

    log "Authorizing self-referencing internal traffic for ports 3000, 8080, 9000, 9090..."
    for port in 3000 8080 9000 9090; do
        aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port "$port" --source-group "$SG_ID" --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" >/dev/null
    done

    log "Security group successfully updated!"
}

create_security_group() {
    log "Checking/Creating Security Group..."
    if ! SG_ID=$(aws ec2 describe-security-groups --group-names "$SECURITY_GROUP_NAME" --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null); then
        SG_ID=$(aws ec2 create-security-group --group-name "$SECURITY_GROUP_NAME" \
            --description "SG for Jenkins, SonarQube, and Prometheus/Grafana Instances" \
            --query 'GroupId' --output text --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE")
    fi

    update_security_group_ip
    echo "$SG_ID"
}

setup_iam_profile() {
    log "Checking/Configuring IAM Instance Profile..."
    if ! aws iam get-role --role-name "$ROLE_NAME" --profile "$AWS_CLI_PROFILE" >/dev/null 2>&1; then
        aws iam create-role --role-name "$ROLE_NAME" --profile "$AWS_CLI_PROFILE" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
        aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess --profile "$AWS_CLI_PROFILE" >/dev/null
    fi

    aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess --profile "$AWS_CLI_PROFILE" >/dev/null || true
    aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser --profile "$AWS_CLI_PROFILE" >/dev/null || true

    if ! aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" --profile "$AWS_CLI_PROFILE" >/dev/null 2>&1; then
        aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" --profile "$AWS_CLI_PROFILE" >/dev/null
        aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" --profile "$AWS_CLI_PROFILE" >/dev/null
    fi

    log "Waiting for IAM instance profile propagation..."
    aws iam wait instance-profile-exists --instance-profile-name "$PROFILE_NAME" --profile "$AWS_CLI_PROFILE"
}

create_jenkins_iam_user() {
    log "Checking/Creating IAM user 'jenkins'..."
    if ! aws iam get-user --user-name jenkins --profile "$AWS_CLI_PROFILE" >/dev/null 2>&1; then
        aws iam create-user --user-name jenkins --profile "$AWS_CLI_PROFILE" >/dev/null
    fi

    log "Attaching policies to IAM user 'jenkins'..."
    aws iam attach-user-policy \
        --user-name jenkins \
        --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess \
        --profile "$AWS_CLI_PROFILE" >/dev/null 2>&1 || true

    aws iam attach-user-policy \
        --user-name jenkins \
        --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess \
        --profile "$AWS_CLI_PROFILE" >/dev/null 2>&1 || true

    log "Generating Access Keys for 'jenkins' user..."
    aws iam create-access-key --user-name jenkins --profile "$AWS_CLI_PROFILE" --output json | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
key = data['AccessKey']
print('----------------------------------------')
print('Access Key ID:     ', key['AccessKeyId'])
print('Secret Access Key: ', key['SecretAccessKey'])
print('----------------------------------------')
"
}

setup_ecr_repository() {
    log "Checking/Creating ECR Repository: $ECR_REPO_NAME..."
    aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" >/dev/null 2>&1 || \
    aws ecr create-repository --repository-name "$ECR_REPO_NAME" --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" >/dev/null
}

setup_ecs_resources() {
    log "Creating ECS Cluster: $ECS_CLUSTER_NAME..."
    aws ecs create-cluster --cluster-name "$ECS_CLUSTER_NAME" --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" >/dev/null || true

    log "Registering initial placeholder Task Definition: $ECS_TASK_FAMILY..."
    aws ecs register-task-definition \
        --family "$ECS_TASK_FAMILY" \
        --network-mode awsvpc \
        --requires-compatibilities FARGATE \
        --cpu "256" \
        --memory "512" \
        --container-definitions "[{
            \"name\": \"app\",
            \"image\": \"amazon/amazon-ecs-sample\",
            \"portMappings\": [{
                \"containerPort\": 8080,
                \"hostPort\": 8080
            }]
        }]" \
        --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" >/dev/null || true

    log "Creating ECS Service: $ECS_SERVICE_NAME..."
    DEFAULT_SUBNET=$(aws ec2 describe-subnets --filters "Name=default-for-az,Values=true" --query "Subnets[0].SubnetId" --output text --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" 2>/dev/null || true)

    if [ -n "$DEFAULT_SUBNET" ] && [ "$DEFAULT_SUBNET" != "None" ]; then
        aws ecs create-service \
            --cluster "$ECS_CLUSTER_NAME" \
            --service-name "$ECS_SERVICE_NAME" \
            --task-definition "$ECS_TASK_FAMILY" \
            --desired-count 1 \
            --launch-type FARGATE \
            --network-configuration "awsvpcConfiguration={subnets=[$DEFAULT_SUBNET],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
            --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" >/dev/null || true
    fi
}

upload_binary_to_s3() {
    EXISTING_BUCKET=$(aws s3api list-buckets --profile "$AWS_CLI_PROFILE" --query "Buckets[?starts_with(Name, 'jenkins-sonarqube-binaries-')].Name" --output text 2>/dev/null || true)

    if [ -n "$EXISTING_BUCKET" ] && [ "$EXISTING_BUCKET" != "None" ]; then
        if aws s3 ls "s3://$EXISTING_BUCKET/sonarqube.zip" --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" >/dev/null 2>&1; then
            log "The zip file already exists in s3://$EXISTING_BUCKET/. Skipping upload."
            export ACTIVE_S3_BUCKET="$EXISTING_BUCKET"
            return 0
        else
            log "s3://$EXISTING_BUCKET/ exists, but the file is not accessible. Creating a new bucket."
        fi
    fi

    log "Creating a new S3 bucket temporarily: $S3_BUCKET_NAME..."
    if [ "$AWS_REGION" == "us-east-1" ]; then
        aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" >/dev/null
    else
        aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
    fi

    log "Uploading the SonarQube zip to s3://$S3_BUCKET_NAME/..."
    aws s3 cp sonarqube-26.9.0.129388.zip "s3://$S3_BUCKET_NAME/sonarqube.zip" --profile "$AWS_CLI_PROFILE"
    export ACTIVE_S3_BUCKET="$S3_BUCKET_NAME"
}

generate_user_data_jenkins() {
    cat << 'EOF' > user-data-jenkins.sh
#!/bin/bash
set -x
exec > >(tee /var/log/user-data.log|logger) 2>&1

log() { echo "[User-Data] $1"; }

log "Configuring 1GB Swap space for t4g.small..."
fallocate -l 1G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

log "Updating system packages and installing prerequisites..."
apt-get update -y && apt-get upgrade -y
apt-get install -y fontconfig openjdk-21-jdk unzip curl net-tools groff maven tree docker.io

log "Installing official AWS CLI v2 for ARM64..."
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "/tmp/awscliv2.zip"
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws

systemctl enable --now docker

log "Installing Jenkins prerequisites and stable Node.js..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key | tee /etc/apt/keyrings/jenkins-keyring.asc > /dev/null
echo deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/ | tee /etc/apt/sources.list.d/jenkins.list > /dev/null

curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

apt-get update -y && apt-get install -y jenkins

log "Bypassing Jenkins Setup Wizard via systemd override..."
mkdir -p /etc/systemd/system/jenkins.service.d
cat << 'EOT' > /etc/systemd/system/jenkins.service.d/override.conf
[Service]
Environment="JENKINS_JAVA_OPTIONS=-Djenkins.install.runSetupWizard=false"
EOT

systemctl daemon-reload
systemctl enable --now jenkins

sudo usermod -aG docker jenkins
sudo systemctl restart docker
sudo systemctl restart jenkins

log "Setting up daily shutdown cron job..."
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
echo "0 0 * * * root aws ec2 stop-instances --instance-ids $INSTANCE_ID --region $REGION" > /etc/cron.d/daily-shutdown
chmod 644 /etc/cron.d/daily-shutdown
log "Jenkins provisioning complete!"
EOF
}

generate_user_data_sonarqube() {
    cat << 'EOF' > user-data-sonarqube.sh
#!/bin/bash
set -x
exec > >(tee /var/log/user-data.log|logger) 2>&1

log() { echo "[User-Data] $1"; }

log "Configuring 1GB Swap space for t4g.small..."
fallocate -l 1G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

log "Updating system packages and installing prerequisites..."
apt-get update -y && apt-get upgrade -y
apt-get install -y fontconfig openjdk-21-jre unzip curl net-tools groff

log "Installing official AWS CLI v2 for ARM64..."
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "/tmp/awscliv2.zip"
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws

log "Downloading SonarQube from S3 bucket..."
useradd -r -M -d /opt/sonarqube -s /bin/bash sonarqube || true
aws s3 cp s3://__ACTIVE_S3_BUCKET__/sonarqube.zip /tmp/sonarqube.zip --region __AWS_REGION__
unzip -q /tmp/sonarqube.zip -d /tmp
rm -rf /opt/sonarqube
mv /tmp/sonarqube-* /opt/sonarqube
chown -R sonarqube:sonarqube /opt/sonarqube
chmod +x /opt/sonarqube/bin/linux-x86-64/sonar.sh
rm -f /tmp/sonarqube.zip

log "Tuning SonarQube JVM heap options for t4g.small..."
cat << 'EOT' >> /opt/sonarqube/conf/sonar.properties
sonar.web.javaOpts=-Xmx512m -Xms256m -XX:+UseG1GC
sonar.ce.javaOpts=-Xmx512m -Xms256m -XX:+UseG1GC
sonar.search.javaOpts=-Xmx512m -Xms256m -XX:+UseG1GC
EOT

cat << 'EOT' > /etc/systemd/system/sonarqube.service
[Unit]
Description=SonarQube service
After=syslog.target network.target

[Service]
Type=forking
ExecStart=/opt/sonarqube/bin/linux-x86-64/sonar.sh start
ExecStop=/opt/sonarqube/bin/linux-x86-64/sonar.sh stop
User=sonarqube
Group=sonarqube
Restart=always
LimitNOFILE=65536
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
EOT

chown -R sonarqube:sonarqube /opt/sonarqube
chmod +x /opt/sonarqube/bin/linux-x86-64/sonar.sh

systemctl daemon-reload
systemctl enable --now sonarqube

log "Setting up daily shutdown cron job..."
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
echo "0 0 * * * root aws ec2 stop-instances --instance-ids $INSTANCE_ID --region $REGION" > /etc/cron.d/daily-shutdown
chmod 644 /etc/cron.d/daily-shutdown
log "SonarQube provisioning complete!"
EOF

    sed -i "s|__ACTIVE_S3_BUCKET__|$ACTIVE_S3_BUCKET|g" user-data-sonarqube.sh
    sed -i "s|__AWS_REGION__|$AWS_REGION|g" user-data-sonarqube.sh
}

generate_user_data_prometheus_grafana() {
    cat << 'EOF' > user-data-prometheus-grafana.sh
#!/bin/bash
set -x
exec > >(tee /var/log/user-data.log|logger) 2>&1

log() { echo "[User-Data] $1"; }

log "Syncing system time..."
apt-get update -y && apt-get install -y chrony
systemctl enable --now chronyd || systemctl enable --now chrony
chronyc -a makestep

log "Configuring 1GB Swap space for t4g.micro..."
fallocate -l 1G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

log "Updating system packages and installing prerequisites..."
apt-get update -y && apt-get upgrade -y
apt-get install -y unzip curl net-tools groff apt-transport-https software-properties-common wget

log "Installing Prometheus..."
useradd --no-create-home --shell /bin/false prometheus || true
mkdir -p /etc/prometheus /var/lib/prometheus

PROM_VERSION="2.51.0"
curl -sLO "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-arm64.tar.gz"
tar -xvf "prometheus-${PROM_VERSION}.linux-arm64.tar.gz"
cp "prometheus-${PROM_VERSION}.linux-arm64/prometheus" /usr/local/bin/
cp "prometheus-${PROM_VERSION}.linux-arm64/promtool" /usr/local/bin/
chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool
cp -r "prometheus-${PROM_VERSION}.linux-arm64/consoles" /etc/prometheus/
cp -r "prometheus-${PROM_VERSION}.linux-arm64/console_libraries" /etc/prometheus/
chown -R prometheus:prometheus /etc/prometheus/consoles /etc/prometheus/console_libraries
rm -rf "prometheus-${PROM_VERSION}.linux-arm64*"

log "Creating Prometheus configuration file..."
cat << 'EOT' > /etc/prometheus/prometheus.yml
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
EOT

chown prometheus:prometheus /etc/prometheus/prometheus.yml

cat << 'EOT' > /etc/systemd/system/prometheus.service
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
    --config.file /etc/prometheus/prometheus.yml \
    --storage.tsdb.path /var/lib/prometheus/ \
    --web.listen-address=0.0.0.0:9090

[Install]
WantedBy=multi-user.target
EOT

systemctl daemon-reload
systemctl enable --now prometheus

log "Installing Grafana..."
mkdir -p /etc/apt/keyrings
wget -q -O /etc/apt/keyrings/grafana.key https://apt.grafana.com/gpg.key
echo "deb [signed-by=/etc/apt/keyrings/grafana.key] https://apt.grafana.com stable main" | tee /etc/apt/sources.list.d/grafana.list
apt-get update -y
apt-get install -y grafana
systemctl daemon-reload
systemctl enable --now grafana-server

log "Setting up daily shutdown cron job..."
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
echo "0 0 * * * root aws ec2 stop-instances --instance-ids $INSTANCE_ID --region $REGION" > /etc/cron.d/daily-shutdown
chmod 644 /etc/cron.d/daily-shutdown
log "Prometheus and Grafana provisioning complete!"
EOF
}

provision() {
    local TARGET_SERVER="${1:-all}"
    verify_aws_auth
    SG_ID=$(create_security_group)
    setup_iam_profile
    create_jenkins_iam_user
    setup_ecr_repository
    setup_ecs_resources
    upload_binary_to_s3

    log "Fetching latest Ubuntu ARM64 AMI..."
    AMI_ID=$(aws ec2 describe-images --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" --owners 099720109477 --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*" "Name=state,Values=available" --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)

    log "Waiting 10 seconds for IAM profile propagation..."
    sleep 10

    # Provision Jenkins Server
    if [ "$TARGET_SERVER" == "all" ] || [ "$TARGET_SERVER" == "jenkins" ]; then
        generate_user_data_jenkins
        log "Launching Instance: Jenkins Server ($INSTANCE_TYPE_HEAVY)..."
        ID_JENKINS=$(aws ec2 run-instances \
            --image-id "$AMI_ID" \
            --count 1 \
            --instance-type "$INSTANCE_TYPE_HEAVY" \
            --security-group-ids "$SG_ID" \
            --iam-instance-profile "Name=$PROFILE_NAME" \
            --user-data file://user-data-jenkins.sh \
            --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":20,"VolumeType":"gp3"}}]' \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG_NAME_JENKINS}]" \
            --query 'Instances[0].InstanceId' --output text --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE")
        log "Jenkins Instance ID: $ID_JENKINS"
    fi

    # Provision SonarQube Server
    if [ "$TARGET_SERVER" == "all" ] || [ "$TARGET_SERVER" == "sonarqube" ]; then
        generate_user_data_sonarqube
        log "Launching Instance: SonarQube Server ($INSTANCE_TYPE_HEAVY)..."
        ID_SQ=$(aws ec2 run-instances \
            --image-id "$AMI_ID" \
            --count 1 \
            --instance-type "$INSTANCE_TYPE_HEAVY" \
            --security-group-ids "$SG_ID" \
            --iam-instance-profile "Name=$PROFILE_NAME" \
            --user-data file://user-data-sonarqube.sh \
            --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":20,"VolumeType":"gp3"}}]' \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG_NAME_SONARQUBE}]" \
            --query 'Instances[0].InstanceId' --output text --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE")
        log "SonarQube Instance ID: $ID_SQ"
    fi

    # Provision Prometheus & Grafana Server
    if [ "$TARGET_SERVER" == "all" ] || [ "$TARGET_SERVER" == "prometheus" ]; then
        generate_user_data_prometheus_grafana
        log "Launching Instance: Prometheus & Grafana Server ($INSTANCE_TYPE_LIGHT)..."
        ID_PROM_GRAFANA=$(aws ec2 run-instances \
            --image-id "$AMI_ID" \
            --count 1 \
            --instance-type "$INSTANCE_TYPE_LIGHT" \
            --security-group-ids "$SG_ID" \
            --iam-instance-profile "Name=$PROFILE_NAME" \
            --user-data file://user-data-prometheus-grafana.sh \
            --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":20,"VolumeType":"gp3"}}]' \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG_NAME_PROM_GRAFANA}]" \
            --query 'Instances[0].InstanceId' --output text --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE")
        log "Prometheus & Grafana Instance ID: $ID_PROM_GRAFANA"
    fi

    log "Successfully provisioned requested resources!"
}

teardown() {
    verify_aws_auth
    log "Locating and terminating instances..."
    for TAG in "$TAG_NAME_JENKINS" "$TAG_NAME_SONARQUBE" "$TAG_NAME_PROM_GRAFANA"; do
        INSTANCE_ID=$(aws ec2 describe-instances \
            --filters "Name=tag:Name,Values=$TAG" "Name=instance-state-name,Values=pending,running,stopped,stopping" \
            --query "Reservations[*].Instances[*].InstanceId" --output text --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" 2>/dev/null || true)

        if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
            log "Terminating instance $INSTANCE_ID ($TAG)..."
            aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" >/dev/null
        fi
    done

    log "Waiting for instances to terminate..."
    sleep 15

    log "Cleaning up ECS Service and Cluster..."
    aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$ECS_SERVICE_NAME" --desired-count 0 --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" >/dev/null 2>&1 || true
    aws ecs delete-service --cluster "$ECS_CLUSTER_NAME" --service "$ECS_SERVICE_NAME" --force --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" >/dev/null 2>&1 || true
    aws ecs delete-cluster --cluster "$ECS_CLUSTER_NAME" --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" >/dev/null 2>&1 || true

    log "Deregistering ECS Task Definitions..."
    TASK_ARNS=$(aws ec2 list-task-definitions --family-prefix "$ECS_TASK_FAMILY" --status ACTIVE --query "taskDefinitionArns" --output text --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" 2>/dev/null || true)
    for task_arn in $TASK_ARNS; do
        if [ -n "$task_arn" ] && [ "$task_arn" != "None" ]; then
            log "Deregistering task definition: $task_arn"
            aws ec2 deregister-task-definition --task-definition "$task_arn" --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" >/dev/null 2>&1 || true
        fi
    done

    log "Cleaning up ECR Repository ($ECR_REPO_NAME)..."
    aws ecr delete-repository --repository-name "$ECR_REPO_NAME" --force --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" >/dev/null 2>&1 || true

    EXISTING_BUCKET=$(aws s3api list-buckets --profile "$AWS_CLI_PROFILE" --query "Buckets[?starts_with(Name, 'jenkins-sonarqube-binaries-')].Name" --output text 2>/dev/null || true)
    if [ -n "$EXISTING_BUCKET" ] && [ "$EXISTING_BUCKET" != "None" ]; then
        read -p "Do you want to delete '$EXISTING_BUCKET' and its content? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log "Deleting bucket and content: $EXISTING_BUCKET"
            aws s3 rm "s3://$EXISTING_BUCKET" --recursive --profile "$AWS_CLI_PROFILE" >/dev/null || true
            aws s3api delete-bucket --bucket "$EXISTING_BUCKET" --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" >/dev/null || true
        else
            log "Retaining bucket and content: $EXISTING_BUCKET"
        fi
    fi

    log "Deleting Security Group..."
    SG_ID=$(aws ec2 describe-security-groups --group-names "$SECURITY_GROUP_NAME" --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
    if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
        log "Waiting for dependent ENIs to release..."
        for i in {1..12}; do
            if aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION" --profile "$AWS_CLI_PROFILE" >/dev/null 2>&1; then
                log "Security Group successfully deleted."
                break
            fi
            sleep 5
        done
    fi

    log "Cleaning up IAM Profile and Role..."
    if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" --profile "$AWS_CLI_PROFILE" >/dev/null 2>&1; then
        aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" --profile "$AWS_CLI_PROFILE" >/dev/null || true
        aws iam delete-instance-profile --instance-profile-name "$PROFILE_NAME" --profile "$AWS_CLI_PROFILE" >/dev/null || true
    fi

    if aws iam get-role --role-name "$ROLE_NAME" --profile "$AWS_CLI_PROFILE" >/dev/null 2>&1; then
        ATTACHED_POLICIES=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --profile "$AWS_CLI_PROFILE" --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null || true)
        for policy_arn in $ATTACHED_POLICIES; do
            aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$policy_arn" --profile "$AWS_CLI_PROFILE" >/dev/null || true
        done

        INLINE_POLICIES=$(aws iam list-role-policies --role-name "$ROLE_NAME" --profile "$AWS_CLI_PROFILE" --query 'PolicyNames[*]' --output text 2>/dev/null || true)
        for policy_name in $INLINE_POLICIES; do
            aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$policy_name" --profile "$AWS_CLI_PROFILE" >/dev/null || true
        done

        aws iam delete-role --role-name "$ROLE_NAME" --profile "$AWS_CLI_PROFILE" >/dev/null || true
    fi

    log "Cleaning up IAM User 'jenkins'..."
    if aws iam get-user --user-name jenkins --profile "$AWS_CLI_PROFILE" >/dev/null 2>&1; then
        KEYS=$(aws iam list-access-keys --user-name jenkins --profile "$AWS_CLI_PROFILE" --query 'AccessKeyMetadata[*].AccessKeyId' --output text 2>/dev/null || true)
        for kid in $KEYS; do
            aws iam delete-access-key --user-name jenkins --access-key-id "$kid" --profile "$AWS_CLI_PROFILE" >/dev/null 2>&1 || true
        done

        ATTACHED_USER_POLICIES=$(aws iam list-attached-user-policies --user-name jenkins --profile "$AWS_CLI_PROFILE" --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null || true)
        for policy_arn in $ATTACHED_USER_POLICIES; do
            aws iam detach-user-policy --user-name jenkins --policy-arn "$policy_arn" --profile "$AWS_CLI_PROFILE" >/dev/null || true
        done

        aws iam delete-user --user-name jenkins --profile "$AWS_CLI_PROFILE" >/dev/null || true
    fi

    log "Teardown complete!"
}

case "${1:-}" in
    provision)
        provision "${2:-all}"
        ;;
    teardown)
        teardown
        ;;
    update-ip)
        update_security_group_ip
        ;;
    *)
        usage
        ;;
esac