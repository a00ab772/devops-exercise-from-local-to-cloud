pipeline {
    agent any

    tools {
        maven "Maven 3.8.7"
        jdk "JDK-21"
    }

    stages {
        stage('Fetch source code') {
            steps {
                git branch: 'main', url: 'https://github.com/a00ab772/devops-exercise-from-local-to-cloud.git'
            }
        }

        stage('Unit test') {
            steps {
                sh 'mvn test'
            }
        }

        stage('Build') {
            steps {
                sh 'mvn install -DskipTests'
            }

            post {
                success {
                    echo 'Archiving artifact'
                    archiveArtifacts artifacts: '**/*.war'
                }
            }
        }
    }
}