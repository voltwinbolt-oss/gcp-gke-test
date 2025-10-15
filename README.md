# README 

## Topics:

- setup of GoogleCloudPlatform (GCP) standard GoogleKubernetesEnterprise (GKE) test cluster
- deployment of jenkins with TLS in GKE

## Prerequisites:

- I used debian trixie vm with bind9-dnsutils for `dig` command
- google-cloud-sdk https://cloud.google.com/sdk/docs/install 
- gcloud init successfully completed and authenticated against the GoogleCloudPlatform account

> Now we are ready to begin with the GKE setup and Jenkins deployment

## Initialize

1. Vars
```
export GCLOUD_USER=""
export PROJECT_ID=""
export PROJECT_NAME="devel"
export REGION=europe-north1
export ZONE=${REGION}-a
export JENKINS_HOST="A-record.fqdn"
export REPO="${PROJECT_NAME}-repo"
```


2. Create project

```
gcloud projects create ${PROJECT_ID} \
  --name="$PROJECT_NAME" \
  --set-as-default
```

3. Set quota project and enable billing (required to deploy GKE)

```
gcloud auth application-default set-quota-project ${PROJECT_ID}
gcloud config get-value project
# ^ verify the current default project is set to the new project
```
then, visit the billing for the project to enable it
https://console.cloud.google.com/billing/linkedaccount?project= <$PROJECT_ID>
Once billing enabled, create the gke-standard


## GKE

1. Create GKE standard
```
gcloud container clusters create $CLUSTER_NAME \
  --num-nodes=3 \
  --machine-type=e2-medium \
  --project=${PROJECT_ID} \
  --zone=${ZONE}
```

2. verify kube config context points to the GKE cluster

`kubectl config get-contexts`


3. Test ssh access

```
test_instance=$(gcloud compute instances list | awk '{print $1}'|grep -v NAME|head -1)
gcloud compute ssh ${test_instance} --zone=$ZONE
```

4. Label nodes

```
nodes=($(kubectl get nodes -o wide|awk '{print $1}'|grep -v NAME))
count="${#nodes[*]}"
labels="apps apps ci"

for label in $labels; do \
  count=$(( count-1 )); \
  echo "count = $count"; \
  kubectl label node ${nodes[$count]} purpose=${label};
done
```

then, verify "purpose" label present

```
for node in ${nodes[*]}; do \
  echo -e "\n$node checking purpose label present "; \
  kubectl get node $node --show-labels | grep --color -oe "purpose....";
done
```

## TLS
> see Footnotes for why I picked Let's Encrypt option at this time

1. Install nginx ingress controller
```
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.3/deploy/static/provider/cloud/deploy.yaml
```

verify pods completed / running 
`kubectl get pods -n ingress-nginx`

2. Install cert manager
```
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.0/cert-manager.yaml
```

verify pods completed / running 
`kubectl get pods -n cert-manager`


3. apply ClusterIssuer
```
cat >> cert-manager.yaml <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-http
spec:
  acme:
    email: $GCLOUD_USER
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-http-key
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

kubectl apply -f cert-manager.yaml
```



## Jenkins 

1. Create an A record -> EXTERNAL-IP for `$JENKINS_HOST` at the DNS hosting provider (i use ClouDNS)
```
EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx | awk '{print $4}'|grep -v EXTERNAL)
echo $EXTERNAL_IP
```

2. Deploy jenkins workload

```
git clone https://github.com/voltwinbolt-oss/gcp-gke-test/ && cd gcp-gke-test
bash make.sh
kubectl apply -f jenkins.yaml
```

Wait for the pods to go live and ready
get logs on the jenkins in the jenkins namespace to retrieve
the initial password and navigate to the URL it should be up


### Configure image registry
1. Enable artifact type of registry
```
gcloud services enable artifactregistry.googleapis.com
```

> TODO: Struggled with artifactory authentication / permissions
> need to clean this up to remove duplicate / unnecessary steps

```
for role in \
  artifactregistry.reader \
  artifactregistry.writer \
  artifactregistry.repoAdmin \
  artifactregistry.admin; \
do \
  echo -e "\n$role" && \
  gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="user:${GCLOUD_USER}"  --role=roles/${role};
done


gcloud artifacts repositories create $REPO \
  --repository-format=docker \
  --location=$REGION \
  --description="$REPO image registry"


gcloud auth configure-docker ${REGION}-docker.pkg.dev

gcloud auth configure-docker

gcloud auth print-access-token | docker login \
  -u oauth2accesstoken --password-stdin \
  https://${REGION}-docker.pkg.dev
```

2. Confirm get-iam-policy does not get Permission Denied
```
gcloud artifacts repositories get-iam-policy ${REPO} \
  --location=${REGION} \
  --project=${PROJECT_ID}
```

3. Tag and push image
```
docker tag test ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/test:2285

docker push ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/test:2285
```

4. Verification

```
gcloud artifacts docker images list ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}
gcloud artifacts repositories list

# Delete Repository
# gcloud artifacts repositories delete ${REPO} \
#  --location=$REGION \
```


### optional dependencies

build agent with policy to access artifactory

1. select size, like e2-standard-2 cpu 2 ram 4G 
```
gcloud compute instances create testbox \
  --zone=${ZONE} \
  --machine-type=e2-standard-2 \
  --image-family=debian-13 \
  --image-project=debian-cloud
```

`gcloud compute ssh testbox --zone=$ZONE`


2. add jenkins user to iam for artifactory pushes
```
gcloud iam service-accounts create jenkins-user

3. assign roles to jenkins-user
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="serviceAccount:jenkins-user@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.writer"

4. get credential
gcloud iam service-accounts keys create ~/artifactory-key.json \
  --iam-account=jenkins-user@${PROJECT_ID}.iam.gserviceaccount.com



## Footnotes / References

> I have not used GCP/GKE prior, and found it to be 
> a good opportunity to explore GoogleCloudPlatform

#### GCP introduction 
https://cloud.google.com/kubernetes-engine/docs/about

https://cloud.google.com/kubernetes-engine/docs/learn

#### Quickstart example, helpful to dive into GKE general concepts on CLI
https://github.com/GoogleCloudPlatform/bank-of-anthos

#### INGRESS
Ingress is a well deserved dedicated section in references
Helpful detour for issue with ingress load balancer not assigning external ip
https://cloud.google.com/kubernetes-engine/docs/concepts/ingress

#### TLS:  Using Google-managed SSL certificates
https://cloud.google.com/kubernetes-engine/docs/how-to/managed-certs

> after "nn" hours of attempting to resolve the cert provisioning via
> Google-managed certificates and following the above link precisely as
> documented with valid values, and debugging - I've decided to try a
> different approach with Let's Encrypt - and voila it worked out the box.
> For the purposes of this project I've tabled for now the research on 
> Google-managed certs for TLS approach in favor of robust Let's Encrypt

#### TLS: Using Let's Encrypt with ingress-nginx

https://cert-manager.io/docs/

https://cert-manager.io/docs/configuration/acme/

https://cert-manager.io/docs/usage/ingress/

https://github.com/kubernetes/ingress-nginx/tags