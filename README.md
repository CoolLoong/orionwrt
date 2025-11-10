# Build Guide
```
# 如果你使用，WSL环境，需清理宿主机环境变量
export PATH=$(echo "$PATH" | tr ':' '\n' | grep -E '^/' | grep -v '^/mnt/' | tr '\n' ':' | sed 's/:$//')

# 初始化固件源码
git clone https://github.com/CoolLoong/orionwrt
chmod +x build.sh

# 初始化构建环境
sudo apt -y update  
sudo apt -y full-upgrade  
sudo apt install -y dos2unix libfuse-dev  
sudo bash -c 'bash <(curl -sL https://build-scripts.immortalwrt.org/init_build_environment.sh)'  

# 构建
./build.sh x86_64_immwrt
```