#!/bin/bash

#@author: Pavel Losiev
#@description: PHASE 2 - EC2 Instance Launch with User Data.
#@date: 2025-25-05
#@usage: ./instances-setup.sh
#@dependencies: AWS CLI, jq, curl

#############################################

# Load VPC, Subnet IDs and Security Group from Phase 1 output
vpcid=$(aws ec2 describe-vpcs \
  --filters Name=tag:Name,Values=myVPC \
  --query 'Vpcs[0].VpcId' \
  --output text)

# Get the Subnet IDs
pubsub1=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values='Public Subnet'" "Name=vpc-id,Values=$vpcid" \
  --query 'Subnets[0].SubnetId' \
  --output text)

# Get the Private Subnet ID
privsub1=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values='Private Subnet'" "Name=vpc-id,Values=$vpcid" \
  --query 'Subnets[0].SubnetId' \
  --output text)

# Check if VPC, Subnet IDs and Security Group are found
if [ -z "$vpcid" ] || [ -z "$pubsub1" ] || [ -z "$privsub1" ]; then
  echo "Error: VPC, Subnet IDs not found. Please run the VPC setup script first."
  exit 1
fi

# Print the IDs for verification
echo "VPC ID: $vpcid"
echo "Public Subnet ID: $pubsub1"
echo "Private Subnet ID: $privsub1"


# Get the current public IP address
myip=$(curl -s http://checkip.amazonaws.com)/32
echo "My IP address is: $myip"

# Create Security Group
BastionSecurityGroup=$(aws ec2 create-security-group \
  --group-name mySecurityGroup \
  --description "Security group for Bastion host - Restrict security group ingress to my IP" \
  --vpc-id $vpcid \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=BastionSecurityGroup}]' \
  --query 'GroupId' \
  --output text)
echo "Security Group created: $BastionSecurityGroup"

# Add Inbound Rules to Security Group enabling SSH access from my IP
aws ec2 authorize-security-group-ingress \
  --group-id $BastionSecurityGroup \
  --protocol tcp \
  --port 22 \
  --cidr $myip
echo "Inbound rule added to Security Group $BastionSecurityGroup allowing SSH access from $myip"


# Get the latest Amazon Linux 2023 AMI ID with SSM Parameter 
al2023_ami=$(aws ssm get-parameter \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64 \
    --query "Parameter.Value" \
    --output text)
echo "Latest Amazon Linux 2023 AMI: $al2023_ami"

# Get avalable key pair
keypair=$(aws ec2 describe-key-pairs \
  --query 'KeyPairs[0].KeyName' \
  --output text)

# Check if a key pair exists
if [ $keypair == "None" || $keypair != "vockey" ]; then
  echo "No key pair found. Creating a new key pair."
  # Create key pair
  aws ec2 create-key-pair \
    --key-name myKeyPair \
    --query 'KeyMaterial' \
    --output text > myKeyPair.pem
else
  echo "Using existing key pair: $keypair"
fi

# Launch an EC2 instance in the public subnet with user data
instance_id=$(aws ec2 run-instances \
  --image-id $al2023_ami \
  --instance-type t2.micro \
  --key-name $keypair \
  --security-group-ids $BastionSecurityGroup \
  --subnet-id $pubsub1 \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=BastionServer}]' \
  --query 'Instances[0].InstanceId' \
  --output text
)

echo "BastionServer launched: $instance_id"


##########################################

# Create Security Group for Web Server
WebServerSecurityGroup=$(aws ec2 create-security-group \
  --group-name WebServerSecurityGroup \
  --description "Security group for Web Server - HTTP from anywhere, SSH from Bastion" \
  --vpc-id $vpcid \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=WebServerSecurityGroup}]' \
  --query 'GroupId' \
  --output text)
echo "Web Server Security Group created: $WebServerSecurityGroup"

# Allow HTTP from anywhere
aws ec2 authorize-security-group-ingress \
  --group-id $WebServerSecurityGroup \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0

# Allow SSH only from Bastion Security Group
aws ec2 authorize-security-group-ingress \
  --group-id $WebServerSecurityGroup \
  --protocol tcp \
  --port 22 \
  --source-group $BastionSecurityGroup

echo "Inbound rules added to Web Server Security Group"


# Launch webserserver in public subnet with connection into only from bastion server but with inbound rule to allow HTTP traffic from anywhere
webserver_id=$(aws ec2 run-instances \
  --image-id $al2023_ami \
  --instance-type t2.micro \
  --key-name $keypair \
  --security-group-ids $WebServerSecurityGroup \
  --subnet-id $pubsub1 \
  --user-data file://userdata.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=WebServer}]' \
  --query 'Instances[0].InstanceId' \
  --output text
)

echo "WebServer launched: $webserver_id"

# Get the public IP of the Bastion Server
bastion_ip=$(aws ec2 describe-instances \
  --instance-ids $instance_id \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "Bastion Server Public IP: $bastion_ip"