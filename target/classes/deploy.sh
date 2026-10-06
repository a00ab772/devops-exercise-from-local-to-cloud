#!/usr/bin/env bash
set -x
cd /tmp/
cd /tmp/devops-exercise-from-local-to-cloud/
export MAVEN_OPTS="-Xmx512m -XX:MaxMetaspaceSize=256m" && /usr/local/maven3.9/bin/mvn install
sudo systemctl stop tomcat
sudo rm -rf /usr/local/tomcat/webapps/ROOT*
sudo cp target/devops-exercise-from-local-to-cloud-v2.war /usr/local/tomcat/webapps/ROOT.war
sudo chown tomcat.tomcat /usr/local/tomcat/webapps -R
sudo systemctl start tomcat
