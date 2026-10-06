#!/usr/bin/env bash
# ============================================================
# Script Name: aws_lab_manager.sh
# Description: Unified script with custom AMI selection, Auto Scaling Group deployment, and EFS mount reuse.
# Usage: ./aws_lab_manager.sh [spinup|cleanup|create-ami] [options]
# ============================================================

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

# ---------- Default Config ----------
AWS_REGION="${AWS_REGION:-us-east-1}"
SG_NAME="${SG_NAME:-web-app-sg}"
SG_DESC="${SG_DESC:-Security group for website behind Load Balancer}"
EFS_SG_NAME="${EFS_SG_NAME:-efs-access-sg}"
EFS_NAME="${EFS_NAME:-Custom-Web-EFS}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
INSTANCE_NAME="${INSTANCE_NAME:-Web-Server-Instance}"
INSTANCE_ID="${INSTANCE_ID:-}"
CUSTOM_AMI_ID="${CUSTOM_AMI_ID:-}"
AMI_NAME="${AMI_NAME:-MyCustomWebServer-AMI}"
NO_REBOOT="${NO_REBOOT:-true}"
USER_DATA_FILE="multios-web-setup.sh"
IAM_ROLE_NAME="EC2CloudWatchAgentRole"
IAM_PROFILE_NAME="EC2CloudWatchAgentProfile"
ASG_NAME="${ASG_NAME:-Web-App-ASG}"
LT_NAME="${LT_NAME:-Web-App-Launch-Template}"
DRY_RUN="${DRY_RUN:-false}"
ACTION=""

# ---------- Colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { echo -e "${CYAN}[INFO][$SCRIPT_NAME]${NC}      $*"; }
success() { echo -e "${GREEN}[OK][$SCRIPT_NAME]${NC}        $*"; }
warn()    { echo -e "${YELLOW}[WARN][$SCRIPT_NAME]${NC}      $*"; }
error()   { echo -e "${RED}[ERROR][$SCRIPT_NAME]${NC}    $*"; }

run() {
  if [ "$DRY_RUN" = "true" ]; then
    echo -e "${YELLOW}[DRY-RUN][$SCRIPT_NAME]${NC} $*"
  else
    eval "$@"
  fi
}

usage() {
  echo "============================================================="
  echo " USAGE EXAMPLES & OPTIONS:"
  echo "============================================================="
  echo " 1. Spin up the lab (using ASG with latest Amazon Linux 2023):"
  echo "    ./$SCRIPT_NAME spinup --region us-west-2"
  echo ""
  echo " 2. Spin up using a custom AMI ID and ASG name:"
  echo "    ./$SCRIPT_NAME spinup --ami-id ami-0123456789abcdef0 --instance-name Web-Server-01"
  echo ""
  echo " 3. Create an AMI from a running instance:"
  echo "    ./$SCRIPT_NAME create-ami --instance-id i-0123456789abcdef0 --ami-name my-golden-image"
  echo ""
  echo " 4. Run cleanup:"
  echo "    ./$SCRIPT_NAME cleanup --region us-west-2"
  echo ""
  echo " Available Options:"
  echo "    --region <region>          AWS Region (default: us-east-1)"
  echo "    --sg-name <name>           Security Group Name (default: web-app-sg)"
  echo "    --instance-type <type>     EC2 Instance Type (default: t3.micro)"
  echo "    --instance-name <name>     EC2 Instance / ASG Name tag prefix"
  echo "    --ami-id <id>              Custom AMI ID to use for spinup"
  echo "    --instance-id <id>         EC2 Instance ID for AMI creation"
  echo "    --ami-name <name>          Name for the generated AMI"
  echo "    --help                     Display this help message"
  echo "============================================================="
  exit 1
}

# ---------- Parse Arguments ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    spinup|cleanup|create-ami)
      ACTION="$1"
      shift
      ;;
    --region)
      AWS_REGION="$2"
      shift 2
      ;;
    --sg-name)
      SG_NAME="$2"
      shift 2
      ;;
    --instance-type)
      INSTANCE_TYPE="$2"
      shift 2
      ;;
    --instance-name)
      INSTANCE_NAME="$2"
      ASG_NAME="${INSTANCE_NAME}-ASG"
      LT_NAME="${INSTANCE_NAME}-LT"
      shift 2
      ;;
    --ami-id)
      CUSTOM_AMI_ID="$2"
      shift 2
      ;;
    --instance-id)
      INSTANCE_ID="$2"
      shift 2
      ;;
    --ami-name)
      AMI_NAME="$2"
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    *)
      error "Unknown option: $1"
      usage
      ;;
  esac
done

if [ -z "$ACTION" ]; then
  usage
fi

# ============================================================
# SPINUP FUNCTIONALITY (ASG DEPLOYMENT)
# ============================================================
do_spinup() {
  log "Starting deployment in region: $AWS_REGION"

  log "=== 1. Verifying IAM Role and Instance Profile ==="
  if ! aws iam get-role --role-name "$IAM_ROLE_NAME" &>/dev/null; then
    aws iam create-role \
        --role-name "$IAM_ROLE_NAME" \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
        > /dev/null
    aws iam attach-role-policy \
        --role-name "$IAM_ROLE_NAME" \
        --policy-arn "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
    aws iam attach-role-policy \
        --role-name "$IAM_ROLE_NAME" \
        --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonElasticFileSystemClientReadWrite"
    success "IAM role created and policies attached."
  else
    log "IAM role already exists. Ensuring EFS client policy is attached..."
    aws iam attach-role-policy \
        --role-name "$IAM_ROLE_NAME" \
        --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonElasticFileSystemClientReadWrite" 2>/dev/null || true
  fi

  aws iam attach-role-policy \
      --role-name "$IAM_ROLE_NAME" \
      --policy-arn "arn:aws:iam::aws:policy/AmazonElasticFileSystemFullAccess" 2>/dev/null || true

  if ! aws iam get-instance-profile --instance-profile-name "$IAM_PROFILE_NAME" &>/dev/null; then
    aws iam create-instance-profile --instance-profile-name "$IAM_PROFILE_NAME" > /dev/null
    aws iam add-role-to-instance-profile \
        --instance-profile-name "$IAM_PROFILE_NAME" \
        --role-name "$IAM_ROLE_NAME"
    sleep 10
  else
    log "Instance profile already exists."
  fi

  log "=== 2. Resolving AMI ID ==="
  if [ -n "$CUSTOM_AMI_ID" ]; then
    log "Using user-provided Custom AMI ID: $CUSTOM_AMI_ID"
    AMI_ID="$CUSTOM_AMI_ID"
  else
    log "No custom AMI provided. Fetching latest Amazon Linux 2023 AMI..."
    AMI_ID=$(aws ec2 describe-images \
      --region "$AWS_REGION" \
      --owners amazon \
      --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
      --query "sort_by(Images, &CreationDate)[-1].ImageId" \
      --output text)
    AMI_ID=$(echo "$AMI_ID" | head -n1 | xargs)
  fi
  success "Selected AMI: $AMI_ID"

  log "=== 3. Creating EC2 Security Group ==="
  SG_ID=$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --group-names "$SG_NAME" \
    --query "SecurityGroups[0].GroupId" \
    --output text 2>/dev/null || echo "")
  SG_ID=$(echo "$SG_ID" | head -n1 | xargs)

  if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
    SG_ID=$(aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name "$SG_NAME" \
        --description "$SG_DESC" \
        --query "GroupId" \
        --output text)
    SG_ID=$(echo "$SG_ID" | head -n1 | xargs)
    success "Security group created with ID: $SG_ID"
  else
    log "Security group already exists with ID: $SG_ID"
  fi

  log "=== 4. Configuring Ingress Rules (HTTP & SSH) ==="
  aws ec2 authorize-security-group-ingress \
    --region "$AWS_REGION" \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0 2>/dev/null || true

  MY_IP=$(curl -s https://checkip.amazonaws.com/)
  MY_IP=$(echo "$MY_IP" | head -n1 | xargs)

  aws ec2 authorize-security-group-ingress \
    --region "$AWS_REGION" \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 22 \
    --cidr "$MY_IP/32" 2>/dev/null || true

  log "=== 4.1. Configuring Amazon EFS (Decoupled Security Group & Mount Targets) ==="
  VPC_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$SG_ID" --query "SecurityGroups[0].VpcId" --output text)
  VPC_ID=$(echo "$VPC_ID" | head -n1 | xargs)

  VPC_CIDR=$(aws ec2 describe-vpcs --region "$AWS_REGION" --vpc-ids "$VPC_ID" --query "Vpcs[0].CidrBlock" --output text)
  VPC_CIDR=$(echo "$VPC_CIDR" | head -n1 | xargs)

  EFS_SG_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" --filters "Name=group-name,Values=$EFS_SG_NAME" "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "")
  EFS_SG_ID=$(echo "$EFS_SG_ID" | head -n1 | xargs)

  if [ -z "$EFS_SG_ID" ] || [ "$EFS_SG_ID" = "None" ]; then
    EFS_SG_ID=$(aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name "$EFS_SG_NAME" \
        --description "Security group for EFS mount targets" \
        --vpc-id "$VPC_ID" \
        --query "GroupId" \
        --output text)
    EFS_SG_ID=$(echo "$EFS_SG_ID" | head -n1 | xargs)
  fi

  aws ec2 authorize-security-group-ingress \
    --region "$AWS_REGION" \
    --group-id "$EFS_SG_ID" \
    --protocol tcp \
    --port 2049 \
    --cidr "$VPC_CIDR" 2>/dev/null || true

  EFS_ID=$(aws efs describe-file-systems --region "$AWS_REGION" --query "FileSystems[?Name=='$EFS_NAME'].FileSystemId" --output text 2>/dev/null || echo "")
  EFS_ID=$(echo "$EFS_ID" | head -n1 | xargs)

  if [ -z "$EFS_ID" ] || [ "$EFS_ID" = "None" ]; then
    EFS_ID=$(aws efs create-file-system \
        --region "$AWS_REGION" \
        --performance-mode generalPurpose \
        --throughput-mode bursting \
        --encrypted \
        --tags Key=Name,Value="$EFS_NAME" \
        --query "FileSystemId" \
        --output text)
    EFS_ID=$(echo "$EFS_ID" | head -n1 | xargs)

    while true; do
        STATE=$(aws efs describe-file-systems --region "$AWS_REGION" --file-system-id "$EFS_ID" --query "FileSystems[0].LifeCycleState" --output text 2>/dev/null || echo "deleted")
        STATE=$(echo "$STATE" | head -n1 | xargs)
        if [ "$STATE" = "available" ]; then
            break
        fi
        sleep 5
    done
  fi

  SUBNET_IDS=$(aws ec2 describe-subnets --region "$AWS_REGION" --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[*].SubnetId" --output text)
  for SUBNET_ID in $SUBNET_IDS; do
    EXISTING_MT=$(aws ec2 describe-mount-targets --region "$AWS_REGION" --file-system-id "$EFS_ID" --query "MountTargets[?SubnetId=='$SUBNET_ID'].MountTargetId" --output text 2>/dev/null || echo "")
    EXISTING_MT=$(echo "$EXISTING_MT" | head -n1 | xargs)
    if [ -z "$EXISTING_MT" ] || [ "$EXISTING_MT" = "None" ]; then
      log "Creating mount target for subnet $SUBNET_ID..."
      aws efs create-mount-target --region "$AWS_REGION" --file-system-id "$EFS_ID" --subnet-id "$SUBNET_ID" --security-groups "$EFS_SG_ID" > /dev/null 2>/dev/null || log "Mount target for subnet $SUBNET_ID already exists. Re-using."
    else
      log "Mount target already exists for subnet $SUBNET_ID (ID: $EXISTING_MT). Re-using."
    fi
  done

  log "Waiting for all EFS mount targets to become fully available..."
  while true; do
    ALL_READY=true
    for SUBNET_ID in $SUBNET_IDS; do
      MT_STATE=$(aws efs describe-mount-targets --region "$AWS_REGION" --file-system-id "$EFS_ID" --query "MountTargets[?SubnetId=='$SUBNET_ID'].LifeCycleState" --output text 2>/dev/null || echo "")
      MT_STATE=$(echo "$MT_STATE" | head -n1 | xargs)
      if [ "$MT_STATE" != "available" ]; then
        ALL_READY=false
        break
      fi
    done

    if [ "$ALL_READY" = "true" ]; then
      success "All EFS mount targets are now available!"
      break
    fi
    sleep 5
  done

  log "=== 5. Generating setup script ==="
  cat << 'EOF' > "$USER_DATA_FILE"
#!/bin/bash
URL='https://www.tooplate.com/zip-templates/2098_health.zip'
ART_NAME='2098_health'
TEMPDIR="/tmp/webfiles"
EFS_ID="__EFS_ID_PLACEHOLDER__"
REGION="__REGION_PLACEHOLDER__"

PACKAGES="wget unzip amazon-cloudwatch-agent stress amazon-efs-utils nfs-utils python3-pip"
SVC=""

yum --help &> /dev/null
if [ $? -eq 0 ]; then
    PACKAGES="httpd $PACKAGES"
    SVC="httpd"
    sudo yum install $PACKAGES -y > /dev/null
    sudo pip3 install botocore > /dev/null 2>&1 || true
    sudo systemctl start $SVC
    sudo systemctl enable $SVC
else
    PACKAGES="apache2 $PACKAGES"
    SVC="apache2"
    sudo apt update
    sudo apt install $PACKAGES -y > /dev/null
    sudo pip3 install botocore > /dev/null 2>&1 || true
    sudo systemctl start $SVC
    sudo systemctl enable $SVC
fi

sudo mkdir -p /mnt/efs
sudo mount -t efs -o tls "$EFS_ID:/." /mnt/efs
sudo mkdir -p /mnt/efs/html /mnt/efs/logs

if [ ! "$(ls -A /mnt/efs/html)" ]; then
    mkdir -p $TEMPDIR && cd $TEMPDIR
    wget $URL > /dev/null
    unzip $ART_NAME.zip > /dev/null
    sudo cp -r $ART_NAME/* /mnt/efs/html/
    rm -rf $TEMPDIR
fi

sudo systemctl stop $SVC
if [ -d /var/log/httpd ]; then
    sudo cp -r /var/log/httpd/* /mnt/efs/logs/ 2>/dev/null || true
    sudo rm -rf /var/log/httpd
elif [ -d /var/log/apache2 ]; then
    sudo cp -r /var/log/apache2/* /mnt/efs/logs/ 2>/dev/null || true
    sudo rm -rf /var/log/apache2
fi

sudo mkdir -p /var/log/httpd
sudo rm -rf /var/www/html
sudo mkdir -p /var/www/html

echo "$EFS_ID:/ /mnt/efs efs defaults,_netdev,tls 0 0" | sudo tee -a /etc/fstab
echo "/mnt/efs/html /var/www/html none bind,_netdev 0 0" | sudo tee -a /etc/fstab
echo "/mnt/efs/logs /var/log/httpd none bind,_netdev 0 0" | sudo tee -a /etc/fstab

sudo mount -a
sudo chown -R apache:apache /mnt/efs/html /mnt/efs/logs 2>/dev/null || sudo chown -R www-data:www-data /mnt/efs/html /mnt/efs/logs 2>/dev/null || true

sudo systemctl start $SVC
sudo systemctl restart $SVC

sudo mkdir -p /opt/aws/amazon-cloudwatch-agent/etc
cat << 'CONFIGEOF' > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
{
  "metrics": {
    "metrics_collected": {
      "mem": { "measurement": ["mem_used_percent"] },
      "disk": { "measurement": ["used_percent"], "resources": ["/"] }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "/var/log/httpd/access_log", "log_group_name": "/aws/ec2/httpd-access-logs", "log_stream_name": "{instance_id}" },
          { "file_path": "/var/log/httpd/error_log", "log_group_name": "/aws/ec2/httpd-error-logs", "log_stream_name": "{instance_id}" }
        ]
      }
    }
  }
}
CONFIGEOF

sudo systemctl enable amazon-cloudwatch-agent
sudo systemctl start amazon-cloudwatch-agent
EOF

  sed -i "s/__EFS_ID_PLACEHOLDER__/$EFS_ID/g" "$USER_DATA_FILE"
  sed -i "s/__REGION_PLACEHOLDER__/$AWS_REGION/g" "$USER_DATA_FILE"

  # Codificar User-Data en Base64 para el Launch Template
  USER_DATA_B64=$(base64 -w 0 "$USER_DATA_FILE" 2>/dev/null || base64 "$USER_DATA_FILE" | tr -d '\r\n')

  log "=== 6. Creating Launch Template ==="
  # Comprobar si ya existe el template para actualizarlo o crearlo limpio
  aws ec2 delete-launch-template --region "$AWS_REGION" --launch-template-name "$LT_NAME" 2>/dev/null || true

  aws ec2 create-launch-template \
    --region "$AWS_REGION" \
    --launch-template-name "$LT_NAME" \
    --launch-template-data "{
      \"ImageId\": \"$AMI_ID\",
      \"InstanceType\": \"$INSTANCE_TYPE\",
      \"SecurityGroupIds\": [\"$SG_ID\"],
      \"IamInstanceProfile\": {\"Name\": \"$IAM_PROFILE_NAME\"},
      \"UserData\": \"$USER_DATA_B64\"
    }" > /dev/null
  success "Launch Template '$LT_NAME' created successfully."

  log "=== 7. Creating Auto Scaling Group (ASG) ==="
  # Eliminar ASG previo si existiera en un despliegue anterior
  if aws autoscaling describe-auto-scaling-groups --region "$AWS_REGION" --auto-scaling-group-names "$ASG_NAME" --query "AutoScalingGroups[0].AutoScalingGroupName" --output text 2>/dev/null | grep -q "$ASG_NAME"; then
    log "Existing ASG found. Deleting before re-creation..."
    aws autoscaling update-auto-scaling-group --region "$AWS_REGION" --auto-scaling-group-name "$ASG_NAME" --min-size 0 --max-size 0 --desired-capacity 0 2>/dev/null || true
    sleep 5
    aws autoscaling delete-auto-scaling-group --region "$AWS_REGION" --auto-scaling-group-name "$ASG_NAME" --force-delete 2>/dev/null || true
    sleep 10
  fi

  # Convertir subredes en formato separado por comas para el ASG
  SUBNET_IDS_CSV=$(echo "$SUBNET_IDS" | xargs | tr ' ' ',')

  aws autoscaling create-auto-scaling-group \
    --region "$AWS_REGION" \
    --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateName=$LT_NAME,Version=\$Latest" \
    --min-size 1 \
    --max-size 3 \
    --desired-capacity 1 \
    --vpc-zone-identifier "$SUBNET_IDS_CSV" \
    --tags "Key=Name,Value=$INSTANCE_NAME,PropagateAtLaunch=true"

  success "Auto Scaling Group '$ASG_NAME' created successfully!"
  success "Deployment completed via ASG! Instances are spinning up automatically."
}

# ============================================================
# CREATE AMI FUNCTIONALITY
# ============================================================
do_create_ami() {
  if [ -z "$INSTANCE_ID" ]; then
    error "Instance ID is required to create an AMI."
    echo "Usage example: ./$SCRIPT_NAME create-ami --instance-id i-0123456789abcdef0 --ami-name my-custom-ami"
    exit 1
  fi

  log "Starting AMI creation from instance: $INSTANCE_ID in region: $AWS_REGION"
  log "AMI Name: $AMI_NAME"

  AMI_CMD="aws ec2 create-image --region \"$AWS_REGION\" --instance-id \"$INSTANCE_ID\" --name \"$AMI_NAME-$INSTANCE_ID\" --description \"Created by aws_lab_manager.sh from instance $INSTANCE_ID\""

  if [ "$NO_REBOOT" = "true" ]; then
    AMI_CMD="$AMI_CMD --no-reboot"
  fi

  NEW_AMI_ID=$(eval "$AMI_CMD --query 'ImageId' --output text")
  NEW_AMI_ID=$(echo "$NEW_AMI_ID" | head -n1 | xargs)

  success "AMI creation initiated successfully!"
  success "Generated AMI ID: $NEW_AMI_ID"
  log "Waiting for the AMI to become available (this may take a few minutes)..."

  aws ec2 wait image-available --region "$AWS_REGION" --image-ids "$NEW_AMI_ID"
  success "AMI $NEW_AMI_ID is now available and ready to use!"
}

# ============================================================
# CLEANUP FUNCTIONALITY
# ============================================================
do_cleanup() {
  log "Starting universal cleanup in region: $AWS_REGION"

  log "Step 0/9 — Deregistering custom/user AMIs..."
  AMI_IDS=$(aws ec2 describe-images --region "$AWS_REGION" --owners self --query "Images[*].ImageId" --output text 2>/dev/null || echo "")
  for AMI_ID_ITEM in $AMI_IDS; do
    if [ -n "$AMI_ID_ITEM" ] && [ "$AMI_ID_ITEM" != "None" ]; then
      run "aws ec2 deregister-image --image-id '$AMI_ID_ITEM' --region '$AWS_REGION'"
      success "-> Deregistered AMI ID: $AMI_ID_ITEM"
    fi
  done

  log "Step 1/9 — Finding and deleting Auto Scaling Groups..."
  ASG_NAMES=$(aws autoscaling describe-auto-scaling-groups --region "$AWS_REGION" --query "AutoScalingGroups[*].AutoScalingGroupName" --output text 2>/dev/null || echo "")
  for ASG in $ASG_NAMES; do
    if [ -n "$ASG" ] && [ "$ASG" != "None" ]; then
      run "aws autoscaling update-auto-scaling-group --auto-scaling-group-name '$ASG' --min-size 0 --max-size 0 --desired-capacity 0 --region '$AWS_REGION'"
      sleep 5
      run "aws autoscaling delete-auto-scaling-group --auto-scaling-group-name '$ASG' --force-delete --region '$AWS_REGION'"
      success "-> Deleted ASG: $ASG"
    fi
  done

  log "Step 2/9 — Finding and deleting Launch Templates..."
  LT_INFO=$(aws ec2 describe-launch-templates --region "$AWS_REGION" --query "LaunchTemplates[*].[LaunchTemplateId, LaunchTemplateName]" --output text 2>/dev/null || echo "")
  while read -r LT_ID LT_NAMEREF; do
    if [ -n "$LT_ID" ] && [ "$LT_ID" != "None" ]; then
      run "aws ec2 delete-launch-template --launch-template-id '$LT_ID' --region '$AWS_REGION'"
      success "-> Deleted Launch Template: $LT_NAMEREF"
    fi
  done <<< "$LT_INFO"

  log "Step 3/9 — Terminating any remaining active EC2 instances..."
  INSTANCE_INFO=$(aws ec2 describe-instances --region "$AWS_REGION" --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[*].Instances[*].[InstanceId, Tags[?Key=='Name']|[0].Value]" --output text 2>/dev/null || echo "")
  while read -r INSTANCE_ID_ITEM INSTANCE_TAG; do
    if [ -n "$INSTANCE_ID_ITEM" ] && [ "$INSTANCE_ID_ITEM" != "None" ]; then
      run "aws ec2 terminate-instances --instance-ids '$INSTANCE_ID_ITEM' --region '$AWS_REGION'"
      success "-> Terminated EC2 Instance ID: $INSTANCE_ID_ITEM"
    fi
  done <<< "$INSTANCE_INFO"

  log "Step 4/9 — Deleting EFS File Systems and Mount Targets..."
  EFS_INFO=$(aws efs describe-file-systems --region "$AWS_REGION" --query "FileSystems[*].[FileSystemId, to_string(Name)]" --output text 2>/dev/null || echo "")
  while read -r EFS_ID EFS_NAMEREF; do
    if [ -n "$EFS_ID" ] && [ "$EFS_ID" != "None" ]; then
      MT_IDS=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" --region "$AWS_REGION" --query "MountTargets[*].MountTargetId" --output text 2>/dev/null || echo "")
      for MT_ID in $MT_IDS; do
        if [ -n "$MT_ID" ] && [ "$MT_ID" != "None" ]; then
          run "aws efs delete-mount-target --mount-target-id '$MT_ID' --region '$AWS_REGION'"
        fi
      done

      if [ "$DRY_RUN" != "true" ]; then
        log "Waiting for mount targets of EFS $EFS_ID to delete..."
        sleep 15
      fi

      run "aws efs delete-file-system --file-system-id '$EFS_ID' --region '$AWS_REGION'" || true
      success "-> Deleted EFS File System ID: $EFS_ID"
    fi
  done <<< "$EFS_INFO"

  log "Step 5/9 — Finding and deleting Load Balancers..."
  ALB_INFO=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --query "LoadBalancers[*].[LoadBalancerArn, LoadBalancerName]" --output text 2>/dev/null || echo "")
  while read -r ALB_ARN ALB_NAMEREF; do
    if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
      LISTENER_ARNS=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --region "$AWS_REGION" --query "Listeners[*].ListenerArn" --output text 2>/dev/null || echo "")
      for L_ARN in $LISTENER_ARNS; do
        if [ -n "$L_ARN" ] && [ "$L_ARN" != "None" ]; then
          run "aws elbv2 delete-listener --listener-arn '$L_ARN' --region '$AWS_REGION'"
        fi
      done
      run "aws elbv2 delete-load-balancer --load-balancer-arn '$ALB_ARN' --region '$AWS_REGION'"
      success "-> Deleted Load Balancer: $ALB_NAMEREF"
    fi
  done <<< "$ALB_INFO"

  log "Step 6/9 — Finding and deleting Target Groups..."
  TG_INFO=$(aws elbv2 describe-target-groups --region "$AWS_REGION" --query "TargetGroups[*].[TargetGroupArn, TargetGroupName]" --output text 2>/dev/null || echo "")
  while read -r TG_ARN TG_NAMEREF; do
    if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then
      run "aws elbv2 delete-target-group --target-group-arn '$TG_ARN' --region '$AWS_REGION'"
      success "-> Deleted Target Group: $TG_NAMEREF"
    fi
  done <<< "$TG_INFO"

  log "Step 7/9 — Removing all ingress/egress rules and deleting Security Groups..."
  SG_IDS=$(aws ec2 describe-security-groups --region "$AWS_REGION" --query "SecurityGroups[?GroupName != 'default'].GroupId" --output text 2>/dev/null || echo "")

  for SG_ID in $SG_IDS; do
    if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
      log "Revoking rules for Security Group: $SG_ID"
      INBOUND_RULES=$(aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$SG_ID" --query "SecurityGroups[0].IpPermissions" --output json 2>/dev/null || echo "[]")
      if [ "$INBOUND_RULES" != "[]" ] && [ -n "$INBOUND_RULES" ]; then
        aws ec2 revoke-security-group-ingress --region "$AWS_REGION" --group-id "$SG_ID" --ip-permissions "$INBOUND_RULES" 2>/dev/null || true
      fi
      OUTBOUND_RULES=$(aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$SG_ID" --query "SecurityGroups[0].IpPermissionsEgress" --output json 2>/dev/null || echo "[]")
      if [ "$OUTBOUND_RULES" != "[]" ] && [ -n "$OUTBOUND_RULES" ]; then
        aws ec2 revoke-security-group-egress --region "$AWS_REGION" --group-id "$SG_ID" --ip-permissions "$OUTBOUND_RULES" 2>/dev/null || true
      fi
    fi
  done

  sleep 10

  for SG_ID in $SG_IDS; do
    if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
      for i in {1..5}; do
        if aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION" 2>/dev/null; then
          success "-> Deleted Security Group ID: $SG_ID"
          break
        else
          sleep 5
        fi
      done
    fi
  done

  log "Step 8/9 — Cleaning up CloudWatch logs..."
  aws logs describe-log-groups --region "$AWS_REGION" --query 'logGroups[*].logGroupName' --output text 2>/dev/null | tr '\t' '\n' | while read -r GROUP; do
      if [ -n "$GROUP" ] && [ "$GROUP" != "None" ]; then
          run "MSYS_NO_PATHCONV=1 aws logs delete-log-group --log-group-name '$GROUP' --region '$AWS_REGION'" 2>/dev/null || true
      fi
  done

  success "Universal cleanup completed successfully!"
}

# ---------- Execution Controller with Confirmation ----------
case "$ACTION" in
  spinup)
    for arg in "$@"; do
      if [ "$arg" = "--instance-name" ]; then
        CLI_INSTANCE_NAME_PROMPTED=true
      fi
    done

    if [ -z "${CLI_INSTANCE_NAME_PROMPTED:-}" ]; then
      read -p "Enter a choice for the EC2 / ASG Name Prefix (default: Web-Server-Instance): " USER_INPUT_NAME
      if [ -n "$USER_INPUT_NAME" ]; then
        INSTANCE_NAME="$USER_INPUT_NAME"
        ASG_NAME="${INSTANCE_NAME}-ASG"
        LT_NAME="${INSTANCE_NAME}-LT"
      fi
    fi

    echo "============================================================="
    echo " CONFIGURATION PARAMETERS (SPINUP VIA ASG):"
    echo " Region:            $AWS_REGION"
    echo " Security Group:    $SG_NAME"
    echo " EFS Name:          $EFS_NAME"
    echo " Instance Type:     $INSTANCE_TYPE"
    echo " ASG Name:          $ASG_NAME"
    echo " Launch Template:   $LT_NAME"
    echo " Custom AMI ID:     ${CUSTOM_AMI_ID:-[Amazon Linux 2023 por defecto]}"
    echo "============================================================="
    read -p "Do you want to start the deployment with an Auto Scaling Group? (y/n): " choice
    case "$choice" in
      y|Y ) do_spinup;;
      * ) echo "Operation cancelled."; exit 0;;
    esac
    ;;
  create-ami)
    echo "============================================================="
    echo " CONFIGURATION PARAMETERS (CREATE AMI):"
    echo " Region:            $AWS_REGION"
    echo " Instance ID:       $INSTANCE_ID"
    echo " AMI Name:          $AMI_NAME"
    echo "============================================================="
    read -p "Do you want to create an AMI from this instance? (y/n): " choice
    case "$choice" in
      y|Y ) do_create_ami;;
      * ) echo "Operation cancelled."; exit 0;;
    esac
    ;;
  cleanup)
    echo "============================================================="
    echo " CONFIGURATION PARAMETERS (CLEANUP):"
    echo " Region:            $AWS_REGION"
    echo " Security Group:    $SG_NAME"
    echo " EFS Name:          $EFS_NAME"
    echo "============================================================="
    read -p "Do you want to start the cleanup of all resources including ASG and LT? (y/n): " choice
    case "$choice" in
      y|Y ) do_cleanup;;
      * ) echo "Operation cancelled."; exit 0;;
    esac
    ;;
  *)
    error "Unknown action: $ACTION"
    usage
    ;;
esac
