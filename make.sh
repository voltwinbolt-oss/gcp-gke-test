#!/bin/bash

# ABOUT
#   this ( subshell ) script  redirects output to final yaml
#

# BEFORE RUNNING make.sh
# export JENKINS_HOST="your.jenkins.fqdn"

# yamls=$(ls | grep yaml | grep -v "jenkins.yaml")
# order matters

yamls="jenkins-namespace.yaml jenkins-pvc.yaml jenkins-deployment.yaml jenkins-service.yaml jenkins-ingress.yaml"
(
for yaml in $yamls; do
  eval "cat <<EOF
$(cat manifests/"$yaml")
EOF"
  echo "---"
done
) > jenkins.yaml
