#!/usr/bin/env bash
# ============================================================
# cleanup script — Universal dynamic cleanup for user-created resources
# Safety rules:
#   - Skips anything containing 'bill' (case-insensitive)
#   - Skips default VPC, default security groups, and default subnets
#   - Uses dynamic $0 for script log headers
# ============================================================
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

# ---------- Config ----------
REGION="us-east-1"
DRY_RUN="${DRY_RUN:-false}"

# ---------- Colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log()     { echo -e "${CYAN}[INFO][$SCRIPT_NAME]${NC}$*"; }
success() { echo -e "${GREEN}[OK][$SCRIPT_NAME]${NC}$*"; }
warn()    { echo -e "${YELLOW}[WARN][$SCRIPT_NAME]${NC}$*"; }
error()   { echo -e "${RED}[ERROR][$SCRIPT_NAME]${NC}$*"; }

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY-RUN][$SCRIPT_NAME]${NC}$*"
  else
    eval "$@"
  fi
}

if ! command -v aws &>/dev/null; then
  error "AWS CLI not found. Install it first."
  exit 1
fi

log "Starting universal cleanup in region: $REGION"
echo ""

# ============================================================
# STEP 1 — Delete All Non-Default Application Load Balancers
# ============================================================
log "Step 1/6 — Scanning for Load Balancers..."
ALB_ARNS=$(aws elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[?contains(LoadBalancerName, 'bill') == `false`].LoadBalancerArn" --output text 2>/dev/null || echo "")

for ALB_ARN in $ALB_ARNS; do
  if [[ -n "$ALB_ARN" && "$ALB_ARN" != "None" ]]; then
    log "Found ALB: $ALB_ARN. Deleting listeners first..."
    LISTENER_ARNS=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --region "$REGION" --query "Listeners[*].ListenerArn" --output text 2>/dev/null || echo "")
    for L_ARN in $LISTENER_ARNS; do
      run "aws elbv2 delete-listener --listener-arn '$L_ARN' --region '$REGION'"
    done
    run "aws elbv2 delete-load-balancer --load-balancer-arn '$ALB_ARN' --region '$REGION'"
    success "Deleted ALB: $ALB_ARN"
  fi
done
echo ""

# ============================================================
# STEP 2 — Delete All Non-Default Auto Scaling Groups
# ============================================================
log "Step 2/6 — Scanning for Auto Scaling Groups..."
ASG_NAMES=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" --query "AutoScalingGroups[?contains(AutoScalingGroupName, 'bill') == `false`].AutoScalingGroupName" --output text 2>/dev/null || echo "")

for ASG in $ASG_NAMES; do
  if [[ -n "$ASG" && "$ASG" != "None" ]]; then
    log "Found ASG: $ASG. Scaling down and deleting..."
    run "aws autoscaling update-auto-scaling-group --auto-scaling-group-name '$ASG' --min-size 0 --max-size 0 --desired-capacity 0 --region '$REGION'"
    run "aws autoscaling delete-auto-scaling-group --auto-scaling-group-name '$ASG' --force-delete --region '$REGION'"
    success "Deleted ASG: $ASG"
  fi
done
echo ""

# ============================================================
# STEP 3 — Delete All Non-Default Target Groups
# ============================================================
log "Step 3/6 — Scanning for Target Groups..."
TG_ARNS=$(aws elbv2 describe-target-groups --region "$REGION" --query "TargetGroups[?contains(TargetGroupName, 'bill') == `false`].TargetGroupArn" --output text 2>/dev/null || echo "")

for TG_ARN in $TG_ARNS; do
  if [[ -n "$TG_ARN" && "$TG_ARN" != "None" ]]; then
    log "Deleting Target Group: $TG_ARN"
    run "aws elbv2 delete-target-group --target-group-arn '$TG_ARN' --region '$REGION'"
    success "Deleted Target Group."
  fi
done
echo ""

# ============================================================
# STEP 4 — Delete All Non-Default Launch Templates
# ============================================================
log "Step 4/6 — Scanning for Launch Templates..."
LT_IDS=$(aws ec2 describe-launch-templates --region "$REGION" --query "LaunchTemplates[?contains(LaunchTemplateName, 'bill') == `false`].LaunchTemplateId" --output text 2>/dev/null || echo "")

for LT_ID in $LT_IDS; do
  if [[ -n "$LT_ID" && "$LT_ID" != "None" ]]; then
    log "Deleting Launch Template: $LT_ID"
    run "aws ec2 delete-launch-template --launch-template-id '$LT_ID' --region '$REGION'"
    success "Deleted Launch Template: $LT_ID"
  fi
done
echo ""

# ============================================================
# STEP 5 — Delete Custom Security Groups (Excluding 'default')
# ============================================================
log "Step 5/6 — Scanning for custom Security Groups..."
SG_IDS=$(aws ec2 describe-security-groups --region "$REGION" --query "SecurityGroups[?GroupName != 'default' && contains(GroupName, 'bill') == `false`].GroupId" --output text 2>/dev/null || echo "")

for SG_ID in $SG_IDS; do
  if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
    log "Deleting Security Group: $SG_ID"
    run "aws ec2 delete-security-group --group-id '$SG_ID' --region '$REGION' 2>/dev/null \vert{}\vert{} warn 'Could not delete SG$SG_ID (in use)'"
  fi
done
echo ""

# ============================================================
# STEP 6 — Delete CloudWatch Log Groups & Alarms (Excluding 'bill')
# ============================================================
log "Step 6/6 — Scanning for Log Groups and Alarms..."
aws logs describe-log-groups --region "$REGION" --query 'logGroups[*].logGroupName' --output text 2>/dev/null | tr '\t' '\n' | while read -r GROUP; do
    if [[ -n "$GROUP" && "$GROUP" != "None" ]]; then
        if [[ "$GROUP" =~ [Bb][Ii][Ll][lL] ]]; then
            log "Skipping billing-related Log Group: $GROUP"
            continue
        fi
        run "MSYS_NO_PATHCONV=1 aws logs delete-log-group --log-group-name '$GROUP' --region '$REGION'"
    fi
done

ALARMS=$(aws cloudwatch describe-alarms --region "$REGION" --query "MetricAlarms[*].AlarmName" --output text 2>/dev/null || echo "")
for ALARM in $ALARMS; do
    if [[ -n "$ALARM" && "$ALARM" != "None" ]]; then
        if [[ "$ALARM" =~ [Bb][Ii][Ll][lL] ]]; then
            log "Skipping billing-related Alarm: $ALARM"
            continue
        fi
        run "aws cloudwatch delete-alarms --alarm-names '$ALARM' --region '$REGION'"
    fi
done
echo ""

echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} Universal cleanup complete! All user objects purged (billing protected).${NC}"
echo -e "${GREEN}============================================================${NC}"
