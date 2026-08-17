# Load the .env file
set -a
source .env
set +a

# Generate config and pipe directly to eksctl
eksctl create cluster -f - <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: "$CLUSTER_NAME"
  region: "$AWS_REGION"
  version: "1.36"

upgradePolicy:
  supportType: STANDARD

managedNodeGroups:
  - name: "$NODEGROUP_NAME"
    instanceType: t3.xlarge
    minSize: 3
    desiredCapacity: 3
    maxSize: 5

iam:
  withOIDC: true
EOF
