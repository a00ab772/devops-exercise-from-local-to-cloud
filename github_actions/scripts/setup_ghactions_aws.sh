#!/bin/bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
readonly ECR_REPO_NAME="myapprepo"
readonly ECS_CLUSTER_NAME="devops-exercise-from-local-to-cloud"
readonly ECS_SERVICE_NAME="devops-exercise-from-local-to-cloud-service"
readonly ECS_TASK_FAMILY="devops-exercise-from-local-to-cloud-task"
readonly IAM_USER_NAME="github-actions-deployer"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >&2
}

usage() {
    echo "Usage: $0 {provision|teardown}"
    echo
    echo "Options:"
    echo "  provision : Creates ECR, ECS cluster, service, task definition, and IAM user, and pushes keys & account ID to GitHub Secrets."
    echo "  teardown  : Cleans up and deletes all created AWS resources (ECS, ECR, and IAM user)."
    exit 1
}

provision() {
    # Check if GitHub CLI is installed and authenticated
    if ! command -v gh &> /dev/null; then
        log "Error: GitHub CLI ('gh') is not installed. Please install it to automatically set repository secrets."
        exit 1
    fi

    if ! gh auth status &> /dev/null; then
        log "Error: GitHub CLI is not authenticated. Run 'gh auth login' first."
        exit 1
    fi

    log "1. Creating ECR Repository: $ECR_REPO_NAME..."
    aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || \
    aws ecr create-repository --repository-name "$ECR_REPO_NAME" --region "$AWS_REGION" >/dev/null

    log "2. Creating ECS Cluster: $ECS_CLUSTER_NAME..."
    aws ecs create-cluster --cluster-name "$ECS_CLUSTER_NAME" --region "$AWS_REGION" >/dev/null || true

    log "3. Registering initial placeholder Task Definition: $ECS_TASK_FAMILY..."
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
        --region "$AWS_REGION" >/dev/null || true

    log "4. Creating ECS Service: $ECS_SERVICE_NAME..."
    DEFAULT_SUBNET=$(aws ec2 describe-subnets --filters "Name=default-for-az,Values=true" --query "Subnets[0].SubnetId" --output text --region "$AWS_REGION" 2>/dev/null || true)
    DEFAULT_SG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=default" --query "SecurityGroups[0].GroupId" --output text --region "$AWS_REGION" 2>/dev/null || true)

    if [ -n "$DEFAULT_SUBNET" ] && [ "$DEFAULT_SUBNET" != "None" ]; then
        aws ecs create-service \
            --cluster "$ECS_CLUSTER_NAME" \
            --service-name "$ECS_SERVICE_NAME" \
            --task-definition "$ECS_TASK_FAMILY" \
            --desired-count 1 \
            --launch-type FARGATE \
            --network-configuration "awsvpcConfiguration={subnets=[$DEFAULT_SUBNET],securityGroups=[$DEFAULT_SG],assignPublicIp=ENABLED}" \
            --region "$AWS_REGION" >/dev/null || true
    fi

    log "5. Creating IAM user for GitHub Actions: $IAM_USER_NAME..."
    if ! aws iam get-user --user-name "$IAM_USER_NAME" >/dev/null 2>&1; then
        aws iam create-user --user-name "$IAM_USER_NAME" >/dev/null
    fi

    log "6. Attaching required deployment policies..."
    aws iam attach-user-policy --user-name "$IAM_USER_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess >/dev/null || true
    aws iam attach-user-policy --user-name "$IAM_USER_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess >/dev/null || true

    aws iam put-user-policy --user-name "$IAM_USER_NAME" --policy-name "PassRolePolicy" --policy-document '{
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": ["iam:PassRole"],
          "Resource": "*"
        }
      ]
    }' >/dev/null || true

    log "7. Fetching AWS Account ID..."
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

    log "8. Generating Access Keys and updating GitHub Secrets automatically..."
    # Clean up any existing keys for this user to avoid hitting limits
    KEYS=$(aws iam list-access-keys --user-name "$IAM_USER_NAME" --query 'AccessKeyMetadata[*].AccessKeyId' --output text 2>/dev/null || true)
    for kid in $KEYS; do
        aws iam delete-access-key --user-name "$IAM_USER_NAME" --access-key-id "$kid" >/dev/null 2>&1 || true
    done

    # Create new access key
    CREDENTIALS=$(aws iam create-access-key --user-name "$IAM_USER_NAME" --output json)
    ACCESS_KEY_ID=$(echo "$CREDENTIALS" | python3 -c "import sys, json; print(json.load(sys.stdin)['AccessKey']['AccessKeyId'])")
    SECRET_ACCESS_KEY=$(echo "$CREDENTIALS" | python3 -c "import sys, json; print(json.load(sys.stdin)['AccessKey']['SecretAccessKey'])")

    # Set secrets using GitHub CLI (gh) client-side encryption
    echo "$ACCESS_KEY_ID" | gh secret set AWS_ACCESS_KEY_ID
    echo "$SECRET_ACCESS_KEY" | gh secret set AWS_SECRET_ACCESS_KEY
    echo "$AWS_ACCOUNT_ID" | gh secret set AWS_ACCOUNT_ID

    log "GitHub Secrets 'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY' and 'AWS_ACCOUNT_ID' successfully configured!"
    log "Provisioning complete!"
}

teardown() {
    log "1. Cleaning up ECS Service and Cluster..."
    aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$ECS_SERVICE_NAME" --desired-count 0 --region "$AWS_REGION" >/dev/null 2>&1 || true
    aws ecs delete-service --cluster "$ECS_CLUSTER_NAME" --service "$ECS_SERVICE_NAME" --force --region "$AWS_REGION" >/dev/null 2>&1 || true

    log "Waiting for ECS service to be fully deleted..."
    aws ecs wait services-inactive --cluster "$ECS_CLUSTER_NAME" --services "$ECS_SERVICE_NAME" --region "$AWS_REGION" 2>/dev/null || true

    aws ecs delete-cluster --cluster "$ECS_CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || true

    log "2. Deregistering ECS Task Definitions..."
    TASK_ARNS=$(aws ecs list-task-definitions --family-prefix "$ECS_TASK_FAMILY" --status ACTIVE --query "taskDefinitionArns" --output text --region "$AWS_REGION" 2>/dev/null || true)
    for task_arn in $TASK_ARNS; do
        if [ -n "$task_arn" ] && [ "$task_arn" != "None" ]; then
            log "Deregistering task definition: $task_arn"
            aws ecs deregister-task-definition --task-definition "$task_arn" --region "$AWS_REGION" >/dev/null 2>&1 || true
        fi
    done

    log "3. Cleaning up ECR Repository ($ECR_REPO_NAME)..."
    aws ecr delete-repository --repository-name "$ECR_REPO_NAME" --force --region "$AWS_REGION" >/dev/null 2>&1 || true

    log "4. Cleaning up IAM User ($IAM_USER_NAME)..."
    if aws iam get-user --user-name "$IAM_USER_NAME" >/dev/null 2>&1; then
        KEYS=$(aws iam list-access-keys --user-name "$IAM_USER_NAME" --query 'AccessKeyMetadata[*].AccessKeyId' --output text 2>/dev/null || true)
        for kid in $KEYS; do
            aws iam delete-access-key --user-name "$IAM_USER_NAME" --access-key-id "$kid" >/dev/null 2>&1 || true
        done

        ATTACHED_POLICIES=$(aws iam list-attached-user-policies --user-name "$IAM_USER_NAME" --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null || true)
        for policy_arn in $ATTACHED_POLICIES; do
            aws iam detach-user-policy --user-name "$IAM_USER_NAME" --policy-arn "$policy_arn" >/dev/null || true
        done

        aws iam delete-user-policy --user-name "$IAM_USER_NAME" --policy-name "PassRolePolicy" >/dev/null 2>&1 || true
        aws iam delete-user --user-name "$IAM_USER_NAME" >/dev/null || true
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