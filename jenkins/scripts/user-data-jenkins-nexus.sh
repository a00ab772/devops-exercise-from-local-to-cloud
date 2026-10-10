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

echo 'run_as_user="nexus"' > /opt/nexus/bin/nexus.rc
echo 'INSTALL4J_JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"' >> /opt/nexus/bin/nexus.rc
echo '-Xms512m' >> /opt/nexus/bin/nexus.vmoptions
echo '-Xmx512m' >> /opt/nexus/bin/nexus.vmoptions
echo '-Dinstall4j.javaHome=/usr/lib/jvm/java-17-openjdk-amd64' >> /opt/nexus/bin/nexus.vmoptions

chown -R nexus:nexus /opt/nexus
mkdir -p /opt/sonatype-work
chown -R nexus:nexus /opt/sonatype-work

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
RestartSec=10

[Install]
WantedBy=multi-user.target
EOT

systemctl daemon-reload
systemctl enable --now nexus

log "Setting up daily shutdown cron job..."
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
echo "0 0 * * * root aws ec2 stop-instances --instance-ids $INSTANCE_ID --region $REGION" > /etc/cron.d/daily-shutdown
chmod 644 /etc/cron.d/daily-shutdown
log "Jenkins & Nexus provisioning complete!"
