# Steps to deploy Triton Server on EKS

## 1. Build a custom image

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
    name: wenhant16/triton_trtllm_multinode:24.07
  resources:
    cpu: 4
    memory: 64Gi
    efa: 1
  triton_model_repo_path: /var/run/models/mixtral_8x7b_tp8_ep2_moetp4/triton_model_repo

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

## 4. Install the helm chart

```
helm install <installation_name> \
  --values ./chart/values.yaml \
  --values ./chart/<custom_values>.yaml \
  ./chart/.
```
