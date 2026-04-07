
# install nvidia device plugin （quick）
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.15.0/nvidia-device-plugin.yml

# install nvidia device plugin (production)
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update
helm upgrade --install nvdp nvdp/nvidia-device-plugin -n kube-system
###############
# kube-system（或你指定的 namespace）里一个 DaemonSet：nvidia-device-plugin-daemonset
# Node 上出现资源：
# .status.capacity["nvidia.com/gpu"]
# .status.allocatable["nvidia.com/gpu"]
# 它只把 GPU “报”出来，至于驱动是否齐全、容器能否跑 nvidia-smi，不一定由它保证。
####################

# check if the GPU driver is installed
# below are not workable --> need to find out why?
# kubectl debug node/aks-a100-38761938-vmss000001 -it --image=ubuntu -- chroot /host
# kubectl debug node/aks-t4-25568425-vmss000003 -it --image=ubuntu -- chroot /host
# nvidia-smi

# check if the GPU driver is installed
kubectl exec -it nvdp-nvidia-device-plugin -n kube-system -- nvidia-smi
# workable start
kubectl apply -f gpu-pod.yaml
kubectl exec -it gpu-pod -- nvidia-smi
# workable end

#---
# install nvidia driver (production)
# these are not required if AKS automatically installs the GPU driver
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update
helm install gpu-operator nvidia/gpu-operator -n gpu-operator --create-namespace
#---

# check ALLOC_GPU
kubectl get nodes -l kubernetes.azure.com/agentpool=a100 \
  -o custom-columns=NAME:.metadata.name,ALLOC_GPU:.status.allocatable.nvidia\.com/gp
# test
kubectl run gpu-test --rm -it \
  --restart=Never \
  --image=nvidia/cuda:12.2.0-base-ubuntu20.04 \
  --limits='nvidia.com/gpu=1' \
  -- nvidia-smi

# check daemonset
kubectl -n kube-system get ds | grep -i nvidia
kubectl -n kube-system get pods -o wide | grep -i nvidia


