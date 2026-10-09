#!/usr/bin/env bash
# set -x
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"

SG_NAME="vprofile-backend-sg"
SG_DESC="${DESCRIPTION:-Security group for the backend services of the vprofile project}"

RDS_INSTANCE_NAME="vprofiledb"
RDS_INSTANCE_CLASS="db.t3.micro"
RDS_ENGINE="mysql"
RDS_PG_NAME="vprofile-mysql-pg"
RDS_PG_DESC="Parameter group for the vprofile MySQL RDS instance"
RDS_FAMILY="mysql8.4"

RDS_USERNAME="admin"
RDS_PASSWORD="vprofile123"
RDS_NAME="vprofilerdsrearch"

MQ_BROKER_NAME="vprofile-activemq"
MQ_USERNAME="admin"
MQ_PASSWORD="vprofile12345"
EBS_ROLE_NAME="vprofile-eb-ec2-role"
EBS_INSTANCE_PROFILE_NAME="vprofile-eb-instance-profile"
EBS_APPLICATION_NAME="vprofile-web-app"
EBS_ENVIRONMENT_NAME="vprofile-web-env"
EBS_STACK_NAME="64bit Amazon Linux 2023 v5.14.9 running Tomcat 10 Corretto 17"

ELASTICACHE_SUBNET_GROUP="vprofile-elasticache-subnets"
ELASTICACHE_SUBNET_GROUP_DESC="Subnets for the vprofile ElastiCache cluster"
ELASTICACHE_PG_NAME="vprofile-elasticache-parameter-group"
ELASTICACHE_CLUSTER_ID="vprofile-elasticache"

create_security_group() {
    echo "############################################################" >&2
    echo "BACKEND SECURITY GROUP" >&2
    echo "############################################################" >&2

    local sg_id
    sg_id=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=$SG_NAME" \
        --query "SecurityGroups[0].GroupId" \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || true)

    if [ -n "$sg_id" ] && [ "$sg_id" != "None" ]; then
        echo "Security group '$SG_NAME' already exists with ID: $sg_id" >&2
    else
        echo "Creating $SG_NAME security group..." >&2
        sg_id=$(aws ec2 create-security-group \
            --region "$AWS_REGION" \
            --group-name "$SG_NAME" \
            --description "$SG_DESC" \
            --query "GroupId" \
            --output text | head -n1 | xargs)
        echo "Backend security group created with ID: $sg_id" >&2

        echo "Authorizing ingress traffic for the backend security group..." >&2
        aws ec2 authorize-security-group-ingress \
            --group-id "$sg_id" \
            --protocol -1 \
            --port -1 \
            --source-group "$sg_id" >/dev/null 2>&1 || true
        echo "Ingress traffic authorized." >&2
    fi

    # Única línea que se imprime sin redirección para que sea capturada limpiamente
    echo "$sg_id"
}

setup_rds() {
    local sg_id="$1"
    echo "############################################################"
    echo "RDS"
    echo "############################################################"

    echo "Creating RDS parameter group for MySQL (if not exists)..."
    aws rds create-db-parameter-group \
        --db-parameter-group-name "$RDS_PG_NAME" \
        --db-parameter-group-family "$RDS_FAMILY" \
        --description "$RDS_PG_DESC" \
        --region "$AWS_REGION" >/dev/null 2>&1 || echo "Parameter group already exists, skipping."

    echo "Fetching subnet IDs..."
    read -r -a subnet_ids <<< "$(aws ec2 describe-subnets --region "$AWS_REGION" --query "Subnets[*].SubnetId" --output text)"

    echo "Creating RDS subnet group..."
    local rds_sg_name
    rds_sg_name=$(aws rds create-db-subnet-group \
        --db-subnet-group-name "$SG_NAME" \
        --db-subnet-group-description "$SG_DESC" \
        --subnet-ids "${subnet_ids[@]}" \
        --region "$AWS_REGION" \
        --query "DBSubnetGroup.DBSubnetGroupName" \
        --output text 2>/dev/null || echo "$SG_NAME")

    # Verificar si la instancia RDS ya existe para evitar errores
    if aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
        echo "RDS instance '$RDS_INSTANCE_NAME' already exists. Fetching endpoint..."
        local rds_endpoint
        rds_endpoint=$(aws rds describe-db-instances \
            --db-instance-identifier "$RDS_INSTANCE_NAME" \
            --region "$AWS_REGION" \
            --query "DBInstances[0].Endpoint.Address" \
            --output text)
    else
        echo "Creating the RDS instance..."
        local rds_endpoint
        rds_endpoint=$(aws rds create-db-instance \
            --db-instance-identifier "$RDS_INSTANCE_NAME" \
            --db-instance-class "$RDS_INSTANCE_CLASS" \
            --engine "$RDS_ENGINE" \
            --engine-version 8.4.11 \
            --master-username "$RDS_USERNAME" \
            --master-user-password "$RDS_PASSWORD" \
            --allocated-storage 20 \
            --storage-type gp2 \
            --db-name "$RDS_NAME" \
            --db-parameter-group-name "$RDS_PG_NAME" \
            --db-subnet-group-name "$rds_sg_name" \
            --vpc-security-group-ids "$sg_id" \
            --backup-retention-period 0 \
            --no-multi-az \
            --no-publicly-accessible \
            --no-storage-encrypted \
            --no-auto-minor-version-upgrade \
            --region "$AWS_REGION" \
            --query "DBInstance.Endpoint.Address" \
            --output text)
    fi

    echo "Waiting for RDS instance to be available..."
    aws rds wait db-instance-available \
        --db-instance-identifier "$RDS_INSTANCE_NAME" \
        --region "$AWS_REGION"

    echo "Temporarily making RDS publicly accessible..."
    aws rds modify-db-instance \
        --db-instance-identifier "$RDS_INSTANCE_NAME" \
        --publicly-accessible \
        --apply-immediately \
        --region "$AWS_REGION" >/dev/null 2>&1 || true

    local local_ip
    local_ip=$(curl -s ifconfig.me)
    echo "Authorizing temporary IP access ($local_ip) to RDS..."
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 3306 \
        --cidr "$local_ip/32" \
        --region "$AWS_REGION" >/dev/null 2>&1 || true

    echo "Populating RDS schema..."
    curl -s -o global-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem

    export MYSQL_PWD="$RDS_PASSWORD"
    mysql -h "$rds_endpoint" -P 3306 -u "$RDS_USERNAME" \
        --ssl-mode=VERIFY_IDENTITY \
        --ssl-ca=./global-bundle.pem < ./db_backup.sql || echo "Schema might already be populated or connection skipped."
    unset MYSQL_PWD

    echo "Reverting RDS to non-publicly accessible..."
    aws rds modify-db-instance \
        --db-instance-identifier "$RDS_INSTANCE_NAME" \
        --no-publicly-accessible \
        --apply-immediately \
        --region "$AWS_REGION" >/dev/null 2>&1 || true

    aws rds wait db-instance-available \
        --db-instance-identifier "$RDS_INSTANCE_NAME" \
        --region "$AWS_REGION"

    echo "Revoking temporary IP access..."
    aws ec2 revoke-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 3306 \
        --cidr "$local_ip/32" \
        --region "$AWS_REGION" >/dev/null 2>&1 || true
}

setup_elasticache() {
    local sg_id="$1"
    echo "############################################################"
    echo "ElastiCache"
    echo "############################################################"

    read -r -a subnet_ids <<< "$(aws ec2 describe-subnets --region "$AWS_REGION" --query "Subnets[*].SubnetId" --output text)"

    aws elasticache create-cache-subnet-group \
        --cache-subnet-group-name "$ELASTICACHE_SUBNET_GROUP" \
        --cache-subnet-group-description "$ELASTICACHE_SUBNET_GROUP_DESC" \
        --subnet-ids "${subnet_ids[@]}" \
        --region "$AWS_REGION" >/dev/null 2>&1 || true

    aws elasticache create-cache-parameter-group \
        --cache-parameter-group-name "$ELASTICACHE_PG_NAME" \
        --cache-parameter-group-family memcached1.6 \
        --description "Parameter group for the vprofile ElastiCache cluster" \
        --region "$AWS_REGION" >/dev/null 2>&1 || true

    local elasticache_engine_version
    elasticache_engine_version=$(aws elasticache describe-cache-engine-versions \
        --engine memcached \
        --region "$AWS_REGION" \
        --query "CacheEngineVersions[-1].EngineVersion" \
        --output text)

    aws elasticache create-cache-cluster \
        --cache-cluster-id "$ELASTICACHE_CLUSTER_ID" \
        --cache-node-type cache.t4g.micro \
        --engine memcached \
        --engine-version "$elasticache_engine_version" \
        --num-cache-nodes 1 \
        --cache-parameter-group-name "$ELASTICACHE_PG_NAME" \
        --cache-subnet-group-name "$ELASTICACHE_SUBNET_GROUP" \
        --security-group-ids "$sg_id" \
        --region "$AWS_REGION" >/dev/null 2>&1 || echo "ElastiCache cluster already exists or is creating."
}

setup_amazon_mq() {
    local sg_id="$1"
    echo "############################################################"
    echo "Amazon MQ"
    echo "############################################################"

    read -r -a subnet_ids <<< "$(aws ec2 describe-subnets --region "$AWS_REGION" --query "Subnets[*].SubnetId" --output text)"

    local mq_engine_version
    mq_engine_version=$(aws mq describe-broker-engine-types \
        --engine-type ActiveMQ \
        --region "$AWS_REGION" \
        --query "BrokerEngineTypes[-1].EngineVersions[-1].Name" \
        --output text)

    aws mq create-broker \
        --broker-name "$MQ_BROKER_NAME" \
        --engine-type ActiveMQ \
        --engine-version "$mq_engine_version" \
        --host-instance-type mq.t3.micro \
        --deployment-mode SINGLE_INSTANCE \
        --security-groups "$sg_id" \
        --subnet-ids "${subnet_ids[0]}" \
        --no-publicly-accessible \
        --users Username="$MQ_USERNAME",Password="$MQ_PASSWORD",ConsoleAccess=true \
        --region "$AWS_REGION" >/dev/null 2>&1 || echo "Amazon MQ broker already exists."
}

setup_elastic_beanstalk() {
    local sg_id="$1"
    echo "############################################################"
    echo "Elastic Beanstalk"
    echo "############################################################"

    aws iam create-role \
        --role-name "$EBS_ROLE_NAME" \
        --assume-role-policy-document '{
          "Version": "2012-10-17",
          "Statement": [{
            "Effect": "Allow",
            "Principal": { "Service": "ec2.amazonaws.com" },
            "Action": "sts:AssumeRole"
          }]
        }' \
        --region "$AWS_REGION" >/dev/null 2>&1 || true

    aws iam attach-role-policy \
        --role-name "$EBS_ROLE_NAME" \
        --policy-arn arn:aws:iam::aws:policy/AWSElasticBeanstalkWebTier >/dev/null 2>&1 || true

    aws iam create-instance-profile \
        --instance-profile-name "$EBS_INSTANCE_PROFILE_NAME" >/dev/null 2>&1 || true

    aws iam add-role-to-instance-profile \
        --instance-profile-name "$EBS_INSTANCE_PROFILE_NAME" \
        --role-name "$EBS_ROLE_NAME" >/dev/null 2>&1 || true

    aws elasticbeanstalk create-application \
        --application-name "$EBS_APPLICATION_NAME" \
        --description "Vprofile Tomcat Web Application" \
        --region "$AWS_REGION" >/dev/null 2>&1 || true

    aws elasticbeanstalk create-environment \
        --application-name "$EBS_APPLICATION_NAME" \
        --environment-name "$EBS_ENVIRONMENT_NAME" \
        --solution-stack-name "$EBS_STACK_NAME" \
        --option-settings \
        Namespace=aws:autoscaling:launchconfiguration,OptionName=IamInstanceProfile,Value="$EBS_INSTANCE_PROFILE_NAME" \
        Namespace=aws:autoscaling:launchconfiguration,OptionName=InstanceType,Value=t3.micro \
        Namespace=aws:elasticbeanstalk:environment,OptionName=EnvironmentType,Value=SingleInstance \
        --region "$AWS_REGION" >/dev/null 2>&1 || echo "Elastic Beanstalk environment might already exist."

    echo "Waiting for Elastic Beanstalk environment to be ready..."
    aws elasticbeanstalk wait environment-updated \
        --application-name "$EBS_APPLICATION_NAME" \
        --environment-names "$EBS_ENVIRONMENT_NAME" \
        --region "$AWS_REGION" 2>/dev/null || true

    local ebs_sg_id
    ebs_sg_id=$(aws ec2 describe-security-groups \
        --filters "Name=tag:elasticbeanstalk:environment-name,Values=$EBS_ENVIRONMENT_NAME" \
        --query "SecurityGroups[0].GroupId" \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "")

    if [ -n "$ebs_sg_id" ] && [ "$ebs_sg_id" != "None" ]; then
        echo "Authorizing Beanstalk access to RDS (port 3306)..."
        aws ec2 authorize-security-group-ingress \
            --group-id "$sg_id" \
            --description "Allow MySQL access from Beanstalk web tier" \
            --protocol tcp \
            --port 3306 \
            --source-group "$ebs_sg_id" \
            --region "$AWS_REGION" >/dev/null 2>&1 || true

        echo "Authorizing Beanstalk access to ElastiCache (port 11211)..."
        aws ec2 authorize-security-group-ingress \
            --group-id "$sg_id" \
            --description "Allow ElastiCache access from Beanstalk web tier" \
            --protocol tcp \
            --port 11211 \
            --source-group "$ebs_sg_id" \
            --region "$AWS_REGION" >/dev/null 2>&1 || true
    fi
}

main() {
    local sg_id
    sg_id=$(create_security_group)

    setup_rds "$sg_id"
    setup_elasticache "$sg_id"
    setup_amazon_mq "$sg_id"
    setup_elastic_beanstalk "$sg_id"

    echo "Deployment completed successfully!"
}

main "$@"