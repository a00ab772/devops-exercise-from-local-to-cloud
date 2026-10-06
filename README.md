# Project overview

This project is a comprehensive guide to setting up and managing a development environment to deploy a sample application from local to production.

It provides detailed instructions for both automated and manual provisioning methods, ensuring that developers can easily replicate the environment across different machines.


# Application Architecture

The application architecture consists of all these services, and we will be setting up them in this order:

* MySQL: A relational database management system that stores the application's data.
* Memcached: An in-memory key-value store used for caching frequently accessed data to improve application performance.
* RabbitMQ: A message broker that facilitates communication between different parts of the application.
* Tomcat: A Java Servlet container that hosts the web application.
* Nginx: A web server that serves static content and acts as a reverse proxy for the application.

![Application architecture diagram](images/architecture.drawio.png)

[(Source of the draw.io diagram)](./architecture.drawio)

# Local provisioning of the above Dynamic Web Architecture using Vagrant

This is how we can provision the above architecture locally using Vagrant, which allows us to create and manage virtual machines easily.

First, we will cover the manual provisioning method, which involves setting up each component of the architecture step-by-step. This method is useful for understanding the underlying processes and configurations involved in setting up the environment.

* [Local Manual Provisioning](./vagrant/Manual_provisioning/README.md)

Next, we will cover the automated provisioning method, which uses scripts to set up the entire environment with minimal user intervention. This method is useful for quickly replicating the environment across different machines and ensuring consistency in the setup.

* [Local Automated Provisioning](./vagrant/Automated_provisioning/README.md)

# Lift and shift AWS cloud provisioning of a Static Web Application

Before we move the project to the cloud, we will first deploy a static web application to AWS cloud using a lift and shift approach with a mix of manual and semi-automated provisioning methods via bash scripting. This will give us a better understanding of the required steps to deploy a web application in AWS cloud.

Let's do a step-by-step walkthrough of the process of deploying a static web application to AWS cloud using both manual and automated provisioning methods.

(IAAS: EC2, S3, RDS, VPC, IAM, Security Groups, Route53, CloudFront, ELB)

* [AWS Manual Provisioning](./aws/Manual_provisioning/README.md)

# Re-factoring AWS cloud provisioning of our Dynamic Web Application

(IAAC: Ansible, Terraform, CloudFormation)
(CI/CD: Jenkins, GitHub Actions, GitLab CI/CD, CircleCI, Travis CI)
(PAAS and SAAS: RDS, VPC, IAM, Security Groups, Route53, CloudFront, ELB, S3, EKS, ECR, ECS)

* [AWS Automated Provisioning](./aws/Automated_provisioning/README.md)

To be continued ....

# Kubernetes cloud provisioning


# GCP cloud provisioning

# Terraform GCP Automated Provisioning

...