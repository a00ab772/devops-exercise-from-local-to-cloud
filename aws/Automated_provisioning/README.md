# Re-factoring AWS cloud provisioning of our Dynamic Web Application

In this section we will cover the re-factoring (re-architecting) activities, in order to move our Dynamic Web Application from the local Vagrant environment ...:

![Application architecture diagram](../../images/architecture.drawio.png)

... to the AWS cloud environment:

![AWS cloud architecture diagram](../../images/architecture-aws.drawio.png)

Our objective is:

* to have a flexible and scalable archecture.

* without an upfront investment in hardware and software: it will be a pay-as-you-go model, which means that we will only pay for the resources that we use.

* To be provisioned as IAAC, PAAS and SAAS, which will allow us to automate the provisioning of the infrastructure, platform and software services, and to manage them as code.

* to be provisioned as CI/CD, which will allow us to automate the build, test and deployment of our application, and to manage them as code.

That will achieve low operational overhead, high availability, and high scalability of our application, which will allow us to focus on the development of our application, and not on the management of the infrastructure.

## Services that we will be using in AWS cloud environment in order to deploy our Dynamic Web Application

### Front-end services

* Beanstalk: for Tomcat and Nginx services, which will allow us to deploy and manage our web application easily. It will automatically handle the deployment, capacity provisioning, load balancing, and auto-scaling of our application.

* S3/EFS: for storing static content, which will allow us to store and retrieve our static files easily. S3 is a highly scalable object storage service that can store and retrieve any amount of data from anywhere on the web. EFS is a fully managed file storage service that can be used to store and share files across multiple instances.

### Back-end services

* RDS: A managed relational database service that makes it easy to set up, operate, backup, and scale a relational database in the cloud. It supports multiple database engines, including MySQL, PostgreSQL, Oracle, and SQL Server.

* Elasticache: A fully managed in-memory data store service that supports Redis and Memcached. It can be used to improve the performance of our application by caching frequently accessed data. It will take care of the memcached service, which will allow us to store and retrieve data quickly. It will automatically handle the scaling, patching, and backup of our cache.

* ActiveMQ: A managed message broker service that supports multiple messaging protocols, including AMQP, MQTT, and STOMP. It can be used to decouple our application components and improve the scalability and reliability of our application. It will take care of the RabbitMQ service, which will allow us to send and receive messages between our application components. It will automatically handle the scaling, patching, and backup of our message broker.

* Route53: A scalable and highly available domain name system (DNS) web service that translates domain names into IP addresses. It allows us to route traffic to our application resources, such as EC2 instances, S3 buckets, and load balancers.

* Cloudfront: A content delivery network (CDN) that securely delivers data, videos, applications, and APIs to customers globally with low latency and high transfer speeds. It uses a network of edge locations to cache content closer to the end-users, improving the performance and availability of our application.

