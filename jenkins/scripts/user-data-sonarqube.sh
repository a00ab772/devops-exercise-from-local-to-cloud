#!/bin/bash
set -x
exec > >(tee /var/log/user-data.log|logger) 2>&1

log() { echo "[User-Data] $1"; }

log "Configuring 1GB Swap space for t4g.small..."
fallocate -l 1G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

log "Updating system packages and installing prerequisites..."
apt-get update -y && apt-get upgrade -y
apt-get install -y fontconfig openjdk-21-jre unzip curl net-tools groff

log "Installing official AWS CLI v2 for ARM64..."
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "/tmp/awscliv2.zip"
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws

log "Downloading SonarQube from S3 bucket..."
useradd -r -M -d /opt/sonarqube -s /bin/bash sonarqube || true
aws s3 cp s3://jenkins-sonarqube-binaries-22254/sonarqube.zip /tmp/sonarqube.zip --region us-east-1
unzip -q /tmp/sonarqube.zip -d /tmp
rm -rf /opt/sonarqube
mv /tmp/sonarqube-* /opt/sonarqube
chown -R sonarqube:sonarqube /opt/sonarqube
chmod +x /opt/sonarqube/bin/linux-x86-64/sonar.sh
rm -f /tmp/sonarqube.zip

log "Tuning SonarQube JVM heap options for t4g.small..."
cat << 'EOT' >> /opt/sonarqube/conf/sonar.properties
sonar.web.javaOpts=-Xmx512m -Xms256m -XX:+UseG1GC
sonar.ce.javaOpts=-Xmx512m -Xms256m -XX:+UseG1GC
sonar.search.javaOpts=-Xmx512m -Xms256m -XX:+UseG1GC
EOT

cat << 'EOT' > /etc/systemd/system/sonarqube.service
[Unit]
Description=SonarQube service
After=syslog.target network.target

[Service]
Type=forking
ExecStart=/opt/sonarqube/bin/linux-x86-64/sonar.sh start
ExecStop=/opt/sonarqube/bin/linux-x86-64/sonar.sh stop
User=sonarqube
Group=sonarqube
Restart=always
LimitNOFILE=65536
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
EOT

chown -R sonarqube:sonarqube /opt/sonarqube
chmod +x /opt/sonarqube/bin/linux-x86-64/sonar.sh

systemctl daemon-reload
systemctl enable --now sonarqube

log "Setting up daily shutdown cron job..."
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
echo "0 0 * * * root aws ec2 stop-instances --instance-ids $INSTANCE_ID --region $REGION" > /etc/cron.d/daily-shutdown
chmod 644 /etc/cron.d/daily-shutdown
log "SonarQube provisioning complete!"
