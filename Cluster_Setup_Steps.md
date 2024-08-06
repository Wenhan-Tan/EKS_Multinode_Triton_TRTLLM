# Steps to set up cluster

## 1. Add node label and taint

Run the following command to get node names:

```
kubectl get nodes
```

You shoud output something similar to below:

```
NAME                          STATUS   ROLES    AGE     VERSION
ip-10-0-124-72.ec2.internal   Ready    <none>   6h10m   v1.29.3-eks-ae9a62a
ip-10-0-8-159.ec2.internal    Ready    <none>   6h10m   v1.29.3-eks-ae9a62a
```

Run the following command to add label and taints

```
kubectl label nodes ip-10-0-124-72.ec2.internal nvidia.com/gpu=present
kubectl label nodes ip-10-0-8-159.ec2.internal nvidia.com/gpu=present
kubectl taint nodes ip-10-0-124-72.ec2.internal nvidia.com/gpu=present:NoSchedule
kubectl taint nodes ip-10-0-8-159.ec2.internal nvidia.com/gpu=present:NoSchedule
```

## 2. Install Kubernetes Node Feature Discovery service

```
helm repo add kube-nfd https://kubernetes-sigs.github.io/node-feature-discovery/charts && helm repo update
helm install -n kube-system node-feature-discovery kube-nfd/node-feature-discovery \
  --set nameOverride=node-feature-discovery \
  --set worker.tolerations[0].key=nvidia.com/gpu \
  --set worker.tolerations[0].operator=Exists \
  --set worker.tolerations[0].effect=NoSchedule
```

## 3. Install NVIDIA Device Plugin

```
kubectl create -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.15.0/deployments/static/nvidia-device-plugin.yml
```

## 4. Install NVIDIA GPU Feature Discovery service

```
kubectl apply -f ./nvidia_gpu-feature-discovery_daemonset.yaml
```

## 5. Install Prometheus Kubernetes Stack

```
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update
helm install -n monitoring prometheus prometheus-community/kube-prometheus-stack \
  --set tolerations[0].key=nvidia.com/gpu \
  --set tolerations[0].operator=Exists \
  --set tolerations[0].effect=NoSchedule
```

## 6. Install NVIDIA DCGM Exporter

```
helm repo add nvidia-dcgm https://nvidia.github.io/dcgm-exporter/helm-charts && helm repo update
helm install -n monitoring dcgm-exporter nvidia-dcgm/dcgm-exporter --values nvidia_dcgm-exporter_values.yaml
```

## 7. Connect DCGM and Triton Metrics to Prometheus

```
helm install -n monitoring prometheus-adapter prometheus-community/prometheus-adapter \
  --set metricsRelistInterval=6s \
  --set customLabels.monitoring=prometheus-adapter \
  --set customLabels.release=prometheus \
  --set prometheus.url=http://prometheus-kube-prometheus-prometheus \
  --set additionalLabels.release=prometheus
```

To verify that Prometheus Adapter is working properly, run the following command:

```
kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1
```

If the command fails, wait longer and retry. If the command fails for more than a few minutes then the adapter is misconfigured and will require intervention.

## 8. Install Prometheus rule for Triton metrics

```
kubectl apply -f ./triton-metrics_prometheus-rule.yaml
```

## 9. Install EFA Kubernetes Device Plugin

Pull the EFA Kubernetes Device Plugin helm chart:

```
helm repo add eks https://aws.github.io/eks-charts
helm pull eks/aws-efa-k8s-device-plugin --untar
```

Add tolerations in `aws-efa-k8s-device-plugin/values.yaml` at line 134 like below:

```
tolerations:
- key: nvidia.com/gpu
  operator: Exists
  effect: NoSchedule
```

Install the EFA Kubernetes Device Plugin helm chart:

```
helm install aws-efa-k8s-device-plugin --namespace kube-system ./aws-efa-k8s-device-plugin/
```
