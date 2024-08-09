# Steps to create EKS cluster with EFS

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

In this example we create an EKS cluster consisting of two `g5.12xlarge` compute nodes, each with four NVIDIA A10G GPUs and `c5.2xlarge` CPU node as control plane. We also setup EFA between the compute nodes.

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
    minSize: 0
    desiredCapacity: 0
    maxSize: 1
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        ebs: true
        efs: true
        awsLoadBalancerController: true
        cloudWatch: true
        albIngress: true

  - name: efa-compute-nodes
    instanceType: g5.12xlarge
    minSize: 0
    desiredCapacity: 0
    maxSize: 1
    volumeSize: 300
    efaEnabled: true
    privateNetworking: true
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        ebs: true
        efs: true
        awsLoadBalancerController: true
        cloudWatch: true
        albIngress: true
```

> [!NOTE]
> We set `minSize` and `desiredCapacity` to be 0 because AWS does not create your cluster successfully if no nodes are available. For example, if you specify `desiredCapacity` to be 2 but there are no available 2 nodes, your cluster creation will fail due to timeout even though there are no errors. The easiest way to avoid this is to create the cluster with 0 nodes and increase the number of nodes later.

### c. Create the EKS cluster

```
eksctl create cluster -f eks_cluster_config.yaml
```

## 3. Create an EFS file system

To enable multiple pods deployed to multiple nodes to load shards of the same model so that they can used in coordination to serve inference request too large to loaded by a single GPU, we'll need a common, shared storage location. In Kubernetes, these common, shared storage locations are referred to as persistent volumes. Persistent volumes can be volume mapped in to any number of pods and then accessed by processes running inside of said pods as if they were part of the pod's file system. We will be using EFS as persistent volume.

Additionally, we will need to create a persistent-volume claim which can use to assign the persistent volume to a pod.
### a. Create an IAM role

Follow the steps to create an IAM role for your EFS file system: https://docs.aws.amazon.com/eks/latest/userguide/efs-csi.html#efs-create-iam-resources. This role will be used later when you install the EFS CSI Driver.

### b. Install EFS CSI driver

Install the EFS CSI Driver through the Amazon EKS add-on in AWS console: https://docs.aws.amazon.com/eks/latest/userguide/efs-csi.html#efs-install-driver. Once it's done, check the Add-ons section in EKS console, you should see the driver is showing `Active` under Status.

### c. Create EFS file system

Follow the steps to create an EFS file system: https://github.com/kubernetes-sigs/aws-efs-csi-driver/blob/master/docs/efs-create-filesystem.md. Make sure you mount subnets in the last step correctly. This will affect whether your nodes are able to access the created EFS file system.

## 4. Test

Follow the steps to check if your EFS file system is working properly with your nodes: https://github.com/kubernetes-sigs/aws-efs-csi-driver/tree/master/examples/kubernetes/multiple_pods. This test is going to mount your EFS file system on all of your available nodes and write a text file to the file system.
