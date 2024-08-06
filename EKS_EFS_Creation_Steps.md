# Steps to create EKS cluster and EFS

## 1. Install CLIs

### a. Install AWS CLI (steps [here](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html))

```
sudo apt install unzip
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

### b. Install Kubernetes CLI (steps [here](https://docs.aws.amazon.com/eks/latest/userguide/install-kubectl.html))

```
curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.30.0/2024-05-12/bin/linux/amd64/kubectl
chmod +x ./kubectl
mkdir -p $HOME/bin && cp ./kubectl $HOME/bin/kubectl && export PATH=$HOME/bin:$PATH
echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc
```

### c. Install EKS CLI (steps [here](https://eksctl.io/installation/))

```
ARCH=amd64
PLATFORM=$(uname -s)_$ARCH
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$PLATFORM.tar.gz"
curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_checksums.txt" | grep $PLATFORM | sha256sum --check
tar -xzf eksctl_$PLATFORM.tar.gz -C /tmp && rm eksctl_$PLATFORM.tar.gz
sudo mv /tmp/eksctl /usr/local/bin
```

### d. Install Helm CLI (steps [here](https://docs.aws.amazon.com/eks/latest/userguide/helm.html))

```
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 > get_helm.sh
chmod 700 get_helm.sh
./get_helm.sh
```

## 2. Create an EKS cluster

### a. Configure AWS CLI

```
aws configure
```

### b. Create a config file for EKS cluster creation

eks_cluster_config.yaml

```
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: wenhant-eks-cluster
  version: "1.30"
  region: us-east-1

iam:
  withOIDC: true

managedNodeGroups:
  - name: sys-nodes
    instanceType: c5.2xlarge
    desiredCapacity: 1
    iam:
      withAddonPolicies:
        cloudWatch: true

  - name: compute-nodes
    instanceType: g5.12xlarge
    minSize: 2
    desiredCapacity: 2
    maxSize: 2
    volumeSize: 300
    efaEnabled: true
    privateNetworking: true
    iam:
      withAddonPolicies:
        cloudWatch: true
        efs: true
```

### c. Create an EKS cluster

```
eksctl create cluster -f eks_cluster_config.yaml
```

## 3. Create an EFS file system

### a. Create an IAM role

Follow the steps to create an IAM role for your EFS file system: https://docs.aws.amazon.com/eks/latest/userguide/efs-csi.html#efs-create-iam-resources. This role will be used later when you install the EFS CSI Driver.

### b. Install EFS CSI driver

Install the EFS CSI Driver through the Amazon EKS add-on in AWS console: https://docs.aws.amazon.com/eks/latest/userguide/efs-csi.html#efs-install-driver. Once it's done, check the Add-ons section in EKS console, you should see the driver is showing `Active` under Status.

### c. Create EFS file system

Follow the steps to create an EFS file system: https://github.com/kubernetes-sigs/aws-efs-csi-driver/blob/master/docs/efs-create-filesystem.md. Make sure you mount subnets in the last step correctly. This will affect whether your nodes are able to access the created EFS file system.

## 4. Test

Follow the steps to check if your EFS file system is working properly with your nodes: https://github.com/kubernetes-sigs/aws-efs-csi-driver/tree/master/examples/kubernetes/multiple_pods. This test is going to mount your EFS file system on all of your available nodes and write a text file to the file system.
