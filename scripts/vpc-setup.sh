#!/bin/bash

#@author: Pavel Losiev
#@description: PHASE 1 -  VPC with a public and private subnet, an internet gateway, a route table, and a security group.
#@date: 2025-23-05
#@version: 1.0
#@dependencies: AWS CLI, jq, curl

#############################################

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null
then
    echo "AWS CLI could not be found. Please install it first."
    exit
fi
# Check if jq is installed
if ! command -v jq &> /dev/null
then
    echo "jq could not be found. Please install it first."
    exit
fi
# Check if curl is installed
if ! command -v curl &> /dev/null
then
    echo "curl could not be found. Please install it first."
    exit
fi
# Check if AWS credentials are configured
if ! aws sts get-caller-identity &> /dev/null
then
    echo "AWS credentials are not configured. Please configure them first."
    exit
fi
# Check if the region is set
if ! aws configure get region &> /dev/null
then
    echo "AWS region is not set. Please set it first."
    exit
fi
############################################33


# Creating a VPC with a CIDR block of 10.0.0.0/24
vpcid=$(aws ec2 create-vpc \
    --cidr-block 10.0.0.0/25 \
    --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=myVPC}]' \
    --query 'Vpc.VpcId' \
    --output text)

echo "VPC created: $vpcid"

# Create Private Subnet
privsub1=$(aws ec2 create-subnet \
  --vpc-id $vpcid \
  --cidr-block 10.0.0.0/26 \
  --availability-zone us-west-2a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=Private Subnet}]' \
  --query 'Subnet.SubnetId' \
  --output text)

echo "Private Subnet created: $privsub1"

# Create Public Subnet
pubsub1=$(aws ec2 create-subnet \
  --vpc-id $vpcid \
  --cidr-block 10.0.0.64/28 \
  --availability-zone us-west-2a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=Public Subnet}]' \
  --query 'Subnet.SubnetId' \
  --output text)

echo "Public Subnet created: $pubsub1"

# Enable Public IP on launch
aws ec2 modify-subnet-attribute \
  --subnet-id $pubsub1 \
  --map-public-ip-on-launch

# Create Internet Gateway
igw=$(aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=myIGW}]' \
  --query 'InternetGateway.InternetGatewayId' \
  --output text)
echo "Internet Gateway created: $igw"

# Attach Internet Gateway to VPC
aws ec2 attach-internet-gateway \
  --vpc-id $vpcid \
  --internet-gateway-id $igw

echo "Internet Gateway attached to VPC $vpcid"

# Create Route Table
routetable=$(aws ec2 create-route-table \
  --vpc-id $vpcid \
  --query 'RouteTable.RouteTableId' \
  --output text)

echo "Route Table created: $routetable"

# Tag Route Table
aws ec2 create-tags \
  --resources $routetable \
  --tags Key=Name,Value="myPublic RouteTable"
echo "Route Table tagged with Name: myPublic RouteTable"

# Create Route to Internet Gateway
aws ec2 create-route \
    --route-table-id $routetable \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id $igw
echo "Route to Internet Gateway created in Route Table $routetable"

# Associate Route Table with Public Subnet
aws ec2 associate-route-table \
  --subnet-id $pubsub1 \
  --route-table-id $routetable

echo "Route Table $routetable associated with Public Subnet $pubsub1"

###################################################


# Allocate Elastic IP for NAT Gateway
eip_alloc_id=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
echo "Elastic IP allocated for NAT Gateway: $eip_alloc_id"

# Create NAT Gateway in the public subnet
nat_gw_id=$(aws ec2 create-nat-gateway \
  --subnet-id $pubsub1 \
  --allocation-id $eip_alloc_id \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=myNATGateway}]' \
  --query 'NatGateway.NatGatewayId' \
  --output text)
echo "NAT Gateway created: $nat_gw_id"

# Wait for NAT Gateway to become available
echo "🕒 Waiting for NAT Gateway to become available..."
aws ec2 wait nat-gateway-available --nat-gateway-ids $nat_gw_id

###################################################

# Create Route Table for Private Subnet
priv_routetable=$(aws ec2 create-route-table \
  --vpc-id $vpcid \
  --query 'RouteTable.RouteTableId' \
  --output text)
echo "Private Route Table created: $priv_routetable"

# Tag Private Route Table
aws ec2 create-tags \
  --resources $priv_routetable \
  --tags Key=Name,Value="myPrivate RouteTable"
echo "Private Route Table tagged with Name: myPrivate RouteTable"

# Create Route to NAT Gateway in Private Route Table
aws ec2 create-route \
    --route-table-id $priv_routetable \
    --destination-cidr-block 0.0.0.0/0 \
    --nat-gateway-id $nat_gw_id
echo "Route to NAT Gateway created in Private Route Table $priv_routetable"

# Associate Private Route Table with Private Subnet
aws ec2 associate-route-table \
  --subnet-id $privsub1 \
  --route-table-id $priv_routetable
echo "Private Route Table $priv_routetable associated with Private Subnet $privsub1"

echo "🚀 VPC setup completed successfully! 🚀"

###################################################
