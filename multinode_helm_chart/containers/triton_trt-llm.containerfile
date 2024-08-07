# Copyright (c) 2024, NVIDIA CORPORATION. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

ARG BASE_CONTAINER_IMAGE=nvcr.io/nvidia/tritonserver:24.07-trtllm-python-py3
ARG NCCL_VERSION=v2.21.5-1

FROM ${BASE_CONTAINER_IMAGE}

# Set a set of useful labels.
LABEL "base"="${BASE_CONTAINER_IMAGE}"
LABEL "role"="server"

# Stop APT (Debian package manager) from complaining about interactivity.
ENV DEBIAN_FRONTEND=noninteractive
# Set additional environment values that make usage more pleasant.
ENV TERM=xterm-256color

RUN apt update \
 && apt install --yes \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    cgroup-tools \
 && rm -rf /var/lib/apt/lists/*

 #################################################
# Install kubectl because server.py script depends on it.
# Step 1: acquire the Kubernetes APT GPG key.
RUN curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
 && chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Step 2: Acquire the API sources list for Kubernetes.
RUN echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' \
  | tee /etc/apt/sources.list.d/kubernetes.list \
 && chmod 644 /etc/apt/sources.list.d/kubernetes.list

# Step 3: Install kubectl.
RUN apt update \
 && apt install --yes \
    kubectl \
 && apt autoremove --yes \
 && apt purge --yes \
 && rm -rf /var/lib/apt/lists/*

#################################################
## Install EFA installer
RUN apt update
RUN cd $HOME \
    && curl -O https://efa-installer.amazonaws.com/aws-efa-installer-1.33.0.tar.gz \
    && tar -xf $HOME/aws-efa-installer-1.33.0.tar.gz \
    && cd aws-efa-installer \
    && ./efa_installer.sh -y -g -d --skip-kmod --skip-limit-conf --no-verify \
    && rm -rf $HOME/aws-efa-installer

###################################################
## Install AWS-OFI-NCCL plugin
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y libhwloc-dev
#Switch from sh to bash to allow parameter expansion
SHELL ["/bin/bash", "-c"]
RUN curl -OL https://github.com/aws/aws-ofi-nccl/releases/download/v1.9.2-aws/aws-ofi-nccl-1.9.2-aws.tar.gz \
    && tar -xf aws-ofi-nccl-1.9.2-aws.tar.gz \
    && cd aws-ofi-nccl-1.9.2-aws \
    && ./configure --prefix=/opt/aws-ofi-nccl/install \
        --with-mpi=/opt/amazon/openmpi \
        --with-libfabric=/opt/amazon/efa \
        --with-cuda=/usr/local/cuda \
        --enable-platform-aws \
    && make -j $(nproc) \
    && make install \
    && cd .. \
    && rm -rf aws-ofi-nccl-1.9.2-aws \
    && rm aws-ofi-nccl-1.9.2-aws.tar.gz

SHELL ["/bin/sh", "-c"]

# Set the active working directory.
WORKDIR /workspace

# Copy kubessh script w/ executable permissions for everyone.
# This enables the script to be executed no matter the user the container is run as.
# This works around the issue of the file being non-executable when the container is build on a Windows host.
COPY --chmod=555 kubessh .
COPY server.py .

RUN apt list --installed \
 && pip list --version

ENTRYPOINT [ "/bin/bash" ]
