#!/bin/bash
set -x
exec > >(tee /var/log/user-data.log|logger) 2>&1

log() { echo "[User-Data] $1"; }

log "Configuring 2GB Swap space for t3.micro..."
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

log "Updating system packages and installing prerequisites (unzip, curl, net-tools)..."
apt-get update -y && apt-get upgrade -y
apt-get install -y fontconfig openjdk-21-jre unzip curl net-tools groff

log "Installing official AWS CLI v2..."
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
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

log "Installing Jenkins prerequisites and Jenkins..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key | tee /etc/apt/keyrings/jenkins-keyring.asc > /dev/null
echo deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/ | tee /etc/apt/sources.list.d/jenkins.list > /dev/null
apt-get update -y && apt-get install -y jenkins
systemctl enable --now jenkins

log "Installing Nexus prerequisites (Java 17) and Nexus OSS..."
apt-get install -y openjdk-17-jre
cd /opt
useradd -r -M -d /opt/nexus -s /bin/false nexus || true
NEXUS_URL="https://download.sonatype.com/nexus/3/nexus-3.77.2-02-unix.tar.gz"
wget "$NEXUS_URL" -O nexus.tar.gz || wget "https://download.sonatype.com/nexus/3/latest-unix.tar.gz" -O nexus.tar.gz
tar -xvf nexus.tar.gz && rm -rf nexus && mv nexus-3* nexus && chown -R nexus:nexus /opt/nexus

# Configuring nexus user and forcing Java 17 usage
echo 'run_as_user="nexus"' > /opt/nexus/bin/nexus.rc
echo 'INSTALL4J_JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"' >> /opt/nexus/bin/nexus.rc
echo '-Dinstall4j.javaHome=/usr/lib/jvm/java-17-openjdk-amd64' >> /opt/nexus/bin/nexus.vmoptions

# Create native Systemd service for Nexus
cat << 'EOT' > /etc/systemd/system/nexus.service
[Unit]
Description=Nexus Service
After=syslog.target network.target

[Service]
Type=forking
LimitNOFILE=65536
ExecStart=/opt/nexus/bin/nexus start
ExecStop=/opt/nexus/bin/nexus stop
User=nexus
Group=nexus
Restart=on-failure

[Install]
WantedBy=multi-user.target
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

systemctl daemon-reload
systemctl enable --now nexus
systemctl enable --now sonarqube

log "Setting up daily shutdown cron job..."
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
echo "0 0 * * * root aws ec2 stop-instances --instance-ids $INSTANCE_ID --region $REGION" > /etc/cron.d/daily-shutdown
chmod 644 /etc/cron.d/daily-shutdown
log "Provisioning complete!"
