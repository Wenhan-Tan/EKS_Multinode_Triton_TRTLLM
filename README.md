# Multinode Triton+TRT-LLM Deployment on EKS

This repository provides a Helm chart and some associated Python scripts that serve as a sample for deploying large models on EKS (Amazon Elastic Kubernetes Service). It is specifically tailored for scenarios where the model is too large to fit on a single node (which, depending on the instance contains up to 8 gpus) and therefore a single pod. This deployment flow uses Nvidia TensorRT-LLM as the inference engine and Nvidia TritonServer as the model server for ingesting and preprocessing requests. 

The main challenge in deploying models that require multinode is that one instance of the model spans multiple pods. Consequently the atomic unit that needs to be ready before requests can be served, as well as the unit that needs to be scaled becomes groups of pods. This example shows how to get around these problems and provides code to set up the following

 1. Gang Scheduling - This is a mechanism that ensures for an instance of the model all pods required to host it are running before Triton and TRT-LLM are launched on them.
 2. Autoscaling - By default the Horizontal Pod Autoscaler (HPA) scales individual pods, but we need it to scale groups of pods. We rely on [LeaderWorkerSet](https://github.com/kubernetes-sigs/lws/tree/main) to enable this. Additionally we leverage the GPU metrics exposed by Triton Server and set up Prometheus to scrape these metrics and inform the HPA's autoscaling decisions.
 3. LoadBalancer Setup - Although there are multiple pods in each instance of the model, only one pod within each group accepts requests. We show how to correctly set up a LoadBalancer Service to allow external clients to submit requests.


## Setup and Installation

 1. [Create EKS Cluster and EFS](https://github.com/Wenhan-Tan/EKS_Multinode_Triton_TRTLLM/blob/main/EKS_EFS_Creation_Steps.md)
 2. [Configure EKS Cluster and Install Dependencies](https://github.com/Wenhan-Tan/EKS_Multinode_Triton_TRTLLM/blob/main/Cluster_Setup_Steps.md)
 3. [Deploy Helm Chart and Install Triton Server](https://github.com/Wenhan-Tan/EKS_Multinode_Triton_TRTLLM/blob/main/Triton_Deployment_Steps.md)
