FROM maven:3.9.9-eclipse-temurin-21-jammy AS BUILD_IMAGE
RUN git clone https://github.com/a00ab772/devops-exercise-from-local-to-cloud.git
RUN cd devops-exercise-from-local-to-cloud && mvn install

FROM tomcat:10-jdk21

RUN rm -rf /usr/local/tomcat/webapps/*

COPY --from=BUILD_IMAGE devops-exercise-from-local-to-cloud/target/devops-exercise-from-local-to-cloud-v2.war /usr/local/tomcat/webapps/ROOT.war

EXPOSE 8080
CMD ["catalina.sh", "run"]