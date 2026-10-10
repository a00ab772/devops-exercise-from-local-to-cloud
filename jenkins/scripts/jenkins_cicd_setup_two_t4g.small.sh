#!/bin/bash
# set -x
set -euo pipefail

# Configuration Variables
AWS_REGION="${AWS_REGION:-us-east-1}"
readonly SECURITY_GROUP_NAME="jenkins-devsecops-sg"
readonly INSTANCE_TYPE="t4g.small"
readonly ROLE_NAME="EC2ShutdownRole"
readonly PROFILE_NAME="EC2ShutdownProfile"
readonly TAG_NAME_JENKINS_NEXUS="Jenkins-Nexus-Server"
readonly TAG_NAME_SONARQUBE="SonarQube-Server"
readonly S3_BUCKET_NAME="jenkins-sonarqube-binaries-${RANDOM}"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >&2
}

usage() {
    echo "Usage: $0 {provision|teardown}"
    exit 1
}

create_security_group() {
    log "Checking/Creating Security Group..."
    if ! SG_ID=$(aws ec2 describe-security-groups --group-names "$SECURITY_GROUP_NAME" --region "$AWS_REGION" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null); then
        SG_ID=$(aws ec2 create-security-group --group-name "$SECURITY_GROUP_NAME" \
            --description "SG for Split Jenkins/Nexus and SonarQube POC" \
            --query 'GroupId' --output text --region "$AWS_REGION")

        log "Fetching your public IP address..."
        MY_IP=$(curl -s http://checkip.amazonaws.com)
        MY_IP_CIDR="${MY_IP}/32"
        log "Restricting inbound access to your IP: $MY_IP_CIDR"

        log "Opening inbound ports (SSH: 22, Jenkins: 8080, Nexus: 8081, SonarQube: 9000)..."
        for port in 22 8080 8081 9000; do
            aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port "$port" --cidr "$MY_IP_CIDR" --region "$AWS_REGION" >/dev/null
        done
    fi

    echo "$SG_ID"
}

setup_iam_profile() {
    log "Checking/Configuring IAM Instance Profile..."
    if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
        aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
        aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess >/dev/null
    fi

    aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess >/dev/null || true

    if ! aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
        aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null
        aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" >/dev/null
    fi

    log "Waiting for IAM instance profile propagation..."
    aws iam wait instance-profile-exists --instance-profile-name "$PROFILE_NAME"
}

upload_binary_to_s3() {
    EXISTING_BUCKET=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, 'jenkins-sonarqube-binaries-')].Name" --output text 2>/dev/null || true)

    if [ -n "$EXISTING_BUCKET" ] && [ "$EXISTING_BUCKET" != "None" ]; then
        if aws s3 ls "s3://$EXISTING_BUCKET/sonarqube.zip" --region "$AWS_REGION" >/dev/null 2>&1; then
            log "The zip file already exists in s3://$EXISTING_BUCKET/. Skipping upload."
            export ACTIVE_S3_BUCKET="$EXISTING_BUCKET"
            return 0
        else
            log "s3://$EXISTING_BUCKET/ exists, but the file is not accessible. Creating a new bucket."
        fi
    fi

    log "Creating a new S3 bucket temporarily: $S3_BUCKET_NAME..."
    if [ "$AWS_REGION" == "us-east-1" ]; then
        aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" >/dev/null
    else
        aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
    fi

    log "Uploading the SonarQube zip to s3://$S3_BUCKET_NAME/..."
    aws s3 cp sonarqube-26.9.0.129388.zip "s3://$S3_BUCKET_NAME/sonarqube.zip"
    export ACTIVE_S3_BUCKET="$S3_BUCKET_NAME"
}

generate_user_data_jenkins_nexus() {
    cat << 'EOF' > user-data-jenkins-nexus.sh
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
apt-get install -y fontconfig openjdk-21-jdk unzip curl net-tools groff maven tree

log "Installing Jenkins prerequisites and Jenkins..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key | tee /etc/apt/keyrings/jenkins-keyring.asc > /dev/null
echo deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/ | tee /etc/apt/sources.list.d/jenkins.list > /dev/null
apt-get update -y && apt-get install -y jenkins
systemctl enable --now jenkins

log "Installing Nexus prerequisites (Java 17) and Nexus OSS..."
apt-get install -y openjdk-17-jdk
cd /opt
useradd -r -M -d /opt/nexus -s /bin/false nexus || true
NEXUS_URL="https://download.sonatype.com/nexus/3/nexus-3.77.2-02-unix.tar.gz"
wget "$NEXUS_URL" -O nexus.tar.gz || wget "https://download.sonatype.com/nexus/3/latest-unix.tar.gz" -O nexus.tar.gz
tar -xvf nexus.tar.gz && rm -rf nexus && mv nexus-3* nexus && chown -R nexus:nexus /opt/nexus

echo 'run_as_user="nexus"' > /opt/nexus/bin/nexus.rc
echo 'INSTALL4J_JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"' >> /opt/nexus/bin/nexus.rc
echo '-Xms512m' >> /opt/nexus/bin/nexus.vmoptions
echo '-Xmx512m' >> /opt/nexus/bin/nexus.vmoptions
echo '-Dinstall4j.javaHome=/usr/lib/jvm/java-17-openjdk-amd64' >> /opt/nexus/bin/nexus.vmoptions

chown -R nexus:nexus /opt/nexus
mkdir -p /opt/sonatype-work
chown -R nexus:nexus /opt/sonatype-work

cat << 'EOT' > /etc/systemd/system/nexus.service
[Unit]
Description=Nexus Service
After=syslog.target network.target

[Service]
Type=forking
LimitNOFILE=65536
ExecStart=/opt/nexus/bin/nexus start
ExecStop=/opt/nexus/bin/nexus stop
User=nexus
Group=nexus
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOT

systemctl daemon-reload
systemctl enable --now nexus

log "Setting up daily shutdown cron job..."
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
echo "0 0 * * * root aws ec2 stop-instances --instance-ids $INSTANCE_ID --region $REGION" > /etc/cron.d/daily-shutdown
chmod 644 /etc/cron.d/daily-shutdown
log "Jenkins & Nexus provisioning complete!"
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

provision() {
    SG_ID=$(create_security_group)
    setup_iam_profile
    upload_binary_to_s3

    generate_user_data_jenkins_nexus
    generate_user_data_sonarqube

    log "Fetching latest Ubuntu ARM64 AMI..."
    AMI_ID=$(aws ec2 describe-images --region "$AWS_REGION" --owners 099720109477 --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*" "Name=state,Values=available" --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)

    log "Waiting 10 seconds for IAM profile propagation..."
    sleep 10

    log "Launching Instance 1: Jenkins & Nexus (t4g.small)..."
    ID_JN=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --count 1 \
        --instance-type "$INSTANCE_TYPE" \
        --security-group-ids "$SG_ID" \
        --iam-instance-profile "Name=$PROFILE_NAME" \
        --user-data file://user-data-jenkins-nexus.sh \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":20,"VolumeType":"gp3"}}]' \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG_NAME_JENKINS_NEXUS}]" \
        --query 'Instances[0].InstanceId' --output text --region "$AWS_REGION")

    log "Launching Instance 2: SonarQube (t4g.small)..."
    ID_SQ=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --count 1 \
        --instance-type "$INSTANCE_TYPE" \
        --security-group-ids "$SG_ID" \
        --iam-instance-profile "Name=$PROFILE_NAME" \
        --user-data file://user-data-sonarqube.sh \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":20,"VolumeType":"gp3"}}]' \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG_NAME_SONARQUBE}]" \
        --query 'Instances[0].InstanceId' --output text --region "$AWS_REGION")

    log "Successfully provisioned instances!"
    log "Jenkins & Nexus Instance ID: $ID_JN"
    log "SonarQube Instance ID: $ID_SQ"
}

teardown() {
    log "Locating and terminating instances..."
    for TAG in "$TAG_NAME_JENKINS_NEXUS" "$TAG_NAME_SONARQUBE"; do
        INSTANCE_ID=$(aws ec2 describe-instances \
            --filters "Name=tag:Name,Values=$TAG" "Name=instance-state-name,Values=pending,running,stopped,stopping" \
            --query "Reservations[*].Instances[*].InstanceId" --output text --region "$AWS_REGION" 2>/dev/null || true)

        if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
            log "Terminating instance $INSTANCE_ID ($TAG)..."
            aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" >/dev/null
        fi
    done

    log "Waiting for instances to terminate..."
    sleep 15

    EXISTING_BUCKET=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, 'jenkins-sonarqube-binaries-')].Name" --output text 2>/dev/null || true)
    if [ -n "$EXISTING_BUCKET" ] && [ "$EXISTING_BUCKET" != "None" ]; then
        read -p "Do you want to delete '$EXISTING_BUCKET' and its content? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log "Deleting bucket and content: $EXISTING_BUCKET"
            aws s3 rm "s3://$EXISTING_BUCKET" --recursive >/dev/null || true
            aws s3api delete-bucket --bucket "$EXISTING_BUCKET" --region "$AWS_REGION" >/dev/null || true
        else
            log "Retaining bucket and content: $EXISTING_BUCKET"
        fi
    fi

    log "Deleting Security Group..."
    SG_ID=$(aws ec2 describe-security-groups --group-names "$SECURITY_GROUP_NAME" --region "$AWS_REGION" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
    if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
        sleep 5
        aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION" >/dev/null || log "Warning: Could not delete security group immediately."
    fi

    log "Cleaning up IAM Profile and Role..."
    if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
        aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" >/dev/null || true
        aws iam delete-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null || true
    fi

    if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
        aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess >/dev/null || true
        aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess >/dev/null || true
        aws iam delete-role --role-name "$ROLE_NAME" >/dev/null || true
    fi

    log "Teardown complete!"
}

case "${1:-}" in
    provision)
        provision
        ;;
    teardown)
        teardown
        ;;
    *)
        usage
        ;;
esac