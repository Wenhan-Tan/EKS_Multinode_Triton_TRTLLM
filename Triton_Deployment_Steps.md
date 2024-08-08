# Steps to deploy Triton Server on EKS

## 1. Build a custom image

We need to build a custom image to include the kubessh file, server.py, and other EFA libraries stack.

Run the following command to build a custom image:

```
docker build \
  --file ./triton_trt-llm.containerfile \
  --rm \
  --tag <custom_image_tag> \
  .
```

Push the image to a cluster visible repository:

```
docker push <custom_image_tag>
```

## 2. Prepare a Triton model repository:

Clone the TRT-LLM backend repository:

```
git clone https://github.com/triton-inference-server/tensorrtllm_backend.git -b v0.11.0
cd tensorrtllm_backend
git lfs install
git submodule update --init --recursive
```

Launch a container:

```
docker run --rm -it --net host --shm-size=2g --ulimit memlock=-1 --ulimit stack=67108864 --gpus all -v $(pwd):/workspace -w /workspace nvcr.io/nvidia/tritonserver:24.07-trtllm-python-py3 bash
```

Build a Llama3-8b engine with Tensor Parallelism=4, Pipeline Parallelism=2:

```
cd tensorrt_llm/examples/llama
git clone https://huggingface.co/meta-llama/Meta-Llama-3-8B

python convert_checkpoint.py --model_dir ./Meta-Llama-3-8B \
                             --output_dir ./converted_checkpoint \
                             --dtype float16 \
                             --tp_size 4 \
                             --pp_size 2

trtllm-build --checkpoint_dir ./converted_checkpoint \
             --output_dir ./output_engines \
             --gemm_plugin float16 \
             --use_custom_all_reduce disable \ # only disable on non-NVLink machines
             --max_input_len 2048 \
             --max_output_len 2048 \
             --max_batch_size 4 \
             --use_paged_context_fmha enable
```

Prepare a Triton model repository:

```
cd /workspace
mkdir triton_model_repo

cp -r all_models/inflight_batcher_llm/ensemble triton_model_repo/
cp -r all_models/inflight_batcher_llm/preprocessing triton_model_repo/
cp -r all_models/inflight_batcher_llm/postprocessing triton_model_repo/
cp -r all_models/inflight_batcher_llm/tensorrt_llm triton_model_repo/

python3 tools/fill_template.py -i triton_model_repo/preprocessing/config.pbtxt tokenizer_dir:<path_to_tokenizer>,tokenizer_type:llama,triton_max_batch_size:4,preprocessing_instance_count:1
python3 tools/fill_template.py -i triton_model_repo/tensorrt_llm/config.pbtxt triton_max_batch_size:4,decoupled_mode:False,max_beam_width:1,engine_dir:<path_to_engines>,max_tokens_in_paged_kv_cache:2560,max_attention_window_size:2560,kv_cache_free_gpu_mem_fraction:0.5,exclude_input_in_output:True,enable_kv_cache_reuse:False,batching_strategy:inflight_batching,max_queue_delay_microseconds:600
python3 tools/fill_template.py -i triton_model_repo/postprocessing/config.pbtxt tokenizer_dir:<path_to_tokenizer>,tokenizer_type:llama,triton_max_batch_size:4,postprocessing_instance_count:1
python3 tools/fill_template.py -i triton_model_repo/ensemble/config.pbtxt triton_max_batch_size:4
```

> [!Note]
> Be sure to substitute the correct values for `<path_to_tokenizer>` and `<path_to_engines>` in the example above. Keep in mind that we need to copy the tokenizer, the TRT-LLM engines, and the Triton model repository to a shared file storage between your nodes. They're required to launch your model in Triton. For example, if using AWS EFS, the values for `<path_to_tokenizer>` and `<path_to_engines>` should be respect to the actutal EFS mount path. This is determined by your persistent-volume claim and mount path in chart/templates/deployment.yaml. Make sure that your nodes are able to access these three items.

## 3. Create a `<custom_values>.yaml` file

Make sure you go over the provided `values.yaml` first to understand what each value represents.

Below is an example:

```
gpu: NVIDIA-A10G
gpuPerNode: 4
persistentVolumeClaim: efs-claim

tensorrtLLM:
  parallelism:
    tensor: 4
    pipeline: 2

triton:
  image:
    name: wenhant16/triton_trtllm_multinode:24.07.10
  resources:
    cpu: 4
    memory: 64Gi
    efa: 1 # If you don't want to enable EFA, set this to 0.
  triton_model_repo_path: /var/run/models/llama3_8b_tp4_pp2/triton_model_repo
  enable_nsys: false # Note if you send lots of requests, nsys report can be very large.

logging:
  tritonServer:
    verbose: False

autoscaling:
  enable: true
  replicas:
    maximum: 2
    minimum: 1
  metric:
    name: triton:queue_compute:ratio
    value: 1
```

## 4. Install the Helm chart

```
helm install <installation_name> \
  --values ./chart/values.yaml \
  --values ./chart/<custom_values>.yaml \
  ./chart/.
```

In this example, we are going to deploy Triton server on 2 nodes with 4 GPUs each. This will result in having 2 pods running in your cluster. Command `kubectl get pods` should output something similar to below:

```
NAME                         READY   STATUS    RESTARTS   AGE
leaderworkerset-sample-0     1/1     Running   0          28m
leaderworkerset-sample-0-1   1/1     Running   0          28m
```

Use the following command to check Triton logs:

```
kubectl logs --follow leaderworkerset-sample-0
```

You should output something similar to below:

```
I0717 23:01:28.501008 300 server.cc:674] 
+----------------+---------+--------+
| Model          | Version | Status |
+----------------+---------+--------+
| ensemble       | 1       | READY  |
| postprocessing | 1       | READY  |
| preprocessing  | 1       | READY  |
| tensorrt_llm   | 1       | READY  |
+----------------+---------+--------+

I0717 23:01:28.501073 300 tritonserver.cc:2579] 
+----------------------------------+-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+
| Option                           | Value                                                                                                                                                                                                           |
+----------------------------------+-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+
| server_id                        | rank0                                                                                                                                                                                                           |
| server_version                   | 2.47.0                                                                                                                                                                                                          |
| server_extensions                | classification sequence model_repository model_repository(unload_dependents) schedule_policy model_configuration system_shared_memory cuda_shared_memory binary_tensor_data parameters statistics trace logging |
| model_repository_path[0]         | /var/run/models/llama3_8b_tp2_pp4/triton_model_repo                                                                                                                                                             |
| model_control_mode               | MODE_NONE                                                                                                                                                                                                       |
| strict_model_config              | 1                                                                                                                                                                                                               |
| model_config_name                |                                                                                                                                                                                                                 |
| rate_limit                       | OFF                                                                                                                                                                                                             |
| pinned_memory_pool_byte_size     | 268435456                                                                                                                                                                                                       |
| cuda_memory_pool_byte_size{0}    | 67108864                                                                                                                                                                                                        |
| min_supported_compute_capability | 6.0                                                                                                                                                                                                             |
| strict_readiness                 | 1                                                                                                                                                                                                               |
| exit_timeout                     | 30                                                                                                                                                                                                              |
| cache_enabled                    | 0                                                                                                                                                                                                               |
+----------------------------------+-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+

I0717 23:01:28.502835 300 grpc_server.cc:2463] "Started GRPCInferenceService at 0.0.0.0:8001"
I0717 23:01:28.503047 300 http_server.cc:4692] "Started HTTPService at 0.0.0.0:8000"
I0717 23:01:28.544321 300 http_server.cc:362] "Started Metrics Service at 0.0.0.0:8002"
```

## 5. Send a Curl POST request for infernce

Each cloud provider has their own LoadBalancer. In this AWS example, we can view the external IP address by running `kubectl get services`. Note that we use `wenhant-test` as helm chart installation name here. Your output should look something similar to below:

```
NAME                     TYPE           CLUSTER-IP      EXTERNAL-IP                                                              PORT(S)                                        AGE
kubernetes               ClusterIP      10.100.0.1      <none>                                                                   443/TCP                                        43d
leaderworkerset-sample   ClusterIP      None            <none>                                                                   <none>                                         54m
wenhant-test             LoadBalancer   10.100.44.170   a69c447a535104f088d2e924f5523d41-634913838.us-east-1.elb.amazonaws.com   8000:32120/TCP,8001:32263/TCP,8002:31957/TCP   54m
```

You can send a CURL with the following command:

```
curl -X POST a69c447a535104f088d2e924f5523d41-634913838.us-east-1.elb.amazonaws.com:8000/v2/models/ensemble/generate -d '{"text_input": "What is machine learning?", "max_tokens": 64, "bad_words": "", "stop_words": "", "pad_id": 2, "end_id": 2}'
```

You should output similar to below:

```
{"context_logits":0.0,"cum_log_probs":0.0,"generation_logits":0.0,"model_name":"ensemble","model_version":"1","output_log_probs":[0.0,0.0,0.0,0.0,0.0],"sequence_end":false,"sequence_id":0,"sequence_start":false,"text_output":" Machine learning is a branch of artificial intelligence that deals with the development of algorithms that allow computers to learn from data and make predictions or decisions without being explicitly programmed. Machine learning algorithms are used in a wide range of applications, including image recognition, natural language processing, and predictive analytics.\nWhat is the difference between machine learning and"}
```

## 6. Test Horizontal Pod Autoscaler and Cluster Autoscaler

To check HPA status, run:

```
kubectl get hpa wenhant-test
```

You should output something similar to below:

```
NAME           REFERENCE                                TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
wenhant-test   LeaderWorkerSet/leaderworkerset-sample   0/1       1         2         1          66m
```

From the output above, the current metric value is 0 and the target value is 1. Note that in this example, our metric is a custom metric defined in Prometheus Rule. You can find more details in the [Install Prometheus rule for Triton metrics](Cluster_Setup_Steps.md#8-install-prometheus-rule-for-triton-metrics) step. When the current value exceed 1, the HPA will start to create a new replica. We can either increase traffic by sending a large amount of requests to the LoadBalancer or manually increase minimum number of replicas to let the HPA create the second replica. In this example, we are going to choose the latter and run the following command:

```
kubectl patch hpa wenhant-test -p '{"spec":{"minReplicas": 2}}'
```

Your `kubectl get pods` command should output something similar to below:

```
NAME                         READY   STATUS    RESTARTS   AGE
leaderworkerset-sample-0     1/1     Running   0          6h48m
leaderworkerset-sample-0-1   1/1     Running   0          6h48m
leaderworkerset-sample-1     0/1     Pending   0          13s
leaderworkerset-sample-1-1   0/1     Pending   0          13s
```

Here we can see the second replica is created but in `Pending` status. If you run `kubectl describe pod leaderworkerset-sample-1`, you should see events similar to below:

```
Events:
  Type     Reason            Age   From                Message
  ----     ------            ----  ----                -------
  Warning  FailedScheduling  48s   default-scheduler   0/3 nodes are available: 1 node(s) didn't match Pod's node affinity/selector, 2 Insufficient nvidia.com/gpu, 2 Insufficient vpc.amazonaws.com/efa. preemption: 0/3 nodes are available: 1 Preemption is not helpful for scheduling, 2 No preemption victims found for incoming pod.
  Normal   TriggeredScaleUp  15s   cluster-autoscaler  pod triggered scale-up: [{eks-efa-compute-ng-2-7ac8948c-e79a-9ad8-f27f-70bf073a9bfa 2->4 (max: 4)}]
```

The first event means that there are no available nodes to schedule any pods. This explains why the second 2 pods are in `Pending` status. The second event states that the Cluster Autoscaler detects that this pod is `unschedulable`, so it is going to increase number of nodes in our cluster until maximum is reached. You can find more details in the [Install Cluster Autoscaler](Cluster_Setup_Steps.md#10-install-cluster-autoscaler) step. This process can take some time depending on whether AWS have enough nodes available to add to your cluster. Eventually, the Cluster Autoscaler will add 2 more nodes in your node group so that the 2 `Pending` pods can be scheduled on them. Your `kubectl get nodes` and `kubectl get pods` commands should output something similar to below:

```
NAME                             STATUS   ROLES    AGE   VERSION
ip-192-168-103-11.ec2.internal   Ready    <none>   15m   v1.30.2-eks-1552ad0
ip-192-168-106-8.ec2.internal    Ready    <none>   15m   v1.30.2-eks-1552ad0
ip-192-168-117-30.ec2.internal   Ready    <none>   11h   v1.30.2-eks-1552ad0
ip-192-168-127-31.ec2.internal   Ready    <none>   11h   v1.30.2-eks-1552ad0
ip-192-168-26-106.ec2.internal   Ready    <none>   11h   v1.30.2-eks-1552ad0
```

```
leaderworkerset-sample-0     1/1     Running   0          7h26m
leaderworkerset-sample-0-1   1/1     Running   0          7h26m
leaderworkerset-sample-1     1/1     Running   0          38m
leaderworkerset-sample-1-1   1/1     Running   0          38m
```

You can run the following command to change minimum replica back to 1:

```
kubectl patch hpa wenhant-test -p '{"spec":{"minReplicas": 1}}'
```

The HPA will delete the second replica if current metric does not exceed the target value. The Cluster Autoscaler will also remove the added 2 nodes when it detects them as "free".

## 7. Uninstall the Helm chart

```
helm uninstall <installation_name>
```

## 8. (Optional) NCCL Test

To test whether EFA is working properly, we can run a NCCL test across nodes. Make sure you modify the [nccl_test.yaml](./multinode_helm_chart/nccl_test.yaml) file and adjust the following values:

- `slotsPerWorker`: set to the number of GPUs per node in your cluster
- `-np`: set to "number_of_worker_nodes" * "number_of_gpus_per_node"
- `-N`: set to number_of_gpus_per_node
- `Worker: replicas`: set to number of worker pods you would like the test to run on. This must be less than or eaqual to the number of nodes in your cluster
- `node.kubernetes.io/instance-type`: set to the instance type of the nodes in your cluster against which you would like the nccl test to be run
- `nvidia.com/gpu`: set to the number of GPUs per node in your cluster, adjust in both the limits and requests section
- `vpc.amazonaws.com/efa`: set to the number of EFA adapters per node in your cluster, adjust in both the limits and requests section

Run the command below to deploy the MPI Operator which is required by the NCCL Test manifest:

```
kubectl apply --server-side -f https://raw.githubusercontent.com/kubeflow/mpi-operator/v0.5.0/deploy/v2beta1/mpi-operator.yaml
```

Run the command below to deploy NCCL test:

```
kubectl apply -f nccl_test.yaml
```

Note that the launcher pod will keep restarting until the connection is established with the worker pods. Run the command below to see the launcher pod logs:

```
kubectl logs -f $(kubectl get pods | grep launcher | cut -d ' ' -f 1)
```
