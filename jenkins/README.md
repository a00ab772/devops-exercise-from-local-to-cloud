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
[2026-10-09 12:17:19] Checking/Creating Security Group...
[2026-10-09 12:17:20] Checking/Configuring IAM Instance Profile...
[2026-10-09 12:17:22] Fetching latest Ubuntu AMI...
[2026-10-09 12:17:24] Launching EC2 Instance with 30GB gp3 storage...
[2026-10-09 12:17:26] Successfully provisioned instance ID: i-025b36f9e1a79af74

```

* Plugins installation.
* Integrate Nexus and SonarQube with Jenkins.
* Write the pipeline script.
* Set notification if pipeline fails.

