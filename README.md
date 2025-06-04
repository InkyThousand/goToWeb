# goToWeb

This project will use AWS VPC and all necessary settings to deploy a web server and database in EC2 instances with WordPress installed.

## Installation & Setup Process

1. **Clone the Repository**
```
git clone <repo-url>
cd goToWeb
```

2. **Configure AWS CLI**

Ensure you have the AWS CLI installed and configured with your credentials and default region.

3. **Install Dependencies**

Make sure jq and curl are installed on your system.

4. **Run VPC Setup Script**
```cd scripts
./vpc-setup.sh
```

This script creates the VPC, public and private subnets, internet gateway, NAT gateway, and route tables.

5. **Run EC2 Instances Setup Script**
```
./instances-setup.sh
```

This script launches the Bastion host and the web server, sets up security groups, and installs Apache, PHP, and MySQL client on the web server using EC2 user data.

6. **Access the Web Server**
After the scripts complete, you can access the web server via its public IP. The default page will show PHP info.

Find the private IP of the web server:
On your local machine (not Bastion), run:
```
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=WebServer" \
  --query "Reservations[0].Instances[0].PrivateIpAddress" \
  --output text
```
From the Bastion server, SSH to the web server:
```
ssh -i /path/to/your/keypair.pem ec2-user@<webserver-private-ip>
```
You can upload your .pem file from your local machine to the Bastion server using scp
```
scp -i ~/.ssh/myBastionKey.pem ~/Downloads/myKeyPair.pem ec2-user@<BastionPublicIP>:~/
```

**Notes**
- The Bastion host allows SSH access only from your current IP.
- The web server allows HTTP (port 80) from anywhere and SSH only from the Bastion host.
- Modify the user data script in instances-setup.sh to customize software installation or deploy WordPress.



**Requirements**
- AWS CLI
- jq
- curl

AWS account with permissions to create VPCs, subnets, EC2 instances, and security groups