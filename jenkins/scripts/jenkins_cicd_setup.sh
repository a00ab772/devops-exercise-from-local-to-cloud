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

    if ! aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
        aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null
        aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" >/dev/null
        sleep 5 # Wait for propagation
    fi
}

generate_user_data() {
    cat << 'EOF' > user-data.sh
#!/bin/bash
exec > >(tee /var/log/user-data.log|logger) 2>&1

log() { echo "[User-Data] $1"; }

log "Configuring 2GB Swap space for t3.micro..."
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

log "Updating system packages..."
apt-get update -y && apt-get upgrade -y
apt-get install -y fontconfig openjdk-17-jre

log "Installing Jenkins..."
wget -O /usr/share/keyrings/jenkins-keyring.asc https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key
echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/ | tee /etc/apt/sources.list.d/jenkins.list > /dev/null
apt-get update -y && apt-get install -y jenkins
systemctl enable jenkins && systemctl start jenkins

log "Installing Nexus OSS..."
cd /opt
useradd -r -M -d /opt/nexus -s /bin/false nexus
wget https://download.sonatype.com/nexus/3/nexus-latest-unix.tar.gz -O nexus.tar.gz
tar -xvf nexus.tar.gz && mv nexus-3* nexus && chown -R nexus:nexus /opt/nexus
echo 'run_as_user="nexus"' > /opt/nexus/bin/nexus.rc
ln -s /opt/nexus/bin/nexus /etc/init.d/nexus
update-rc.d nexus defaults && systemctl start nexus

log "Setting up daily shutdown cron job..."
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
echo "0 0 * * * root aws ec2 stop-instances --instance-ids $INSTANCE_ID --region $REGION" > /etc/cron.d/daily-shutdown
chmod 644 /etc/cron.d/daily-shutdown
log "Provisioning complete!"
EOF
}

provision() {
    SG_ID=$(create_security_group)
    setup_iam_profile
    generate_user_data

    log "Fetching latest Ubuntu AMI..."
    AMI_ID=$(aws ec2 describe-images --region "$AWS_REGION" --owners 099720109477 --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" "Name=state,Values=available" --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)

    log "Launching EC2 Instance with 30GB gp3 storage..."
    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --count 1 \
        --instance-type "$INSTANCE_TYPE" \
        --security-group-ids "$SG_ID" \
        --iam-instance-profile Name="$PROFILE_NAME" \
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
        aws iam delete-role --role-name "$ROLE_NAME" --role-name "$ROLE_NAME" >/dev/null || true
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