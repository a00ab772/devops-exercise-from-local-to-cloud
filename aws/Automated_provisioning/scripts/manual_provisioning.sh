#!/usr/bin/env bash
AWS_REGION="${AWS_REGION:-us-east-1}"

set -euo pipefail

# BACKEND SECURITY GROUP
echo "Creating backend security group..."
SG_NAME="vprofile-backend-sg"
SG_DESC="${DESCRIPTION:-Security group for the backend services of the vprofile project}"

SG_ID=$(aws ec2 create-security-group \
    --region "$AWS_REGION" \
    --group-name "$SG_NAME" \
    --description "$SG_DESC" \
    --query "GroupId" \
    --output text)
SG_ID=$(echo "$SG_ID" | head -n1 | xargs)
echo "Backend security group created with ID: $SG_ID"

echo "Authorizing ingress traffic for the backend security group..."
aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol -1 \
    --port -1 \
    --source-group "$SG_ID"
echo "Ingress traffic authorized for the backend security group. All the backend services can communicate with each other."

# RDS
echo "Creating RDS parameter group for MySQL..."
DB_PG_NAME="vprofile-mysql-pg"
DB_PG_DESC="Parameter group for the vprofile MySQL RDS instance"
DB_FAMILY="mysql8.4"

RDS_PG_ARN=$(aws rds create-db-parameter-group \
    --db-parameter-group-name "$DB_PG_NAME" \
    --db-parameter-group-family "$DB_FAMILY" \
    --description="$DB_PG_DESC" \
    --region "$AWS_REGION" \
    --query "DBParameterGroup.DBParameterGroupArn" \
    --output text)
echo "RDS parameter group created with ARN: $RDS_PG_ARN"

echo "Modifying the RDS parameter group to set the desired values..."
aws rds modify-db-parameter-group \
    --db-parameter-group-name "$DB_PG_NAME" \
    --parameters \
        "ParameterName=character_set_server,ParameterValue=utf8,ApplyMethod=immediate" \
        "ParameterName=character_set_client,ParameterValue=utf8,ApplyMethod=immediate" \
        "ParameterName=log_bin_trust_function_creators,ParameterValue=1,ApplyMethod=immediate" \
        "ParameterName=sql_mode,ParameterValue=STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION,ApplyMethod=immediate"
echo "MySQL parameter group values set."

