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

# Local provisioning using Vagrant

* [Local Manual Provisioning](./vagrant/Manual_provisioning/README.md)

* [Local Automated Provisioning](./vagrant/Automated_provisioning/README.md)

# AWS cloud provisioning

* [AWS Manual Provisioning](./aws/Manual_provisioning/README.md)

* [AWS Automated Provisioning](./aws/Automated_provisioning/README.md)

To be continued ....

# Kubernetes cloud provisioning


# GCP cloud provisioning

# Terraform GCP Automated Provisioning

...