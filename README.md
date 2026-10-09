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

Let's do a step-by-step walkthrough of the process of deploying a static web application to AWS cloud using a lift-and-shift approach with an Infrastructure As A Service (IAAS) approach on which we will install and configure several services over these basic building blocks: EC2, S3, RDS, VPC, IAM, Security Groups, Route53, CloudFront, ELB.

* [AWS Manual Provisioning (IAAS: EC2, S3, RDS, VPC, IAM, Security Groups, Route53, CloudFront, ELB)](aws/lift-and-shift_provisioning/README.md)

# Re-factoring AWS cloud provisioning of our Dynamic Web Application

In this section we will re-factor the previous deployment, replacing the Infrastructure services for AWS Services.

Let's do a step by step walkthrought of the process deploying the static web application to AWS cloud using a PAAS approach where we will deploy:

. Elastic Beanstalk, and EFS as part of the front end services.
. RDS, Amazon MQ and ElastiCache as part of the backend services.
. Route 53 and CloudFront as part of the networking and Content Delivery services. 

* [AWS Re-factor (re-architect) provisioning](aws/re-factor_provisioning/README.md)

# Continuous Integration

(CI/CD: Jenkins, GitHub Actions, GitLab CI/CD, CircleCI, Travis CI)

## Jenkins

[CI/CD using Jenkins](jenkins/README.md)

To be continued ....

(IAAC: Ansible, Terraform, CloudFormation)
(PAAS and SAAS: RDS, VPC, IAM, Security Groups, Route53, CloudFront, ELB, S3, EKS, ECR, ECS)

# Kubernetes cloud provisioning


# GCP cloud provisioning

# Terraform GCP Automated Provisioning

...