#!/bin/bash
exec > >(tee /var/log/user-data.log|logger) 2>&1

log() { echo "[User-Data] $1"; }

log "Configuring 2GB Swap space for t3.micro..."
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

log "Updating system packages..."
apt-get update -y && apt-get upgrade -y
apt-get install -y fontconfig openjdk-17-jre

log "Installing Jenkins..."
wget -O /usr/share/keyrings/jenkins-keyring.asc https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key
echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/ | tee /etc/apt/sources.list.d/jenkins.list > /dev/null
apt-get update -y && apt-get install -y jenkins
systemctl enable jenkins && systemctl start jenkins

log "Installing Nexus OSS..."
cd /opt
useradd -r -M -d /opt/nexus -s /bin/false nexus
wget https://download.sonatype.com/nexus/3/nexus-latest-unix.tar.gz -O nexus.tar.gz
tar -xvf nexus.tar.gz && mv nexus-3* nexus && chown -R nexus:nexus /opt/nexus
echo 'run_as_user="nexus"' > /opt/nexus/bin/nexus.rc
ln -s /opt/nexus/bin/nexus /etc/init.d/nexus
update-rc.d nexus defaults && systemctl start nexus

log "Setting up daily shutdown cron job..."
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
echo "0 0 * * * root aws ec2 stop-instances --instance-ids $INSTANCE_ID --region $REGION" > /etc/cron.d/daily-shutdown
chmod 644 /etc/cron.d/daily-shutdown
log "Provisioning complete!"
