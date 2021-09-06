##### 为 IPv6 only VPS 添加 WGCF，双栈走 warp #####
##### KVM 属于完整虚拟化的 VPS 主机，网络性能方面：内核模块＞wireguard-go。#####

# 判断系统，安装差异部分

# Debian 运行以下脚本
if grep -q -E -i "debian" /etc/issue; then
	
	# 更新源
	apt update

	# 添加 backports 源,之后才能安装 wireguard-tools 
	apt -y install lsb-release sudo
	echo "deb http://deb.debian.org/debian $(lsb_release -sc)-backports main" | tee /etc/apt/sources.list.d/backports.list

	# 再次更新源
	apt update

	# 安装一些必要的网络工具包和wireguard-tools (Wire-Guard 配置工具：wg、wg-quick)
	sudo apt -y --no-install-recommends install net-tools iproute2 openresolv dnsutils wireguard-tools linux-headers-$(uname -r)
	
	# 安装 wireguard 内核模块
	sudo apt -y --no-install-recommends install wireguard-dkms
	
# Ubuntu 运行以下脚本
     elif grep -q -E -i "ubuntu" /etc/issue; then

	# 更新源
	apt update

	# 安装一些必要的网络工具包和 wireguard-tools (Wire-Guard 配置工具：wg、wg-quick)
	apt -y --no-install-recommends install net-tools iproute2 openresolv dnsutils wireguard-tools sudo

# CentOS 运行以下脚本
     elif grep -q -E -i "kernel" /etc/issue; then

	# 安装一些必要的网络工具包和wireguard-tools (Wire-Guard 配置工具：wg、wg-quick)
	yum -y install epel-release sudo
	sudo yum -y install net-tools wireguard-tools

	# 安装 wireguard 内核模块
	sudo curl -Lo /etc/yum.repos.d/wireguard.repo https://copr.fedorainfracloud.org/coprs/jdoss/wireguard/repo/epel-7/jdoss-wireguard-epel-7.repo
	sudo yum -y install epel-release wireguard-dkms

	# 升级所有包同时也升级软件和系统内核
	sudo yum -y update
	
	# 添加执行文件环境变量
        export PATH=$PATH:/usr/local/bin

# 如都不符合，提示,删除临时文件并中止脚本
     else 
	# 提示找不到相应操作系统
	echo -e "\033[32m 抱歉，我不认识此系统！\033[0m"
	
	# 删除临时目录和文件，退出脚本
	rm -f dualstack*
	exit 0

fi

# 以下为3类系统公共部分

# 判断系统架构是 AMD 还是 ARM，虚拟化是 LXC 还是 KVM,设置应用的依赖与环境
if [[ $(hostnamectl) =~ .*arm.* ]]
        then architecture=arm64
        else architecture=amd64
fi

# 判断 wgcf 的最新版本
latest=$(wget -qO- -t1 -T2 "https://api.github.com/repos/ViRb3/wgcf/releases/latest" | grep "tag_name" | head -n 1 | awk -F ":" '{print $2}' | sed 's/\"//g;s/v//g;s/,//g;s/ //g')

# 安装 wgcf
sudo wget -N -6 -O /usr/local/bin/wgcf https://github.com/ViRb3/wgcf/releases/download/v$latest/wgcf_${latest}_linux_$architecture

# 添加执行权限
sudo chmod +x /usr/local/bin/wgcf

# 注册 WARP 账户 (将生成 wgcf-account.toml 文件保存账户信息，为避免文件已存在导致出错，先尝试删掉原文件)
rm -f wgcf-account.toml
echo | wgcf register
until [ $? -eq 0 ]  
  do
   echo -e "\033[32m warp 注册接口繁忙，5秒后自动重试直到成功。 \033[0m"
   sleep 5
   echo | wgcf register
done

# 生成 Wire-Guard 配置文件 (wgcf-profile.conf)
wgcf generate

# 修改配置文件 wgcf-profile.conf 的内容,使得 IPv6 的流量均被 WireGuard 接管，让 IPv6 的流量通过 WARP IPv4 节点以 NAT 的方式访问外部 IPv6 网络，为了防止当节点发生故障时 DNS 请求无法发出，修改为 IPv4 地址的 DNS
sudo sed -i "7 s/^/PostUp = ip -6 rule add from $(ip a | egrep 'inet6' | awk -F '/' '{print $1}' | awk 'END {print $2}') lookup main\n/" wgcf-profile.conf && sudo sed -i "8 s/^/PostDown = ip -6 rule delete from $(ip a | egrep 'inet6' | awk -F '/' '{print $1}' | awk 'END {print $2}') lookup main\n/" wgcf-profile.conf && sudo sed -i 's/engage.cloudflareclient.com/[2606:4700:d0::a29f:c001]/g' wgcf-profile.conf && sudo sed -i 's/1.1.1.1/1.1.1.1,9.9.9.10,8.8.8.8/g' wgcf-profile.conf

# 把 wgcf-profile.conf 复制到/etc/wireguard/ 并命名为 wgcf.conf
sudo cp wgcf-profile.conf /etc/wireguard/wgcf.conf

# 删除临时文件
rm -f dualstack* wgcf*

# 自动刷直至成功（ warp bug，有时候获取不了ip地址）
wg-quick up wgcf
echo -e "\033[32m warp 获取 IP 中，如失败将自动重试直到成功。 \033[0m"
wget -qO- -4 ip.gs > /dev/null
until [ $? -eq 0 ]  
  do
   wg-quick down wgcf
   wg-quick up wgcf
   echo -e "\033[32m warp 获取 IP 失败，自动重试直到成功。 \033[0m"
   wget -qO- -4 ip.gs > /dev/null
done

# 设置开机启动
systemctl enable wg-quick@wgcf > /dev/null

# 优先使用 IPv4 网络
grep -qE '^[ ]*precedence[ ]*::ffff:0:0/96[ ]*100' /etc/gai.conf || echo 'precedence ::ffff:0:0/96  100' | tee -a /etc/gai.conf > /dev/null

# 结果提示
echo -e "\033[32m 恭喜！warp 双栈已成功，IPv4地址为:$(wget -qO- -4 ip.gs)，IPv6地址为:$(wget -qO- -6 ip.gs) \033[0m"
