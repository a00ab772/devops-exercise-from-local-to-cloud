#!/bin/bash
set -ex

apt-get update -y
apt-get install -y curl gnupg apt-transport-https wget ncat

curl -1sLf "https://github.com/rabbitmq/signing-keys/releases/download/2.0.0/rabbitmq.release-signing-key.asc" | gpg --dearmor | tee /usr/share/keyrings/rabbitmq.gpg > /dev/null
curl -1sLf "https://github.com/rabbitmq/signing-keys/releases/download/2.0.0/rabbitmq-server-release.gpg" | gpg --dearmor | tee /usr/share/keyrings/rabbitmq-server-release.gpg > /dev/null

echo "deb [signed-by=/usr/share/keyrings/rabbitmq-server-release.gpg] https://ppa1.rabbitmq.com/rabbitmq/rabbitmq-server/deb/ubuntu jammy main" > /etc/apt/sources.list.d/rabbitmq.list
echo "deb-src [signed-by=/usr/share/keyrings/rabbitmq-server-release.gpg] https://ppa1.rabbitmq.com/rabbitmq/rabbitmq-server/deb/ubuntu jammy main" >> /etc/apt/sources.list.d/rabbitmq.list

apt-get update -y
apt-get install -y rabbitmq-server

systemctl enable --now rabbitmq-server

sh -c 'echo "[{rabbit, [{loopback_users, []}]}]." > /etc/rabbitmq/rabbitmq.config'
rabbitmqctl add_user test test
rabbitmqctl set_user_tags test administrator
rabbitmqctl set_permissions -p / test ".*" ".*" ".*"

ufw allow 5672/tcp
systemctl restart rabbitmq-server
systemctl status rabbitmq-server