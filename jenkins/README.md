# CI/CD using Jenkins

In this section, we will provide a detailed explanation of how we implement CI/CD automation for our web application on AWS using Jenkins.

![jenkins_continuous_integration.drawio.png](images/jenkins_continuous_integration.drawio.png)

# Jenkins CI setup

You can use the provided [jenkins_cicd_setup.sh](scripts/jenkins_cicd_setup.sh) bash script to provision a free tier ubuntu host with 30Gb of disk. The script will take care on your behalf of the following items:

* Jenkins setup.
* Nexus setup.
* SonarQube setup.
* Security Group configuration.

```bash

user@DESKTOP-SCNMK3I UCRT64 ~/Documents/devops-exercise-from-local-to-cloud/jenkins/scripts (main)
Fri Oct 09 12:15:57
$ ./jenkins_cicd_setup.sh
Usage: ./jenkins_cicd_setup.sh {provision|teardown}

user@DESKTOP-SCNMK3I UCRT64 ~/Documents/devops-exercise-from-local-to-cloud/jenkins/scripts (main)
Fri Oct 09 12:17:16
$ ./jenkins_cicd_setup.sh provision
[2026-10-09 17:30:46] Checking/Creating Security Group...
[2026-10-09 17:30:49] Fetching your public IP address...
[2026-10-09 17:30:49] Restricting inbound access to your IP: 8*.**6.240.132/32
[2026-10-09 17:30:49] Opening inbound ports...
[2026-10-09 17:30:55] Checking/Configuring IAM Instance Profile...
[2026-10-09 17:31:02] Waiting for IAM instance profile propagation...
[2026-10-09 17:31:05] The zip file already exists in the s3://jenkins-sonarqube-binaries-22851/ S3 bucket and it is accessible. We skip the upload to save costs.
[2026-10-09 17:31:05] Fetching latest Ubuntu AMI...
[2026-10-09 17:31:06] Waiting 10 seconds for IAM profile propagation to EC2...
[2026-10-09 17:31:16] Launching EC2 Instance with 30GB gp3 storage...
[2026-10-09 17:31:19] Successfully provisioned instance ID: i-063***********1dc

```

Connect to the instance and check the memory consumption:

```bash
user@DESKTOP-SCNMK3I UCRT64 ~/Documents/devops-exercise-from-local-to-cloud/jenkins/scripts (main)
Fri Oct 09 12:19:13
$ aws ec2-instance-connect ssh --instance-id i-025b36f9e1a79af74 --os-user ubuntu --connection-type direct

$ top

ubuntu@ip-172-***-**1-12:~$ sudo ss -tulpn
Netid                 State                  Recv-Q                 Send-Q                                      Local Address:Port                                   Peer Address:Port                 Process
udp                   UNCONN                 0                      0                                              127.0.0.54:53                                          0.0.0.0:*                     users:(("systemd-resolve",pid=333,fd=16))
udp                   UNCONN                 0                      0                                           127.0.0.53%lo:53                                          0.0.0.0:*                     users:(("systemd-resolve",pid=333,fd=14))
udp                   UNCONN                 0                      0                                       172.31.41.12%ens5:68                                          0.0.0.0:*                     users:(("systemd-network",pid=531,fd=21))
udp                   UNCONN                 0                      0                                               127.0.0.1:323                                         0.0.0.0:*                     users:(("chronyd",pid=783,fd=5))
udp                   UNCONN                 0                      0                                                   [::1]:323                                            [::]:*                     users:(("chronyd",pid=783,fd=6))
tcp                   LISTEN                 0                      4096                                           127.0.0.54:53                                          0.0.0.0:*                     users:(("systemd-resolve",pid=333,fd=17))
tcp                   LISTEN                 0                      4096                                              0.0.0.0:22                                          0.0.0.0:*                     users:(("sshd",pid=8017,fd=3),("systemd",pid=1,fd=88))
tcp                   LISTEN                 0                      4096                                        127.0.0.53%lo:53                                          0.0.0.0:*                     users:(("systemd-resolve",pid=333,fd=15))
tcp                   LISTEN                 0                      4096                                                 [::]:22                                             [::]:*                     users:(("sshd",pid=8017,fd=4),("systemd",pid=1,fd=89))

```

sudo tail -f /var/log/user-data.log
sudo journalctl -u jenkins.service -n 50 --no-pager
sudo journalctl -u nexus.service -n 50 --no-pager
sudo journalctl -u sonarqube.service -n 50 --no-pager


![jenkins_cicd_ec2](images/jenkins_cicd_ec2.png)

* Plugins installation.
* Integrate Nexus and SonarQube with Jenkins.
* Write the pipeline script.
* Set notification if pipeline fails.

