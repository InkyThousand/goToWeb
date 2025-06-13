#!/bin/bash

# @author: Pavel Losiev
# @description: PHASE 3 - RDS Setup Script from AWS CLI
# @date: 2025-25-05
# @usage: ./rds-setup.sh
# @dependencies: AWS CLI, jq, curl
#############################################

set -e

# Configuration variables
DB_INSTANCE_IDENTIFIER="gotoweb-db"
DB_ENGINE="mysql"
DB_ENGINE_VERSION="8.0"
DB_INSTANCE_CLASS="db.t3.micro"

DB_NAME="wordpressdb"
DB_USERNAME="wpuser"
DB_PASSWORD="wpsecurepass"  # Change this to a secure password

DB_ALLOCATED_STORAGE=20
DB_SUBNET_GROUP_NAME="gotoweb-db-subnet-group"
DB_SECURITY_GROUP_NAME="gotoweb-db-sg"

# Get the VPC ID for MyVPC
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=MyVPC" --query "Vpcs[0].VpcId" --output text)

# If MyVPC not found, try to find it by listing all non-default VPCs
if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
    echo "MyVPC not found by name tag. Looking for non-default VPCs..."
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=false" --query "Vpcs[0].VpcId" --output text)
fi

# If still not found, use the VPC ID directly
if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
    # Use the VPC ID where you want to create the RDS instance
    VPC_ID="vpc-0a91addd30580e475"  # Replace with your MyVPC ID
    echo "Using hardcoded VPC ID: $VPC_ID"
fi

echo "Using VPC ID: $VPC_ID for RDS instance"
echo "Using VPC ID: $VPC_ID"
BACKUP_RETENTION_PERIOD=7
MULTI_AZ=false

echo "Starting RDS setup process..."

# Create additional subnets in different AZs if needed
echo "Checking available AZs and subnets..."
SUBNET_INFO=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "Subnets[].{SubnetId:SubnetId,AZ:AvailabilityZone,Public:MapPublicIpOnLaunch,CIDR:CidrBlock}" \
    --output json)

echo "Available subnets:"
echo "$SUBNET_INFO" | jq -r '.[] | "SubnetId: \(.SubnetId), AZ: \(.AZ), CIDR: \(.CIDR), Public: \(.Public)"'

# Get VPC CIDR
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --query "Vpcs[0].CidrBlock" --output text)
echo "VPC CIDR: $VPC_CIDR"

# Get list of all AZs in the region
REGION=$(aws configure get region)
if [ -z "$REGION" ]; then
    REGION="us-west-2"  # Default to us-west-2 if not set
fi
echo "Using region: $REGION"

AVAILABLE_AZS=$(aws ec2 describe-availability-zones \
    --region $REGION \
    --query "AvailabilityZones[?State=='available'].ZoneName" \
    --output text)
echo "Available AZs in region: $AVAILABLE_AZS"

# Create array of existing AZs in our VPC
declare -A EXISTING_AZS
for row in $(echo "$SUBNET_INFO" | jq -c '.[] | {AZ: .AZ}'); do
    AZ=$(echo $row | jq -r '.AZ')
    EXISTING_AZS[$AZ]=1
done

echo "Existing AZs in VPC: ${!EXISTING_AZS[*]}"

# Calculate new CIDR blocks for additional subnets
# Extract base CIDR and calculate new ones
BASE_CIDR=$(echo $VPC_CIDR | cut -d'/' -f1)
CIDR_PREFIX=$(echo $VPC_CIDR | cut -d'/' -f2)
IFS='.' read -r -a CIDR_PARTS <<< "$BASE_CIDR"

# Create subnets in at least one more AZ
SUBNET_IDS=()
AZ_COUNT=0

# First, add existing subnets
for row in $(echo "$SUBNET_INFO" | jq -c '.[] | {SubnetId: .SubnetId, AZ: .AZ}'); do
    ID=$(echo $row | jq -r '.SubnetId')
    AZ=$(echo $row | jq -r '.AZ')
    SUBNET_IDS+=($ID)
    echo "Added existing subnet $ID in AZ $AZ"
    AZ_COUNT=$((AZ_COUNT + 1))
    if [ $AZ_COUNT -ge 2 ]; then
        break
    fi
done

# If we don't have enough AZs, modify the script to use a single AZ with multiple subnets
if [ $AZ_COUNT -lt 2 ]; then
    echo "WARNING: Your VPC only has subnets in a single AZ. Using single-AZ deployment for RDS."
    echo "For production, consider creating subnets in multiple AZs."
    
    # Set multi-AZ to false explicitly
    MULTI_AZ=false
    
    # Use the --no-multi-az flag for RDS
    MULTI_AZ_FLAG="--no-multi-az"
    
    # Filter to only include private subnets for DB
    SUBNET_IDS=()
    for row in $(echo "$SUBNET_INFO" | jq -c '.[] | select(.Public==false) | {SubnetId: .SubnetId, AZ: .AZ}'); do
        ID=$(echo $row | jq -r '.SubnetId')
        AZ=$(echo $row | jq -r '.AZ')
        SUBNET_IDS+=($ID)
        echo "Selected private subnet $ID in AZ $AZ for DB subnet group"
    done
    
    # If no private subnets, use public ones
    if [ ${#SUBNET_IDS[@]} -eq 0 ]; then
        for row in $(echo "$SUBNET_INFO" | jq -c '.[] | {SubnetId: .SubnetId, AZ: .AZ}'); do
            ID=$(echo $row | jq -r '.SubnetId')
            AZ=$(echo $row | jq -r '.AZ')
            SUBNET_IDS+=($ID)
            echo "Selected subnet $ID in AZ $AZ for DB subnet group"
        done
    fi
fi

# Check if we have enough subnets for DB subnet group
if [ ${#SUBNET_IDS[@]} -lt 2 ]; then
    echo "WARNING: Not enough subnets found in different AZs. Creating a new subnet in another AZ..."
    
    # Find an AZ that doesn't have a subnet yet
    for AZ in $AVAILABLE_AZS; do
        if [ -z "${EXISTING_AZS[$AZ]}" ]; then
            echo "Creating new subnet in AZ $AZ"
            
            # Calculate a new CIDR block that doesn't overlap with existing ones
            # Using a simple approach with fixed CIDR in a different range
            NEW_CIDR="10.0.1.0/24"
            
            echo "Attempting to create subnet with CIDR $NEW_CIDR in AZ $AZ"
            NEW_SUBNET_ID=$(aws ec2 create-subnet \
                --vpc-id $VPC_ID \
                --cidr-block $NEW_CIDR \
                --availability-zone $AZ \
                --query "Subnet.SubnetId" \
                --output text)
                
            echo "Created new subnet $NEW_SUBNET_ID in AZ $AZ with CIDR $NEW_CIDR"
            SUBNET_IDS+=($NEW_SUBNET_ID)
            break
        fi
    done
fi

# Ensure we have at least 2 subnets for the DB subnet group
if [ ${#SUBNET_IDS[@]} -lt 2 ]; then
    echo "ERROR: Could not create or find at least 2 subnets for DB subnet group."
    echo "RDS requires subnets in at least 2 AZs."
    exit 1
fi

# Check if security group already exists
echo "Checking if security group already exists..."
SG_CHECK=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$DB_SECURITY_GROUP_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[0].GroupId" \
    --output text 2>/dev/null || echo "")

if [ -z "$SG_CHECK" ] || [ "$SG_CHECK" == "None" ]; then
    # Create security group for RDS
    echo "Creating security group for RDS..."
    DB_SG_ID=$(aws ec2 create-security-group \
        --group-name $DB_SECURITY_GROUP_NAME \
        --description "Security group for GoToWeb RDS instance" \
        --vpc-id $VPC_ID \
        --output text --query 'GroupId')
    
    # Allow MySQL/Aurora traffic from anywhere within the VPC
    echo "Adding ingress rule to security group..."
    aws ec2 authorize-security-group-ingress \
        --group-id $DB_SG_ID \
        --protocol tcp \
        --port 3306 \
        --cidr 10.0.0.0/16
else
    echo "Security group $DB_SECURITY_GROUP_NAME already exists with ID: $SG_CHECK"
    DB_SG_ID=$SG_CHECK
fi

# Create RDS instance
echo "Creating RDS instance (this may take several minutes)..."
# Create DB subnet group with subnets from the custom VPC
echo "Creating DB subnet group with subnets from custom VPC..."
aws rds create-db-subnet-group \
    --db-subnet-group-name $DB_SUBNET_GROUP_NAME \
    --db-subnet-group-description "Subnet group for GoToWeb RDS instance" \
    --subnet-ids ${SUBNET_IDS[@]}

aws rds create-db-instance \
    --db-instance-identifier $DB_INSTANCE_IDENTIFIER \
    --db-instance-class $DB_INSTANCE_CLASS \
    --engine $DB_ENGINE \
    --engine-version $DB_ENGINE_VERSION \
    --master-username $DB_USERNAME \
    --master-user-password "$DB_PASSWORD" \
    --allocated-storage $DB_ALLOCATED_STORAGE \
    --db-name $DB_NAME \
    --db-subnet-group-name $DB_SUBNET_GROUP_NAME \
    --vpc-security-group-ids $DB_SG_ID \
    --backup-retention-period $BACKUP_RETENTION_PERIOD \
    --storage-type gp2 \
    --tags Key=Environment,Value=Production Key=Project,Value=GoToWeb

echo "Waiting for RDS instance to become available..."
aws rds wait db-instance-available --db-instance-identifier $DB_INSTANCE_IDENTIFIER

# Get the endpoint
DB_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier $DB_INSTANCE_IDENTIFIER \
    --query "DBInstances[0].Endpoint.Address" \
    --output text)

echo "RDS setup completed successfully!"
echo "=============================="
echo "DB Instance: $DB_INSTANCE_IDENTIFIER"
echo "DB Engine: $DB_ENGINE $DB_ENGINE_VERSION"
echo "DB Name: $DB_NAME"
echo "DB Endpoint: $DB_ENDPOINT"
echo "DB Username: $DB_USERNAME"
echo "DB Password: $DB_PASSWORD"
echo "=============================="
echo "IMPORTANT: Please save these credentials securely!"

# Save credentials to a secure file
echo "Saving credentials to .env.db file..."
cat > .env.db << EOF
DB_HOST=$DB_ENDPOINT
DB_PORT=3306
DB_NAME=$DB_NAME
DB_USER=$DB_USERNAME
DB_PASSWORD=$DB_PASSWORD
EOF

chmod 600 .env.db
echo "Credentials saved to .env.db file. Keep this file secure!"
