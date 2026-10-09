#!/bin/bash
# set -x
set -euo pipefail

# Configuration Variables
AWS_REGION="${AWS_REGION:-us-east-1}"
readonly SECURITY_GROUP_NAME="jenkins-devsecops-sg"
readonly INSTANCE_TYPE="t3.micro"
readonly ROLE_NAME="EC2ShutdownRole"
readonly PROFILE_NAME="EC2ShutdownProfile"
readonly TAG_NAME="Jenkins-DevSecOps"
readonly S3_BUCKET_NAME="jenkins-sonarqube-binaries-${RANDOM}"
readonly NEXUS_URL="https://download.sonatype.com/nexus/3/nexus-3.77.2-02-unix.tar.gz"

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
            --description "SG for Jenkins, Nexus, SonarQube POC" \
            --query 'GroupId' --output text --region "$AWS_REGION")

        log "Fetching your public IP address..."
        MY_IP=$(curl -s http://checkip.amazonaws.com)
        MY_IP_CIDR="${MY_IP}/32"
        log "Restricting inbound access to your IP: $MY_IP_CIDR"

        log "Opening inbound ports..."
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

    # Give wider permissions to the S3 bucket role to avoid 403 errors
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
        # Verify if the zip exists
        if aws s3 ls "s3://$EXISTING_BUCKET/sonarqube.zip" --region "$AWS_REGION" >/dev/null 2>&1; then
            log "The zip file already exists in the s3://$S3_BUCKET_NAME/ S3 bucket and it is accessible. We skip the upload to save costs."
            export ACTIVE_S3_BUCKET="$EXISTING_BUCKET"
            return 0
        else
            log "s3://$S3_BUCKET_NAME/ exists, but the file is not accessible, possibly 403 error. We will create a new bucket instead."
        fi
    fi

    log "Creating a new S3 bucket temporarily: $S3_BUCKET_NAME..."
    if [ "$AWS_REGION" == "us-east-1" ]; then
        aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" >/dev/null
    else
        aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
    fi

    log "Uploading the SonarQube zip to the a s3://$S3_BUCKET_NAME/ bucket..."
    aws s3 cp sonarqube-26.9.0.129388.zip "s3://$S3_BUCKET_NAME/sonarqube.zip"
    export ACTIVE_S3_BUCKET="$S3_BUCKET_NAME"
}

generate_user_data() {
    cat << EOF > user-data.sh
#!/bin/bash
set -x
exec > >(tee /var/log/user-data.log|logger) 2>&1

log() { echo "[User-Data] \$1"; }

log "Configuring 2GB Swap space for t3.micro..."
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

log "Updating system packages and installing prerequisites (unzip, curl, net-tools)..."
apt-get update -y && apt-get upgrade -y
apt-get install -y fontconfig openjdk-21-jre unzip curl net-tools groff

log "Installing official AWS CLI v2..."
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws

log "Downloading SonarQube from S3 bucket..."
useradd -r -M -d /opt/sonarqube -s /bin/bash sonarqube || true
aws s3 cp s3://$ACTIVE_S3_BUCKET/sonarqube.zip /tmp/sonarqube.zip --region $AWS_REGION
unzip -q /tmp/sonarqube.zip -d /tmp
# Aseguramos mover el contenido exacto y dar permisos de ejecución al script de arranque
rm -rf /opt/sonarqube
mv /tmp/sonarqube-* /opt/sonarqube
chown -R sonarqube:sonarqube /opt/sonarqube
chmod +x /opt/sonarqube/bin/linux-x86-64/sonar.sh
rm -f /tmp/sonarqube.zip

log "Installing Jenkins prerequisites and Jenkins..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key | tee /etc/apt/keyrings/jenkins-keyring.asc > /dev/null
echo deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/ | tee /etc/apt/sources.list.d/jenkins.list > /dev/null
apt-get update -y && apt-get install -y jenkins
systemctl enable --now jenkins

log "Installing Nexus prerequisites (Java 17) and Nexus OSS..."
apt-get install -y openjdk-17-jre
cd /opt
useradd -r -M -d /opt/nexus -s /bin/false nexus || true
NEXUS_URL="https://download.sonatype.com/nexus/3/nexus-3.77.2-02-unix.tar.gz"
wget "$NEXUS_URL" -O nexus.tar.gz || wget "https://download.sonatype.com/nexus/3/latest-unix.tar.gz" -O nexus.tar.gz
tar -xvf nexus.tar.gz && rm -rf nexus && mv nexus-3* nexus && chown -R nexus:nexus /opt/nexus

# Configuring nexus user and forcing Java 17 usage to avoid install4j restrictions
echo 'run_as_user="nexus"' > /opt/nexus/bin/nexus.rc
echo 'INSTALL4J_JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"' >> /opt/nexus/bin/nexus.rc
echo '-Dinstall4j.javaHome=/usr/lib/jvm/java-17-openjdk-amd64' >> /opt/nexus/bin/nexus.vmoptions

ln -sf /opt/nexus/bin/nexus /etc/init.d/nexus
update-rc.d nexus defaults && systemctl start nexus
sudo chown -R nexus:nexus /opt/nexus
sudo chown -R nexus:nexus /opt/sonatype-work || true
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
systemctl enable --now sonarqube

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

systemctl daemon-reload
systemctl enable --now sonarqube

log "Setting up daily shutdown cron job..."
INSTANCE_ID=\$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=\$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
echo "0 0 * * * root aws ec2 stop-instances --instance-ids \$INSTANCE_ID --region \$REGION" > /etc/cron.d/daily-shutdown
chmod 644 /etc/cron.d/daily-shutdown
log "Provisioning complete!"
EOF
}

provision() {
    SG_ID=$(create_security_group)
    setup_iam_profile
    upload_binary_to_s3
    generate_user_data

    log "Fetching latest Ubuntu AMI..."
    AMI_ID=$(aws ec2 describe-images --region "$AWS_REGION" --owners 099720109477 --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" "Name=state,Values=available" --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)

    log "Waiting 10 seconds for IAM profile propagation to EC2..."
    sleep 10

    log "Launching EC2 Instance with 30GB gp3 storage..."
    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --count 1 \
        --instance-type "$INSTANCE_TYPE" \
        --security-group-ids "$SG_ID" \
        --iam-instance-profile "Name=$PROFILE_NAME" \
        --user-data file://user-data.sh \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG_NAME}]" \
        --query 'Instances[0].InstanceId' --output text --region "$AWS_REGION")

    log "Successfully provisioned instance ID: $INSTANCE_ID"
}

teardown() {
    log "Locating EC2 Instance with tag Name=$TAG_NAME..."
    INSTANCE_ID=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$TAG_NAME" "Name=instance-state-name,Values=pending,running,stopped,stopping" \
        --query "Reservations[*].Instances[*].InstanceId" --output text --region "$AWS_REGION" 2>/dev/null || true)

    if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
        log "Terminating instance $INSTANCE_ID..."
        aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" >/dev/null
        log "Waiting for instance termination..."
        aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
    else
        log "No active instance found with tag $TAG_NAME."
    fi

    EXISTING_BUCKET=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, 'jenkins-sonarqube-binaries-')].Name" --output text 2>/dev/null || true)
    if [ -n "$EXISTING_BUCKET" ] && [ "$EXISTING_BUCKET" != "None" ]; then
        read -p "Do you want to delete '$EXISTING_BUCKET' and content? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log "Deleting bucket and content: $EXISTING_BUCKET"
            aws s3 rm "s3://$EXISTING_BUCKET" --recursive >/dev/null || true
            aws s3api delete-bucket --bucket "$EXISTING_BUCKET" --region "$AWS_REGION" >/dev/null || true
        else
            log "Retaining bucket and content: $EXISTING_BUCKET"
        fi
    else
        log "$EXISTING_BUCKET bucket doesn't exist."
    fi

    log "Deleting Security Group..."
    SG_ID=$(aws ec2 describe-security-groups --group-names "$SECURITY_GROUP_NAME" --region "$AWS_REGION" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
    if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
        aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION" >/dev/null || log "Warning: Could not delete security group immediately (may require dependency release)."
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