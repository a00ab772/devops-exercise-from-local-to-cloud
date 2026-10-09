#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"

SG_NAME="vprofile-backend-sg"
RDS_INSTANCE_NAME="vprofiledb"
RDS_PG_NAME="vprofile-mysql-pg"
MQ_BROKER_NAME="vprofile-activemq"
EBS_ROLE_NAME="vprofile-eb-ec2-role"
EBS_INSTANCE_PROFILE_NAME="vprofile-eb-instance-profile"
EBS_APPLICATION_NAME="vprofile-web-app"
EBS_ENVIRONMENT_NAME="vprofile-web-env"
ELASTICACHE_SUBNET_GROUP="vprofile-elasticache-subnets"
ELASTICACHE_PG_NAME="vprofile-elasticache-parameter-group"
ELASTICACHE_CLUSTER_ID="vprofile-elasticache"

teardown_elastic_beanstalk() {
    echo "############################################################"
    echo "ELASTIC BEANSTALK TEARDOWN"
    echo "############################################################"

    echo "Terminating Elastic Beanstalk environment: $EBS_ENVIRONMENT_NAME..."
    aws elasticbeanstalk terminate-environment \
        --environment-name "$EBS_ENVIRONMENT_NAME" \
        --region "$AWS_REGION" >/dev/null 2>&1 || true

    echo "Waiting for Elastic Beanstalk environment to terminate (this may take a few minutes)..."
    aws elasticbeanstalk wait environment-terminated \
        --application-name "$EBS_APPLICATION_NAME" \
        --environment-names "$EBS_ENVIRONMENT_NAME" \
        --region "$AWS_REGION" >/dev/null 2>&1 || true

    echo "Deleting Elastic Beanstalk application: $EBS_APPLICATION_NAME..."
    aws elasticbeanstalk delete-application \
        --application-name "$EBS_APPLICATION_NAME" \
        --terminate-env-by-force \
        --region "$AWS_REGION" >/dev/null 2>&1 || true

    echo "Removing IAM roles and instance profiles..."
    aws iam remove-role-from-instance-profile \
        --instance-profile-name "$EBS_INSTANCE_PROFILE_NAME" \
        --role-name "$EBS_ROLE_NAME" >/dev/null 2>&1 || true

    aws iam delete-instance-profile \
        --instance-profile-name "$EBS_INSTANCE_PROFILE_NAME" >/dev/null 2>&1 || true

    aws iam detach-role-policy \
        --role-name "$EBS_ROLE_NAME" \
        --policy-arn arn:aws:iam::aws:policy/AWSElasticBeanstalkWebTier >/dev/null 2>&1 || true

    aws iam delete-role \
        --role-name "$EBS_ROLE_NAME" >/dev/null 2>&1 || true
}

teardown_amazon_mq() {
    echo "############################################################"
    echo "AMAZON MQ TEARDOWN"
    echo "############################################################"

    local broker_id
    broker_id=$(aws mq list-brokers --region "$AWS_REGION" \
        --query "BrokerSummaries[?BrokerName=='$MQ_BROKER_NAME'].BrokerId" \
        --output text 2>/dev/null || true)

    if [ -n "$broker_id" ] && [ "$broker_id" != "None" ]; then
        echo "Deleting Amazon MQ broker ($broker_id)..."
        aws mq delete-broker --broker-id "$broker_id" --region "$AWS_REGION" >/dev/null 2>&1

        echo -n "Waiting for Amazon MQ broker to be deleted"
        while aws mq describe-broker --broker-id "$broker_id" --region "$AWS_REGION" >/dev/null 2>&1; do
            echo -n "."
            sleep 10
        done
        echo " Done."
    else
        echo "Amazon MQ broker not found or already deleted."
    fi
}

teardown_elasticache() {
    echo "############################################################"
    echo "ELASTICACHE TEARDOWN"
    echo "############################################################"

    echo "Deleting ElastiCache cluster: $ELASTICACHE_CLUSTER_ID..."
    aws elasticache delete-cache-cluster \
        --cache-cluster-id "$ELASTICACHE_CLUSTER_ID" \
        --region "$AWS_REGION" >/dev/null 2>&1 || true

    echo -n "Waiting for ElastiCache cluster to be deleted"
    while aws elasticache describe-cache-clusters \
        --cache-cluster-id "$ELASTICACHE_CLUSTER_ID" \
        --region "$AWS_REGION" >/dev/null 2>&1; do
        echo -n "."
        sleep 10
    done
    echo " Done."

    echo "Deleting ElastiCache parameter group..."
    aws elasticache delete-cache-parameter-group \
        --cache-parameter-group-name "$ELASTICACHE_PG_NAME" \
        --region "$AWS_REGION" >/dev/null 2>&1 || true

    echo "Deleting ElastiCache subnet group..."
    aws elasticache delete-cache-subnet-group \
        --cache-subnet-group-name "$ELASTICACHE_SUBNET_GROUP" \
        --region "$AWS_REGION" >/dev/null 2>&1 || true
}

teardown_rds() {
    echo "############################################################"
    echo "RDS TEARDOWN"
    echo "############################################################"

    echo "Deleting RDS instance: $RDS_INSTANCE_NAME (skipping final snapshot)..."
    aws rds delete-db-instance \
        --db-instance-identifier "$RDS_INSTANCE_NAME" \
        --skip-final-snapshot \
        --region "$AWS_REGION" >/dev/null 2>&1 || true

    echo "Waiting for RDS instance to be fully deleted..."
    aws rds wait db-instance-deleted \
        --db-instance-identifier "$RDS_INSTANCE_NAME" \
        --region "$AWS_REGION" >/dev/null 2>&1 || true

    echo "Deleting RDS subnet group: $SG_NAME..."
    aws rds delete-db-subnet-group \
        --db-subnet-group-name "$SG_NAME" \
        --region "$AWS_REGION" >/dev/null 2>&1 || true

    echo "Deleting RDS parameter group: $RDS_PG_NAME..."
    aws rds delete-db-parameter-group \
        --db-parameter-group-name "$RDS_PG_NAME" \
        --region "$AWS_REGION" >/dev/null 2>&1 || true
}

teardown_security_group() {
    echo "############################################################"
    echo "SECURITY GROUP TEARDOWN"
    echo "############################################################"

    local sg_id
    sg_id=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=$SG_NAME" \
        --query "SecurityGroups[0].GroupId" \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || true)

    if [ -n "$sg_id" ] && [ "$sg_id" != "None" ]; then
        echo "Deleting security group: $SG_NAME ($sg_id)..."
        for i in {1..5}; do
            if aws ec2 delete-security-group --group-id "$sg_id" --region "$AWS_REGION" >/dev/null 2>&1; then
                echo "Security group deleted successfully."
                break
            fi
            echo "Waiting for network interfaces/dependencies to clear... attempt $i/5"
            sleep 10
        done
    else
        echo "Security group not found or already deleted."
    fi
}

main() {
    echo "Starting teardown process for vprofile infrastructure..."
    teardown_elastic_beanstalk
    teardown_amazon_mq
    teardown_elasticache
    teardown_rds
    teardown_security_group
    echo "Teardown completed successfully!"
}

main "$@"