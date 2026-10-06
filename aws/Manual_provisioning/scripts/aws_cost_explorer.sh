#!/usr/bin/env bash
REGION="${AWS_REGION:-us-east-1}"

echo "=== Running EC2 Instances ===" && \
aws ec2 describe-instances --region $REGION --filters "Name=instance-state-name,Values=running" --query 'Reservations[*].Instances[*].{ID:InstanceId,Type:InstanceType}' --output table

echo "=== Unattached EBS Volumes ===" && \
aws ec2 describe-volumes --region $REGION --filters "Name=status,Values=available" --query 'Volumes[*].{ID:VolumeId,Size:Size,Type:VolumeType}' --output table

echo "=== Unattached Elastic IPs ===" && \
aws ec2 describe-addresses --region $REGION --query 'Addresses[?InstanceId==null].{IP:PublicIp,ID:AllocationId}' --output table

echo "=== NAT Gateways ===" && \
aws ec2 describe-nat-gateways --region $REGION --filter "Name=state,Values=available" --query 'NatGateways[*].{ID:NatGatewayId,State:State}' --output table

echo "=== RDS Instances ===" && \
aws rds describe-db-instances --region $REGION --query 'DBInstances[*].{ID:DBInstanceIdentifier,Class:DBInstanceClass,State:DBInstanceStatus}' --output table

echo "=== Load Balancers ===" && \
aws elbv2 describe-load-balancers --region $REGION --query 'LoadBalancers[*].{Name:LoadBalancerName,Type:Type,State:State.Code}' --output table

