# Docker CI/CD GitHub actions workflow

Use the provided [scripts/setup_ghactions_aws.sh](scripts/setup_ghactions_aws.sh) to create ECR, ECS cluster, service, task definition, and IAM user that will be used in this GitHub Action:

```bash
user@DESKTOP-SCNMK3I UCRT64 ~/Documents/devops-exercise-from-local-to-cloud/github_actions/scripts (main)
Tue Oct 13 16:59:05
$ ./setup_ghactions_aws.sh
Usage: ./setup_ghactions_aws.sh {provision|teardown}

Options:
  provision : Creates ECR, ECS cluster, service, task definition, and IAM user for GitHub Actions.
  teardown  : Cleans up and deletes all created AWS resources (ECS, ECR, and IAM user).
```


![docker_cicd_github_actions](images/docker_cicd_github_actions.png)


![docker_cicd_github_actions_01](images/docker_cicd_github_actions_01.png)


