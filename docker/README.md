# Docker CI/CD Jenkins pipeline

In this section, we will provide a detailed explanation of how we implement Docker CI/CD automation for our web application on AWS using Jenkins.

![jenkins_cicd_in_docker.drawio.png](images/jenkins_cicd_in_docker.drawio.png)


# Docker CI/CD environment setup

The steps are pretty much the same as you did in [../jenkins/README.md](../jenkins/README.md), except that you don't need the Nexus server up and running so we will be spinning the Jenkins CI/CD infrastructure using the [](scripts/docker_jenkins_cicd_setup.sh)script:

```bash
user@DESKTOP-SCNMK3I UCRT64 ~/Documents/devops-exercise-from-local-to-cloud/docker/scripts (main)
Tue Oct 13 07:09:56
$ ./docker_jenkins_cicd_setup.sh provision
[2026-10-13 07:10:03] Checking/Creating Security Group...
[2026-10-13 07:10:05] Locating Security Group: jenkins-devsecops-sg...
[2026-10-13 07:10:06] Fetching your local public IP address...
[2026-10-13 07:10:07] Current local public IP resolved to: 89.6.2**.132/32
[2026-10-13 07:10:07] Revoking existing inbound rules...
[2026-10-13 07:10:08] Authorizing inbound access for your IP (89.6.2**.132/32) on ports 22, 8080, 9000...
[2026-10-13 07:10:11] Authorizing self-referencing internal traffic for ports 8080, 9000...
[2026-10-13 07:10:14] Security group successfully updated!
[2026-10-13 07:10:14] Checking/Configuring IAM Instance Profile...
[2026-10-13 07:10:22] Waiting for IAM instance profile propagation...
[2026-10-13 07:10:23] Checking/Creating IAM user 'jenkins'...
[2026-10-13 07:10:25] Attaching policies to IAM user 'jenkins'...
[2026-10-13 07:10:28] Generating Access Keys for 'jenkins' user...
----------------------------------------
Access Key ID:      AKIAWI**************252T
Secret Access Key:  3**************TQ/k****************HU
----------------------------------------
[2026-10-13 07:10:31] The zip file already exists in s3://jenkins-sonarqube-binaries-16422/. Skipping upload.
[2026-10-13 07:10:31] Fetching latest Ubuntu ARM64 AMI...
[2026-10-13 07:10:32] Waiting 10 seconds for IAM profile propagation...
[2026-10-13 07:10:42] Launching Instance 1: Jenkins Server (t4g.small)...
[2026-10-13 07:10:45] Launching Instance 2: SonarQube Server (t4g.small)...
[2026-10-13 07:10:47] Successfully provisioned all instances!
[2026-10-13 07:10:47] Jenkins Instance ID: i-0bb9c***********7539
[2026-10-13 07:10:47] SonarQube Instance ID: i-00****************6fc
```

Connect to the Jenkins url and install these plugins:

![docker_jenkins_01](images/docker_jenkins_01.png)

Continue with the configuration that you saw in [../jenkins/README.md](../jenkins/README.md), here shrunk in a small set of screenshots, go there for an extended explanation if required:

![docker_jenkins_02](images/docker_jenkins_02.png)

# ECR repository setup

This section covers the additional steps required to complete the Docker stage that we are going to add in this Jenkins pipeline.

![ecr_repo_setup](images/ecr_repo_setup.png)

Enter the AWS console and create an ECR repository:

![ecr_repo_setup_01](images/ecr_repo_setup_01.png)

Jenkins file will refer these three secrets that you need to store based in the above information:

![ecr_repo_setup_02](images/ecr_repo_setup_02.png)

Next, create a new Jenkins pipeline using the provided  [../jenkins_files/Jenkinsfile_ecr](../jenkins_files/Jenkinsfile_ecr) file:

![ecr_repo_setup_03](images/ecr_repo_setup_03.png)
