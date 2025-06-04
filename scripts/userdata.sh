#!/bin/bash
yum update -y
yum install -y httpd php php-mysqlnd wget unzip
yum install -y https://dev.mysql.com/get/mysql80-community-release-el9-1.noarch.rpm
rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql-2022
yum install -y mysql-community-server

systemctl enable httpd
systemctl start httpd
systemctl enable mysqld
systemctl start mysqld

# Ensure PHP MySQL extension is installed
yum install -y php-mysqlnd

# Restart Apache to load new PHP extensions
systemctl restart httpd

# Set MySQL root password and create WordPress DB/user
DBNAME=wordpressdb
DBUSER=wpuser
DBPASS=wpsecurepass

sleep 15

# Get temporary MySQL root password
TEMP_PASS=$(grep 'temporary password' /var/log/mysqld.log | awk '{print $NF}')
NEW_PASS='RootPassw0rd!'

# Set new root password and create DB/user
mysql --connect-expired-password -u root -p"$TEMP_PASS" <<MYSQL_SCRIPT
ALTER USER 'root'@'localhost' IDENTIFIED BY '$NEW_PASS';
CREATE DATABASE IF NOT EXISTS $DBNAME;
CREATE USER IF NOT EXISTS '$DBUSER'@'localhost' IDENTIFIED BY '$DBPASS';
GRANT ALL PRIVILEGES ON $DBNAME.* TO '$DBUSER'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

# Download and extract WordPress
wget https://wordpress.org/latest.zip -O /tmp/wordpress.zip
unzip /tmp/wordpress.zip -d /tmp/
cp -r /tmp/wordpress/* /var/www/html/
chown -R apache:apache /var/www/html/
chmod -R 755 /var/www/html/

# Configure wp-config.php
cp /var/www/html/wp-config-sample.php /var/www/html/wp-config.php
sed -i "s/database_name_here/$DBNAME/" /var/www/html/wp-config.php
sed -i "s/username_here/$DBUSER/" /var/www/html/wp-config.php
sed -i "s/password_here/$DBPASS/" /var/www/html/wp-config.php

