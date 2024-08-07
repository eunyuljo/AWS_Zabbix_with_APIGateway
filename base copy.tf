provider "aws" {
  region = "ap-northeast-2"
}

# 기존 VPC의 ID를 명시
variable "vpc_id" {
  type    = string
  default = "vpc-02fc631229f179dd9" # 기존 VPC ID로 변경하세요
}

# 퍼블릭 서브넷 ID 리스트
variable "public_subnet_ids" {
  type    = list(string)
  default = ["subnet-0a83aafdae67e1b3d", "subnet-01f7a4616367a07a2"] 
}

# 프라이빗 서브넷 ID 리스트
variable "private_subnet_ids" {
  type    = list(string)
  default = ["subnet-0d76bff127641129e", "subnet-09573ecc3e68ac7c2"] 
}

# Zabbix 서버를 위한 보안 그룹
resource "aws_security_group" "zabbix_sg" {
  name        = "zabbix_sg"
  description = "Allow traffic to Zabbix server"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 인스턴스 생성 및 User Data로 Zabbix 설치
resource "aws_instance" "zabbix" {
  ami                  = "ami-056a29f2eddc40520" # 원하는 AMI ID로 변경하세요
  instance_type        = "t3.small"
  subnet_id            = var.private_subnet_ids[0]
  iam_instance_profile = "AWSCloud9SSMInstanceProfile"

  vpc_security_group_ids = [aws_security_group.zabbix_sg.id]

  user_data = <<-EOF
#!/bin/bash
# Define the script content

script_content='
#!/bin/bash

# Redirect output to log file
exec > >(tee /root/userdata.log | logger -t userdata) 2>&1
echo "Starting User Data script execution"

# Wait for network to be available
while ! nc -z -v -w5 8.8.8.8 53; do
    echo "Waiting for network..."
    sleep 5
done

# Update system and install necessary packages
echo "Updating system and installing packages..."
apt-get update -y && apt-get install -y wget gnupg lsb-release

# Install Zabbix repository
echo "Installing Zabbix repository..."
wget https://repo.zabbix.com/zabbix/6.4/ubuntu/pool/main/z/zabbix-release/zabbix-release_6.4-1+ubuntu22.04_all.deb -O /root/zabbix-release.deb
dpkg -i /root/zabbix-release.deb
apt-get update -y

# Install Zabbix server, frontend, agent, and MySQL
echo "Installing Zabbix and MySQL packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent mysql-server

# Start and enable MySQL service
echo "Starting and enabling MySQL service..."
systemctl start mysql
systemctl enable mysql

# Secure MySQL installation
echo "Securing MySQL installation..."
MYSQL_ROOT_PASSWORD="rootpassword"
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';"
mysql -uroot -p$MYSQL_ROOT_PASSWORD -e "DELETE FROM mysql.user WHERE User='';"
mysql -uroot -p$MYSQL_ROOT_PASSWORD -e "DROP DATABASE IF EXISTS test;"
mysql -uroot -p$MYSQL_ROOT_PASSWORD -e "FLUSH PRIVILEGES;"

# Create Zabbix database and user
echo "Creating Zabbix database and user..."
ZABBIX_DB_PASSWORD="zabbixpassword"
mysql -uroot -p$MYSQL_ROOT_PASSWORD -e "CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"
mysql -uroot -p$MYSQL_ROOT_PASSWORD -e "CREATE USER 'zabbix'@'localhost' IDENTIFIED BY '$ZABBIX_DB_PASSWORD';"
mysql -uroot -p$MYSQL_ROOT_PASSWORD -e "GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';"
mysql -uroot -p$MYSQL_ROOT_PASSWORD -e "FLUSH PRIVILEGES;"

# Import Zabbix schema into the database
echo "Importing Zabbix schema..."
zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql -uzabbix -p$ZABBIX_DB_PASSWORD zabbix

# Configure Zabbix server
echo "Configuring Zabbix server..."
sed -i "s/^# DBPassword=.*$/DBPassword=$ZABBIX_DB_PASSWORD/" /etc/zabbix/zabbix_server.conf

# Restart Zabbix server and agent services
echo "Restarting Zabbix and related services..."
systemctl restart zabbix-server zabbix-agent apache2
systemctl enable zabbix-server zabbix-agent apache2

echo "User Data script completed successfully."
'
# END of Define the script content

# Save the script content to a file
echo "$script_content" > /root/user_data_script.sh

# Make the script executable (optional, if you want to run it manually later)
chmod +x /root/user_data_script.sh

# Execute the actual script content
bash /root/user_data_script.sh

  EOF

  tags = {
    Name = "Zabbix Server"
  }
}


# NLB 생성
resource "aws_lb" "nlb" {
  name               = "fnf-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = var.public_subnet_ids

  enable_deletion_protection = false
}

# NLB 타겟 그룹
resource "aws_lb_target_group" "nlb_tg" {
  name     = "nlb-tg"
  port     = 80
  protocol = "TCP"
  vpc_id   = var.vpc_id
  target_type = "alb"

  health_check {
    protocol            = "HTTP"
    port                = "80"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
  }
}

# NLB 리스너
resource "aws_lb_listener" "nlb_listener" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb_tg.arn
  }
}

resource "aws_lb_target_group_attachment" "nlb_attachment" {
  target_group_arn = aws_lb_target_group.nlb_tg.arn
  target_id        = aws_lb.alb.arn # ALB의 ARN을 사용하여 타겟으로 등록
}

# ALB 생성
resource "aws_lb" "alb" {
  name               = "fnf-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.zabbix_sg.id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = false
}

# ALB 타겟 그룹
resource "aws_lb_target_group" "alb_tg" {
  name     = "alb-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    protocol            = "HTTP"
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# ALB 리스너
resource "aws_lb_listener" "alb_listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_tg.arn
  }
}

# ALB 타겟 그룹에 EC2 인스턴스 등록
resource "aws_lb_target_group_attachment" "alb_attachment" {
  target_group_arn = aws_lb_target_group.alb_tg.arn
  target_id        = aws_instance.zabbix.id
  port             = 80
}
