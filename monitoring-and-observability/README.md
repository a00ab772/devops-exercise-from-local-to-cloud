# Monitoring and Observability layers

There are 7 layers of monitoring:

1. Browser / Frontend Monitoring (Real User Monitoring - RUM)
2. Backend / Application Performance Monitoring (APM)
3. Infrastructure Monitoring
4. Synthetic Monitoring
5. Business / KPI Monitoring
6. Log Monitoring
7. Security Monitoring

Each monitoring layer serves a specific and complementary function, covering everything from user experience to security and business performance.

Integrating all these layers provides a comprehensive and proactive view of system health and reliability.

## 1. Browser / Frontend Monitoring (Real User Monitoring - RUM)

This layer focuses in real user experience, for example: "Track checkout page load time for users in Sweden".

* Metrics collected in this layer: 

  * Page load time (TTFB, FCP),
  * Core Web Vitals (LCP, FID, CLS),
  * JavaScript errors,
  * user navigation & clicks.

* Tools used in this layer:

  * Datadog RUM,
  * New Relic Browser,
  * Sentry,
  * Pingdom RUM.

## 2. Backend / Application Performance Monitoring (APM)

This layer focuses in Backend code and APIs, for example: "Trace API latency from NGINX to Java to MySQL".

* Metrics collected in this layer:

  * Response time,
  * throughput,
  * error rate,
  * database query performance,
  * external API latency,
  * end-to-end tracing.
  
* Tools used in this layer:

  * New Relic,
  * Datadog APM,
  * AppDynamics,
  * Dynatrace,
  * Elastic APM.

## 3. Infrastructure Monitoring

This layer focuses in servers, containers, and cloud resources, for example: "Alert when EC2 CPU usage exceeds 90% for 5 minutes".

* Metrics collected in this layer:

  * CPU,
  * memory,
  * disk,
  * network usage,
  * node health,
  * uptime,
  * pod/container status (Kubernetes)

* Tools used in this layer:

  * Prometheus + Grafana,
  * CloudWatch,
  * Datadog Infra,
  * Zabbix,
  * Nagios.

## 4. Synthetic Monitoring

This layer focuses in proactive performance and availability testing, for example: "Simulate user login from New York and London every 10 minutes".

* Types of synthetic metrics that business usually monitor are:

  * Availability checks (HTTP 200),
  * transaction flows (login to checkout),
  * API endpoint testing.

* Tools used in this layer:

  * Pingdom,
  * Checkly,
  * Datadog Synthetics,
  * CloudWatch Canaries.

## 5. Business / KPI Monitoring

This layer focuses in business performance metrics, for example: "Alert when checkout success rate drops below 95%".

* Metrics collected in this layer:

  * Signups per minute,
  * conversion rate,
  * failed payments,
  * daily active users.

* Tools used in this layer:

  * Mixpanel,
  * Amplitude,
  * Google Analytics,
  * Datadog (custom metrics).

## 6. Log Monitoring

This layer focuses in error detection, debugging, and trend analysis, for example: "Detect spike in TimeoutException logs after deployment".

* Metrics collected in this layer:

  * Error frequency,
  * request logs (status codes),
  * authentication failures.

* Tools used in this layer:

  * ELK Stack,
  * Loki + Grafana,
  * Splunk,
  * CloudWatch Logs.

## 7. Security Monitoring

This layer focuses in threat detection and compliance, for Example: "Detect login anomalies or suspicious access attempts".

* Metrics collected in this layer:

  * Unauthorized access attempts,
  * IAM anomalies,
  * intrusion detection.

* Tools used in this layer:

  * AWS GuardDuty,
  * Datadog Security,
  * Splunk Security,
  * Wazuh.

# Monitoring and Observability environment setup

The components that we will spin this lab are pretty much the same as you did in [../docker/README.md](../docker/README.md), but in addition we will spin up a Prometheus + Grafana EC2 instance, this is the architectural diagram:

![jenkins_cicd_in_docker_monitoring_and_observability.drawio.png](images/jenkins_cicd_in_docker_monitoring_and_observability.drawio.png)

 You can spin it up using the provided [scripts/docker_jenkins_cicd_monitoring_setup.sh](scripts/docker_jenkins_cicd_monitoring_setup.sh) script.

(WIP)