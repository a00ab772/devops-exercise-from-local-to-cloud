#!/bin/bash
REGION="${AWS_REGION:-us-east-1}"

echo ""
echo "=================================================="
echo " AWS UNUSED RESOURCES REPORT"
echo " Region: $REGION"
echo "=================================================="

# -----------------------------------------------
# 1. UNATTACHED EBS VOLUMES (paying for unused storage)
# -----------------------------------------------
echo ""
echo "=== 1. UNATTACHED EBS VOLUMES (available = not attached) ==="
aws ec2 describe-volumes \
    --region $REGION \
    --filters "Name=status,Values=available" \
    --query 'Volumes[*].{VolumeId:VolumeId, SizeGB:Size, Type:VolumeType, Created:CreateTime}' \
    --output table

# -----------------------------------------------
# 2. UNATTACHED ELASTIC IPs (charged when not associated)
# -----------------------------------------------
echo ""
echo "=== 2. UNATTACHED ELASTIC IPs ==="
aws ec2 describe-addresses \
    --region $REGION \
    --query 'Addresses[?InstanceId==null && NetworkInterfaceId==null].{AllocationId:AllocationId, IP:PublicIp}' \
    --output table

# -----------------------------------------------
# 3. EC2 INSTANCES, no matter if they run or not
# -----------------------------------------------
echo ""
echo "=== 15. EC2 INSTANCES ==="
aws ec2 describe-instances \
    --region $REGION \
    --query "Reservations[*].Instances[*].{InstanceId:InstanceId, State:State.Name, Type:InstanceType, Name:Tags[?Key=='Name']|[0].Value}" \
    --output table

# -----------------------------------------------
# 4. UNUSED AMIs / MACHINE IMAGES (paying for snapshot storage)
# -----------------------------------------------
echo ""
echo "=== 4. OWNED AMIs (check if still needed) ==="
aws ec2 describe-images \
    --region $REGION \
    --owners self \
    --query 'Images[*].{ImageId:ImageId, Name:Name, Created:CreationDate, State:State}' \
    --output table

# -----------------------------------------------
# 5. OLD EBS SNAPSHOTS (paying for snapshot storage)
# -----------------------------------------------
echo ""
echo "=== 5. EBS SNAPSHOTS OLDER THAN 90 DAYS ==="
CUTOFF=$(date -d '90 days ago' --utc +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -v-90d -u +%Y-%m-%dT%H:%M:%S)
aws ec2 describe-snapshots \
    --region $REGION \
    --owner-ids self \
    --query "Snapshots[?StartTime<='$CUTOFF'].{SnapshotId:SnapshotId, SizeGB:VolumeSize, Created:StartTime, Description:Description}" \
    --output table

# -----------------------------------------------
# 6. EMPTY / UNUSED S3 BUCKETS
# -----------------------------------------------
echo ""
echo "=== 6. EMPTY S3 BUCKETS ==="
for bucket in $(aws s3api list-buckets --query 'Buckets[*].Name' --output text); do
    count=$(aws s3api list-objects-v2 --bucket $bucket --max-items 1 --query 'length(Contents)' --output text 2>/dev/null)
    if [ "$count" == "None" ] || [ "$count" == "0" ]; then
        echo "  EMPTY: $bucket"
    fi
done

# -----------------------------------------------
# 7. UNUSED LOAD BALANCERS (no targets registered)
# -----------------------------------------------
echo ""
echo "=== 7. LOAD BALANCERS WITH NO HEALTHY TARGETS ==="
for lb_arn in $(aws elbv2 describe-load-balancers --region $REGION --query 'LoadBalancers[*].LoadBalancerArn' --output text); do
    lb_name=$(aws elbv2 describe-load-balancers --region $REGION --load-balancer-arns $lb_arn --query 'LoadBalancers[0].LoadBalancerName' --output text)
    tg_arns=$(aws elbv2 describe-target-groups --region $REGION --load-balancer-arn $lb_arn --query 'TargetGroups[*].TargetGroupArn' --output text)
    if [ -z "$tg_arns" ]; then
        echo "  NO TARGET GROUPS: $lb_name ($lb_arn)"
    else
        for tg_arn in $tg_arns; do
            healthy=$(aws elbv2 describe-target-health --region $REGION --target-group-arn $tg_arn --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
            if [ "$healthy" == "0" ]; then
                echo "  NO HEALTHY TARGETS: $lb_name — TG: $tg_arn"
            fi
        done
    fi
done

# -----------------------------------------------
# 8. UNUSED NAT GATEWAYS (no traffic / idle)
# -----------------------------------------------
echo ""
echo "=== 8. NAT GATEWAYS (review if still needed) ==="
aws ec2 describe-nat-gateways \
    --region $REGION \
    --filter "Name=state,Values=available" \
    --query 'NatGateways[*].{ID:NatGatewayId, VPC:VpcId, Subnet:SubnetId, Created:CreateTime}' \
    --output table

# ------------------
# 9. SECURITY GROUPS
# ------------------
echo ""
echo "=== 9. SECURITY GROUPS ==="
all_sgs=$(aws ec2 describe-security-groups --region "$REGION" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text)

printf "%-22s | %-15s | %-14s | %-15s | %s\n" "GROUP ID" "NAME" "STATUS" "SERVICE/TYPE" "USED BY (DESCRIPTION/ID)"
printf "%s\n" "------------------------------------------------------------------------------------------------------------------"

for sg in $all_sgs; do
	name=$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$sg" --query 'SecurityGroups[0].GroupName' --output text)
	
	eni_info=$(aws ec2 describe-network-interfaces --region "$REGION" --filters "Name=group-id,Values=$sg" --query 'NetworkInterfaces[*].[InterfaceType, Description, RequesterId, Attachment.InstanceId]' --output text 2>/dev/null)
	
	if [ -n "$eni_info" ]; then
		service_type=$(echo "$eni_info" | head -n 1 | awk '{print $1}')
		owner_desc=$(echo "$eni_info" | head -n 1 | cut -f2-)
		printf "%-22s | %-15s | %-14s | %-15s | %s\n" "$sg" "$name" "EN USO" "${service_type:-ENI}" "${owner_desc:-N/A}"
	else
		printf "%-22s | %-15s | %-14s | %-15s | %s\n" "$sg" "$name" "UNUSED" "-" "-"
	fi
done

# -----------------------------------------------
# 10. UNUSED KEY PAIRS (not attached to any instance)
# -----------------------------------------------
echo ""
echo "=== 10. KEY PAIRS NOT USED BY ANY INSTANCE ==="
all_keys=$(aws ec2 describe-key-pairs --region $REGION --query 'KeyPairs[*].KeyName' --output text)
used_keys=$(aws ec2 describe-instances --region $REGION --query 'Reservations[*].Instances[*].KeyName' --output text | tr '\t' '\n' | sort -u)
for key in $all_keys; do
    if ! echo "$used_keys" | grep -q "^$key$"; then
        echo "  UNUSED: $key"
    fi
done

# -----------------------------------------------
# 11. OLD RDS SNAPSHOTS (manual snapshots older than 90 days)
# -----------------------------------------------
echo ""
echo "=== 11. RDS MANUAL SNAPSHOTS OLDER THAN 90 DAYS ==="
CUTOFF=$(date -d '90 days ago' --utc +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -v-90d -u +%Y-%m-%dT%H:%M:%S)
aws rds describe-db-snapshots \
    --region $REGION \
    --snapshot-type manual \
    --query "DBSnapshots[?SnapshotCreateTime<='$CUTOFF'].{ID:DBSnapshotIdentifier, Size:AllocatedStorage, Engine:Engine, Created:SnapshotCreateTime}" \
    --output table

# -----------------------------------------------
# 12. UNUSED VPCs (no running instances)
# -----------------------------------------------
echo ""
echo "=== 12. VPCs WITH NO RUNNING INSTANCES ==="
for vpc in $(aws ec2 describe-vpcs --region $REGION --query 'Vpcs[?IsDefault==`false`].VpcId' --output text); do
    count=$(aws ec2 describe-instances --region $REGION \
        --filters "Name=vpc-id,Values=$vpc" "Name=instance-state-name,Values=running" \
        --query 'length(Reservations)' --output text)
    if [ "$count" == "0" ]; then
        cidr=$(aws ec2 describe-vpcs --region $REGION --vpc-ids $vpc --query 'Vpcs[0].CidrBlock' --output text)
        echo "  NO RUNNING INSTANCES: $vpc (CIDR: $cidr)"
    fi
done

# -----------------------------------------------
# 13. CLOUDWATCH LOG GROUPS WITH NO RETENTION POLICY
# -----------------------------------------------
echo ""
echo "=== 13. CLOUDWATCH LOG GROUPS WITH NO RETENTION POLICY (logs never expire) ==="
aws logs describe-log-groups \
    --region $REGION \
    --query 'logGroups[?retentionInDays==null].{Name:logGroupName, SizeBytes:storedBytes}' \
    --output table

# -----------------------------------------------
# 14. UNUSED ELASTIC NETWORK INTERFACES
# -----------------------------------------------
echo ""
echo "=== 14. UNATTACHED ELASTIC NETWORK INTERFACES (ENIs) ==="
aws ec2 describe-network-interfaces \
    --region $REGION \
    --filters "Name=status,Values=available" \
    --query 'NetworkInterfaces[*].{ID:NetworkInterfaceId, Description:Description, VPC:VpcId, AZ:AvailabilityZone}' \
    --output table

echo ""
echo "=================================================="
echo " REPORT COMPLETE"
echo " Review the above and delete resources no longer needed."
echo " Use AWS Cost Explorer for actual cost impact:"
echo " https://console.aws.amazon.com/cost-management/home"
echo "=================================================="

