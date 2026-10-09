#!/bin/bash

# Strict error handling
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

# ============================================================
# CONFIGURABLE VARIABLES (Supports environment variables)
# ============================================================
AWS_REGION="${AWS_REGION:-us-east-1}"
SG_NAME="${SG_NAME:-health-web-sg}"
SG_DESC="${SG_DESC:-Security group for Health website behind Load Balancer}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
INSTANCE_NAME="${INSTANCE_NAME:-Health-Web-Server}"
USER_DATA_FILE="multios-web-setup.sh"
IAM_ROLE_NAME="EC2CloudWatchAgentRole"
IAM_PROFILE_NAME="EC2CloudWatchAgentProfile"

# Option to decide if you want to create an AMI at the end (true / false)
CREATE_AMI="${CREATE_AMI:-false}"                                        
AMI_NAME="${INSTANCE_NAME}-AMI-$(date +%Y%m%d-%H%M%S)"

# ============================================================
# 1. INFORMATIVE TEXT / HELP (Always displayed at startup)
# ============================================================
echo "============================================================="
echo " SCRIPT USAGE: ./$SCRIPT_NAME"
echo "============================================================="
echo "This script automates IAM role creation, security configuration,"
echo "EC2 instance deployment with Apache (httpd), and CloudWatch agent setup."
echo ""
echo "EXAMPLES OF EXECUTION WITH PARAMETERS:"
echo "  1. Standard execution (default values):"
echo "     ./$SCRIPT_NAME"
echo ""
echo "  2. Execution passing custom variables inline:"
echo "     INSTANCE_NAME=\"MyServer\" SG_NAME=\"my-sg\" CREATE_AMI=\"true\" ./$SCRIPT_NAME"
echo "============================================================="
echo ""

# ============================================================
# 2. DISPLAY PARAMETERS AND REQUEST CONFIRMATION
# ============================================================
echo "============================================================="
echo " [$SCRIPT_NAME] — DEPLOYMENT PARAMETERS SUMMARY"
echo "============================================================="
echo "  - AWS Region          : $AWS_REGION"
echo "  - Security Group Name : $SG_NAME"
echo "  - Security Group Desc : $SG_DESC"
echo "  - Instance Type       : $INSTANCE_TYPE"
echo "  - Instance Name       : $INSTANCE_NAME"
echo "  - Create AMI at end   : $CREATE_AMI"
echo "============================================================="
read -p "Do you want to continue with the deployment using these parameters? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "[$SCRIPT_NAME] Operation cancelled by user."
    exit 0
fi

echo "[$SCRIPT_NAME] Starting deployment..."

echo "[$SCRIPT_NAME] === 1. Ensuring IAM Role and Instance Profile Exist ==="
if ! aws iam get-role --role-name "$IAM_ROLE_NAME" &>/dev/null; then
    echo "[$SCRIPT_NAME] Creating IAM role: $IAM_ROLE_NAME..."
    aws iam create-role \
        --role-name "$IAM_ROLE_NAME" \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
        > /dev/null

    aws iam attach-role-policy \
        --role-name "$IAM_ROLE_NAME" \
        --policy-arn "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"

    echo "[$SCRIPT_NAME] IAM role created and policy attached."
else
    echo "[$SCRIPT_NAME] IAM role already exists."
fi

if ! aws iam get-instance-profile --instance-profile-name "$IAM_PROFILE_NAME" &>/dev/null; then
    echo "[$SCRIPT_NAME] Creating Instance Profile: $IAM_PROFILE_NAME..."
    aws iam create-instance-profile --instance-profile-name "$IAM_PROFILE_NAME" > /dev/null
    aws iam add-role-to-instance-profile \
        --instance-profile-name "$IAM_PROFILE_NAME" \
        --role-name "$IAM_ROLE_NAME"
    echo "[$SCRIPT_NAME] Waiting 10 seconds for IAM profile propagation..."
    sleep 10
else
    echo "[$SCRIPT_NAME] Instance profile already exists."
fi

echo "[$SCRIPT_NAME] === 2. Fetching latest Amazon Linux 2023 AMI ID ==="
AMI_ID=$(aws ec2 describe-images \
    --region "$AWS_REGION" \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text)

echo "[$SCRIPT_NAME] Selected AMI ID: $AMI_ID"

echo "[$SCRIPT_NAME] === 3. Creating Security Group (if it doesn't exist) ==="
SG_ID=$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --group-names "$SG_NAME" \
    --query "SecurityGroups[0].GroupId" \
    --output text 2>/dev/null || true)

if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
    SG_ID=$(aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name "$SG_NAME" \
        --description "$SG_DESC" \
        --query "GroupId" \
        --output text)
    echo "[$SCRIPT_NAME] Security group created with ID: $SG_ID"
else
    echo "[$SCRIPT_NAME] Security group already exists with ID: $SG_ID"
fi

echo "[$SCRIPT_NAME] === 4. Configuring Ingress Rules (HTTP & SSH) ==="
aws ec2 authorize-security-group-ingress \
    --region "$AWS_REGION" \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0 2>/dev/null || echo "[$SCRIPT_NAME] HTTP rule already exists."

MY_IP=$(curl -s https://checkip.amazonaws.com/)
echo "[$SCRIPT_NAME] Detected current public IP: $MY_IP"

aws ec2 authorize-security-group-ingress \
    --region "$AWS_REGION" \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 22 \
    --cidr "$MY_IP/32" 2>/dev/null || echo "[$SCRIPT_NAME] SSH rule for your IP already exists."

echo "[$SCRIPT_NAME] === 5. Creating User Data Script File ==="
cat << 'EOF' > "$USER_DATA_FILE"
#!/bin/bash
URL='https://www.tooplate.com/zip-templates/2098_health.zip'
ART_NAME='2098_health'
TEMPDIR="/tmp/webfiles"

# Define packages base once
PACKAGES="wget unzip amazon-cloudwatch-agent stress"
SVC=""

yum --help &> /dev/null
if [ $? -eq 0 ]; then
    PACKAGES="httpd $PACKAGES"
    SVC="httpd"
    sudo yum install $PACKAGES -y > /dev/null
    sudo systemctl start $SVC
    sudo systemctl enable $SVC
    mkdir -p $TEMPDIR && cd $TEMPDIR
    wget $URL > /dev/null
    unzip $ART_NAME.zip > /dev/null
    sudo cp -r $ART_NAME/* /var/www/html/
    systemctl restart $SVC
    rm -rf $TEMPDIR
else
    PACKAGES="apache2 $PACKAGES"
    SVC="apache2"
    sudo apt update
    sudo apt install $PACKAGES -y > /dev/null
    sudo systemctl start $SVC
    sudo systemctl enable $SVC
    mkdir -p $TEMPDIR && cd $TEMPDIR
    wget $URL > /dev/null
    unzip $ART_NAME.zip > /dev/null
    sudo cp -r $ART_NAME/* /var/www/html/
    systemctl restart $SVC
    rm -rf $TEMPDIR
fi

# Place Free-Tier optimized CloudWatch agent configuration for Apache httpd
sudo mkdir -p /opt/aws/amazon-cloudwatch-agent/etc
cat << 'CONFIGEOF' > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
{
  "metrics": {
    "metrics_collected": {
      "mem": {
        "measurement": [
          "mem_used_percent"
        ]
      },
      "disk": {
        "measurement": [
          "used_percent"
        ],
        "resources": [
          "/"
        ]
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/httpd/access_log",
            "log_group_name": "/aws/ec2/httpd-access-logs",
            "log_stream_name": "{instance_id}"
          },
          {
            "file_path": "/var/log/httpd/error_log",
            "log_group_name": "/aws/ec2/httpd-error-logs",
            "log_stream_name": "{instance_id}"
          }
        ]
      }
    }
  }
}
CONFIGEOF

# Wait for IMDSv2 and IAM role propagation before starting the service
echo "Waiting for IMDS and IAM role to be fully available..."
while true; do
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
    if [ -n "$TOKEN" ]; then
        ROLE_CHECK=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>/dev/null || true)
        if [ -n "$ROLE_CHECK" ] && [ "$ROLE_CHECK" != "404 - Not Found" ]; then
            echo "IAM role '$ROLE_CHECK' is active and ready."
            break
        fi
    fi
    sleep 3
done

# Enable and start the CloudWatch agent service
sudo systemctl enable amazon-cloudwatch-agent
sudo systemctl start amazon-cloudwatch-agent
EOF

echo "[$SCRIPT_NAME] === 6. Launching EC2 Instance ==="
INSTANCE_ID=$(aws ec2 run-instances \
    --region "$AWS_REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --security-group-ids "$SG_ID" \
    --iam-instance-profile "Name=$IAM_PROFILE_NAME" \
    --associate-public-ip-address \
    --user-data "file://$USER_DATA_FILE" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --query "Instances[0].InstanceId" \
    --output text)

echo "[$SCRIPT_NAME] Instance created with ID: $INSTANCE_ID. Waiting for it to run and pass checks..."

aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"

# Optional: Create an AMI if CREATE_AMI is true
if [ "$CREATE_AMI" = "true" ]; then
    echo "[$SCRIPT_NAME] Waiting for instance status checks to complete before creating AMI..."
    aws ec2 wait instance-status-ok --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
    
    echo "[$SCRIPT_NAME] Creating AMI ($AMI_NAME) from instance $INSTANCE_ID..."
    NEW_AMI_ID=$(aws ec2 create-image \
        --region "$AWS_REGION" \
        --instance-id "$INSTANCE_ID" \
        --name "$AMI_NAME" \
        --description "AMI created from $INSTANCE_NAME" \
        --no-reboot \
        --query "ImageId" \
        --output text)
    echo "[$SCRIPT_NAME] AMI creation initiated successfully. New AMI ID: $NEW_AMI_ID"
fi

echo "[$SCRIPT_NAME] === 7. Instance Details ==="
aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].{InstanceId:InstanceId, PublicIP:PublicIpAddress, PrivateIP:PrivateIpAddress, AZ:Placement.AvailabilityZone, State:State.Name, SubnetId:SubnetId, VpcId:VpcId}" \
    --output table
