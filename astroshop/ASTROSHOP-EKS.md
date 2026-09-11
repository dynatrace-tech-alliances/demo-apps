# OpenTelemetry Demo on Amazon EKS

Deploy the [OpenTelemetry Astroshop Demo App](https://opentelemetry.io/docs/demo/kubernetes-deployment/) to Amazon EKS with a managed EC2 node group, an internet-facing Application Load Balancer (ALB), Route 53 DNS, and ACM TLS. The public entry point is `frontend-proxy`; it serves the store, `/feature`, `/grafana/`, `/jaeger/ui/`, and `/otlp-http/`.

This guide implements the relevant Kubernetes-deployment steps from the OpenTelemetry Demo documentation, adapted for AWS. The source chart does not support in-place upgrades: uninstall and reinstall when changing the chart version.

All commands in this guide are run from the `astroshop/` directory. The `.env` file and all generated files live there.

## 1. Prerequisites

The application requires Kubernetes 1.24+ and 6 GiB of available memory. This guide creates a `t3.xlarge` managed node (4 vCPU, 16 GiB), leaving room for Kubernetes and AWS components.

Install and authenticate these tools before starting:

```sh
aws --version
kubectl version --client
eksctl version
helm version
aws sts get-caller-identity
```

Versions used in testing
```
AWS CLI	    v2.36.23 
kubectl	    v1.35.4 
Kustomize	v5.7.1 
eksctl	    v0.230.0 
Helm	    v4.1.4
```

## 2. Set ENV file values

Set values for this deployment. Replace `us-east-1` if you want another Region. The Route 53 hosted zone must be public and managed by the AWS account or role you use here.

Copy and set these values into a `.env` file:
```
# Value from `aws sts get-caller-identity --query Account --output text` command
AWS_ACCOUNT_ID=1234

# Adjust region or leave this value
AWS_REGION=us-east-1

# Your custom name for cluster and node group
CLUSTER_NAME=servicenow-demo-apps
NODEGROUP_NAME=servicenow-demo-apps-nodegroup

# Public hostname for the demo (must be under your Route 53 hosted zone)
DEMO_DOMAIN_NAME=otel-demo.tae.dynatracelabs.com

# Value for the OpenTelemetry Collector exporter
DT_ENDPOINT=https://{your-env-id}.live.dynatrace.com/api/v2/otlp
DT_API_TOKEN=dt0c01.SAMPLE_TOKEN
```

NOTE:
* `DT_API_TOKEN` requires the **openTelemetryTrace.ingest**, **metrics.ingest**, and **logs.ingest** scopes. See [Dynatrace OTLP export authentication](https://docs.dynatrace.com/docs/shortlink/otel-getstarted-otlpexport#authentication-export-to-activegate) for how to create the token.
* `DEMO_DOMAIN_NAME` is the public name you choose for this demo; it does not come from the load balancer. Choose an unused hostname under your hosted zone now, such as `otel-demo.tae.dynatracelabs.com`. Do not create its Route 53 `A` alias record yet. Step 6 adds an ACM validation CNAME for this chosen hostname, step 7 creates the ALB through the ingress, and step 8 points the chosen hostname at that ALB. For a cluster hosting multiple independently managed demos, use a friendly single-label hostname per application:

  ```text
  otel-demo.tae.dynatracelabs.com    -> OpenTelemetry Demo frontend-proxy
  easytrade.tae.dynatracelabs.com    -> EasyTrade public UI service
  another-demo.tae.dynatracelabs.com -> That demo's public frontend service
  ```

## 3. Create EKS Cluster

This guide intentionally creates a separate ALB for the OpenTelemetry Demo. Do not add `alb.ingress.kubernetes.io/group.name` to the ingress annotations: without an ingress group, the AWS Load Balancer Controller creates an ALB and target group dedicated to this app's `frontend-proxy` service. A wildcard ACM certificate for `*.tae.dynatracelabs.com` covers these single-label hostnames when a shared certificate is appropriate.

### Create EKS Cluster

The command below uses the default currently supported EKS Kubernetes version selected by `eksctl`, which satisfies the demo's Kubernetes 1.24+ requirement.

```sh
create-eks-cluster.sh
```

Verify the cluster is active before proceeding:

```sh
aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query "cluster.status" \
  --output text
```

Expect `ACTIVE`.

### Configure kubectl

Once Cluster available, configure `kubectl` and verify that the node is ready:

```sh
set -a
source .env
set +a

aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"
kubectl config current-context
kubectl get nodes
kubectl get pods -A
```

## 4. Configure EBS Storage

EKS clusters on Amazon Linux do not include the EBS CSI driver or a working default StorageClass out of the box. The Dynatrace ActiveGate requires a PersistentVolume, so this must be in place before connecting Dynatrace in the next step.

### Create IAM role for EBS CSI driver

Create the IAM role the driver uses to call the EC2 API:

```sh
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --role-only \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve
```

### Install the EBS CSI driver

Install the addon and wait for it to be active:

```sh
aws eks create-addon \
  --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/AmazonEKS_EBS_CSI_DriverRole"

aws eks wait addon-active \
  --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --addon-name aws-ebs-csi-driver
```

### Verify the driver pods are running:

```sh
kubectl -n kube-system get pods | grep ebs
```

Expect `ebs-csi-controller-*` and `ebs-csi-node-*` pods in `Running` state.

### Create a default StorageClass

The legacy `gp2` StorageClass uses the in-tree `kubernetes.io/aws-ebs` provisioner, which is disabled on EKS 1.23+. Create a `gp3` StorageClass using the CSI provisioner and mark it as the cluster default:

```sh
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
EOF
```

Confirm `gp3` is marked as default:

```sh
kubectl get storageclass
```

## 5. Connect Dynatrace to the EKS Cluster

Connect Dynatrace to the cluster for platform-level observability (nodes, pods, workloads). Follow the Dynatrace UI wizard — it generates the exact commands for your environment.

1. In Dynatrace, open the search and search for **Kubernetes**
2. Click **Add cluster**
3. Under deployment type select **Platform Observability**
4. Under cloud provider select **EKS**
5. Follow the on-screen steps — the wizard generates a `helm install` command for the operator and a `dynakube.yaml` manifest for the DynaKube CR
6. **Before applying `dynakube.yaml`**, make the following EKS-specific adjustments. Without them the ActiveGate will fail to pull its image and the node config collector will get stuck on Amazon Linux nodes.

   **a. Use public ECR for the Helm install**

   The default `helm install` generated by the wizard pulls from Dynatrace's private ECR registry, which your AWS account cannot access. Replace it with the public ECR source:

   ```sh
   helm install dynatrace-operator oci://public.ecr.aws/dynatrace/dynatrace-operator \
     --create-namespace --namespace dynatrace --wait --cleanup-on-fail
   ```

   Note: `--atomic` is deprecated in Helm 4. Use `--wait --cleanup-on-fail` instead, which is equivalent.

   **b. Pin the ActiveGate image to public ECR in `dynakube.yaml`**

   The `use-public-registry` annotation does not reliably redirect ActiveGate images in all operator versions. Set the image explicitly under `activeGate:`. Find the version tag from the wizard-generated YAML or the operator logs, then add:

   ```yaml
   activeGate:
     image: public.ecr.aws/dynatrace/dynatrace-activegate:<tag>
     capabilities:
       - kubernetes-monitoring
   ```

   **c. Remove the AppArmor path from `kspm.mappedHostPaths` in `dynakube.yaml`**

   Amazon Linux 2 / AL2023 nodes do not have `/sys/kernel/security/apparmor` (they use SELinux, not AppArmor). If this path is present the `node-config-collector` pod will stay in `ContainerCreating`. Remove it from the list:

   ```yaml
   kspm:
     mappedHostPaths:
       - /boot
       - /etc
       - /proc/sys/kernel
       - /sys/fs
       # /sys/kernel/security/apparmor  <-- remove this line on Amazon Linux EKS nodes
       - /usr/lib/systemd/system
       - /var/lib
   ```

   Apply the edited `dynakube.yaml`:

   ```sh
   kubectl apply -f dynakube.yaml
   ```

7. Verify the cluster appears in **Kubernetes** with nodes and workloads reporting.

See [Dynatrace Platform Observability for Kubernetes](https://docs.dynatrace.com/docs/ingest-from/setup-on-k8s/deployment/platform-observability) for reference.

## 6. Use the AWS Load Balancer Controller

The controller turns the Kubernetes ingress below into an internet-facing ALB. It needs AWS IAM permissions and an IAM role associated with its Kubernetes service account. Do not grant broad ELB permissions to the EKS node role as a workaround.

First, check whether your platform team has already installed the controller on this cluster:

```sh
kubectl -n kube-system get deployment aws-load-balancer-controller
kubectl -n kube-system get serviceaccount aws-load-balancer-controller
```

If both commands return resources and the deployment is available, also verify the IAM role trust policy references **this cluster's** OIDC provider — the role may have been created for a different cluster and will silently fail to provision the ALB:

```sh
# Get this cluster's OIDC ID
OIDC_ID=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query "cluster.identity.oidc.issuer" \
  --output text | awk -F'/' '{print $NF}')

# Confirm the role trust policy contains that OIDC ID
aws iam get-role \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --query "Role.AssumeRolePolicyDocument.Statement[].Principal" \
  --output json | grep "$OIDC_ID"
```

If `grep` returns nothing, the trust policy points at a different cluster. Update it before continuing:

```sh
aws iam update-assume-role-policy \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Principal\": {
        \"Federated\": \"arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/${OIDC_ID}\"
      },
      \"Action\": \"sts:AssumeRoleWithWebIdentity\",
      \"Condition\": {
        \"StringEquals\": {
          \"oidc.eks.us-east-1.amazonaws.com/id/${OIDC_ID}:sub\": \"system:serviceaccount:kube-system:aws-load-balancer-controller\",
          \"oidc.eks.us-east-1.amazonaws.com/id/${OIDC_ID}:aud\": \"sts.amazonaws.com\"
        }
      }
    }]
  }"

kubectl -n kube-system rollout restart deployment/aws-load-balancer-controller
kubectl -n kube-system rollout status deployment/aws-load-balancer-controller
```

If the trust policy is correct, skip the rest of this section. The existing controller will reconcile the demo ingress.

If either resource is absent and you do not have IAM permissions to create an IAM service account, ask the cluster/platform team to perform the following bootstrap. This is a one-time shared-cluster operation; you continue at step 6 after they confirm the controller is available. They should reuse the existing `AWSLoadBalancerControllerIAMPolicy` if it exists, rather than creating a duplicate.

### Add policy 

```sh
export LBC_VERSION=v2.11.0

aws iam get-policy \
  --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy"
```

If the policy lookup returns `NoSuchEntity`, the platform team creates it from the controller version's published policy:

```sh
curl -fsSLO \
  "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${LBC_VERSION}/docs/install/iam_policy.json"

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json
```

### Add IAM service account

See if the IAM role exists:

```
aws iam list-attached-role-policies \
>   --role-name AmazonEKSLoadBalancerControllerRole
```

#### If does not exist

then this will:
* create Creates IAM role
* Attaches policy to role
* Creates K8s service account
* Annotates service account

The platform team then creates the IAM service account and installs the controller. Keep the IAM policy and Helm controller versions aligned.

NOTE: The `eksctl create iamserviceaccount` command requires permission to create IAM roles and attach policies. It is intentionally not a required command for the person deploying this demo when the controller is shared.

```sh
export LBC_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy"

eksctl create iamserviceaccount \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn "$LBC_POLICY_ARN" \
  --approve
```

#### If does exist

then this will:
* Creates K8s service account
* Annotates service account

```sh
kubectl create serviceaccount aws-load-balancer-controller \
  -n kube-system

kubectl annotate serviceaccount aws-load-balancer-controller \
  -n kube-system \
  eks.amazonaws.com/role-arn="$LBC_POLICY_ARN"
```

## Add the Load Balancer

```sh
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

kubectl -n kube-system rollout status deployment/aws-load-balancer-controller
```

## 7. Request and validate the TLS certificate

Request an ACM certificate in the same Region as the EKS ALB. ACM returns a CNAME record that must be added to the Route 53 hosted zone before it can issue the certificate.

### Generate new Certificate

```sh
export CERTIFICATE_ARN=$(aws acm request-certificate \
  --region "$AWS_REGION" \
  --domain-name "$DEMO_DOMAIN_NAME" \
  --validation-method DNS \
  --query CertificateArn \
  --output text)

# verify have value
aws acm describe-certificate \
  --region "$AWS_REGION" \
  --certificate-arn "$CERTIFICATE_ARN" \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord' \
  --output json
```

### Update Route53 with new Certificate

From the AWS Console in Route53

Create the returned CNAME record in the `tae.dynatracelabs.com` public hosted zone. 

Can monitor in the console, or wait until ACM reports `ISSUED` with this command:
```sh
aws acm wait certificate-validated \
  --region "$AWS_REGION" \
  --certificate-arn "$CERTIFICATE_ARN"
```

## 8. Configure and install the OpenTelemetry Demo

The `/` ingress path routes all traffic — including `/feature` — through `frontend-proxy`, so no separate ingress is needed for the feature-flag UI. `PUBLIC_OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` must be the public URL because browser JavaScript cannot reach cluster-internal DNS; spans go to `/otlp-http/v1/traces` on the public ingress where `frontend-proxy` forwards them to the collector ([Kubernetes deployment docs](https://opentelemetry.io/docs/demo/kubernetes-deployment/)).

NOTE: The `otel-demo-values.yaml.template` is committed alongside this guide. It is a custom file assembled from several sources: 
* the ingress and frontend sections are adapted from the [OTel demo Kubernetes deployment docs](https://opentelemetry.io/docs/demo/kubernetes-deployment/), with AWS ALB annotations added for EKS
* the collector exporter and pipeline config follows the [Dynatrace OTel collector configuration guide](https://docs.dynatrace.com/docs/ingest-from/opentelemetry/collector/configuration)
* the `k8sattributes` enrichment setup follows the [Dynatrace K8s enrichment guide](https://docs.dynatrace.com/docs/ingest-from/opentelemetry/collector/use-cases/kubernetes/k8s-enrich). Edit the template directly when any of those change, then re-run the substitution below.

### Make namespace and secret with credentials

The namespace is created before the secret so the collector can read credentials at pod startup; the API token is never written to the values file or image.

```sh
set -a
source .env
set +a

kubectl create namespace otel-demo

kubectl create secret generic dynatrace-otelcol-dt-api-credentials \
  --namespace otel-demo \
  --from-literal=DT_ENDPOINT="${DT_ENDPOINT}" \
  --from-literal=DT_API_TOKEN="${DT_API_TOKEN}" \
  --from-literal=CLUSTER_NAME="${CLUSTER_NAME}"
```

### Generate otel-demo-values

Generate `otel-demo-values.yaml` from the committed template by substituting the two deployment-specific values:

```sh
sed \
  -e "s|CERTIFICATE_ARN_PLACEHOLDER|${CERTIFICATE_ARN}|g" \
  -e "s|DEMO_DOMAIN_NAME_PLACEHOLDER|${DEMO_DOMAIN_NAME}|g" \
  otel-demo-values.yaml.template > otel-demo-values.yaml
```

Verify the substitutions look correct before installing:

```sh
grep -E "certificate-arn|host:|otlp-http" otel-demo-values.yaml
```

### Install OpenTelemetry Collector

```sh
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

helm install otel-demo open-telemetry/opentelemetry-demo \
  --namespace otel-demo \
  --create-namespace \
  --values otel-demo-values.yaml

kubectl -n otel-demo get pods
kubectl -n otel-demo get ingress
```

Wait until every demo pod is ready and the ingress has an ALB address:

```sh
kubectl -n otel-demo wait --for=condition=Ready pods --all --timeout=15m
kubectl -n otel-demo get ingress -w
```

### Troubleshooting

If any `otel-collector-agent` pod shows `CreateContainerConfigError`, the secret is missing a key (run `kubectl -n otel-demo describe pod -l app=otel-collector-agent` to confirm). Recreate the secret and restart the DaemonSet:

```sh
kubectl -n otel-demo delete secret dynatrace-otelcol-dt-api-credentials

kubectl create secret generic dynatrace-otelcol-dt-api-credentials \
  --namespace otel-demo \
  --from-literal=DT_ENDPOINT="${DT_ENDPOINT}" \
  --from-literal=DT_API_TOKEN="${DT_API_TOKEN}" \
  --from-literal=CLUSTER_NAME="${CLUSTER_NAME}"

kubectl -n otel-demo rollout restart daemonset/otel-collector-agent
kubectl -n otel-demo rollout status daemonset/otel-collector-agent
```

## 9. Create the Route 53 ALB alias record

Obtain the ALB DNS name and its Route 53 canonical hosted-zone ID. The ingress address may take a few minutes to appear.  Do not proceed until see an address in `kubectl -n otel-demo get ingress -w` output.

```sh
export ALB_DNS_NAME=$(kubectl -n otel-demo get ingress \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')

export ALB_ZONE_ID=$(aws elbv2 describe-load-balancers \
  --region "$AWS_REGION" \
  --query "LoadBalancers[?DNSName=='${ALB_DNS_NAME}'].CanonicalHostedZoneId | [0]" \
  --output text)

test "$ALB_ZONE_ID" != "None"
printf 'ALB DNS: %s\nALB hosted zone: %s\n' "$ALB_DNS_NAME" "$ALB_ZONE_ID"
```

Look up the hosted zone ID for your domain and create the alias record:

```sh
export HOSTED_ZONE_ID=$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='tae.dynatracelabs.com.'].Id" \
  --output text | awk -F'/' '{print $3}')

echo "Hosted zone ID: $HOSTED_ZONE_ID"
```

```sh
cat > route53-alias.json <<EOF
{
  "Comment": "Route the OpenTelemetry Demo hostname to its ALB",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${DEMO_DOMAIN_NAME}",
      "Type": "A",
      "AliasTarget": {
        "HostedZoneId": "${ALB_ZONE_ID}",
        "DNSName": "dualstack.${ALB_DNS_NAME}",
        "EvaluateTargetHealth": false
      }
    }
  }]
}
EOF

aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch file://route53-alias.json
```

## 10. Verify the public demo

```sh
curl --fail --location "https://${DEMO_DOMAIN_NAME}/"
curl --fail --location "https://${DEMO_DOMAIN_NAME}/feature"
```

Open these URLs in a browser:

```text
https://<DEMO_DOMAIN_NAME>/
https://<DEMO_DOMAIN_NAME>/feature
https://<DEMO_DOMAIN_NAME>/grafana/
https://<DEMO_DOMAIN_NAME>/jaeger/ui/
```

The `/feature` page is proxied by `frontend-proxy` and changes the demo's feature flags. Restrict the ALB security group to approved source CIDRs when the demo should not be broadly public.

## 11. Upgrade the demo

The demo chart does not support in-place upgrades. Remove it before installing a different chart version:

```sh
helm uninstall otel-demo --namespace otel-demo
kubectl delete namespace otel-demo
```

## 12. Tear down the AWS environment

For a full teardown, delete the demo ingress before deleting the cluster. This gives the AWS Load Balancer Controller time to remove the ALB, its target groups, listeners, security group, and ALB elastic network interfaces. Keep the `ALB_DNS_NAME`, `ALB_ZONE_ID`, and `CERTIFICATE_ARN` shell variables from the earlier steps, or set them again before starting.

```sh
export ALB_DNS_NAME=$(kubectl -n otel-demo get ingress \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')

export ALB_ARN=$(aws elbv2 describe-load-balancers \
  --region "$AWS_REGION" \
  --query "LoadBalancers[?DNSName=='${ALB_DNS_NAME}'].LoadBalancerArn | [0]" \
  --output text)

helm uninstall otel-demo --namespace otel-demo
kubectl delete namespace otel-demo --wait=true

aws elbv2 wait load-balancers-deleted \
  --region "$AWS_REGION" \
  --load-balancer-arns "$ALB_ARN"
```

Delete the public Route 53 alias record after the ALB is gone. This command reuses the alias-record JSON generated in step 8 and changes its operation from `UPSERT` to `DELETE`:

```sh
sed 's/"Action": "UPSERT"/"Action": "DELETE"/' route53-alias.json \
  > route53-delete-alias.json

aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch file://route53-delete-alias.json
```

Delete the certificate after the ALB has stopped using it. The ACM DNS-validation CNAME is harmless if retained, but remove it from Route 53 as well when it was created solely for this temporary hostname.

```sh
aws acm delete-certificate \
  --region "$AWS_REGION" \
  --certificate-arn "$CERTIFICATE_ARN"
```

Do not uninstall a shared AWS Load Balancer Controller or delete the shared `AWSLoadBalancerControllerIAMPolicy`. For a dedicated controller created only for this cluster, have the platform team remove its Helm release, IAM service account, and IAM policy. Then remove the EKS cluster. Because this guide creates a dedicated cluster and VPC with `eksctl`, deleting the cluster also removes its managed node group, load-balancer-free subnets, route tables, internet gateway, NAT gateways, and EKS-created security groups.

```sh
eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION"
```

If the ALB waiter does not complete, do not delete the cluster yet. Inspect the controller logs and Kubernetes events first:

```sh
kubectl -n kube-system logs deployment/aws-load-balancer-controller --tail=200
kubectl -n otel-demo get events --sort-by=.lastTimestamp
```

Only if controller cleanup cannot be repaired, delete the ALB directly and wait for it to disappear before retrying the cluster deletion:

```sh
aws elbv2 delete-load-balancer --region "$AWS_REGION" --load-balancer-arn "$ALB_ARN"
aws elbv2 wait load-balancers-deleted \
  --region "$AWS_REGION" \
  --load-balancer-arns "$ALB_ARN"
```

The EBS CSI IAM role (`AmazonEKS_EBS_CSI_DriverRole`) was created by `eksctl create iamserviceaccount` as a CloudFormation stack. `eksctl delete cluster` removes that stack, so no manual IAM cleanup is needed for it.

Do not delete the VPC manually unless `eksctl delete cluster` reports that it could not do so. If you adapt this guide to an existing or shared VPC, `eksctl` will not delete that shared networking; remove only the dedicated resources you created.
