#!/bin/bash
#
# Copyright (c) 2025 Arm Limited
#
# SPDX-License-Identifier: Apache-2.0
#

set -o errexit
set -o nounset
set -o pipefail
set -x

fvp_dir="$(dirname "$(readlink -f "$0")")"
source "${fvp_dir}/../../common.bash"

ARCH=arm64
PORT=8022
ROOT=tmp
CCA="${CCA:-false}"

function install_dependencies() {
	info "Installing the dependencies needed for running the FVP tests"

	# Install dependencies
	sudo apt-get update
	sudo apt-get remove -y containerd containerd.io docker-ce docker-ce-cli
	sudo apt-get install -y git netcat-openbsd python3 python3-pip telnet docker.io binfmt-support qemu-user-static
	pip3 install pyyaml termcolor tuxmake

	# Install FVP
	tarball_name=FVP_Base_RevC-2xAEMvA_11.28_23_Linux64.tgz
	curl -OL https://developer.arm.com/-/cdn-downloads/permalink/FVPs-Architecture/FM-11.28/${tarball_name}
	tar -xvf ${tarball_name}
	rm -f ${tarball_name}
	export PATH=$(pwd)/Base_RevC_AEMvA_pkg/models/Linux64_GCC-9.3:$PATH

	# Install shrinkwrap
	git clone https://git.gitlab.arm.com/tooling/shrinkwrap.git
	export PATH=$(pwd)/shrinkwrap/shrinkwrap:$PATH
}

function build_packages() {
	info "Building FVP packages"
	export PATH=$(pwd)/shrinkwrap/shrinkwrap:$PATH
	export SHRINKWRAP_BUILD=$(pwd)/build
	export SHRINKWRAP_PACKAGE=$(pwd)/package

	# build docker images
	# do not use cmake v4.0.0 because some compatibility is removed
	sed -i 's|cmake|cmake==3.31.6|g' shrinkwrap/docker/Dockerfile.slim
	./shrinkwrap/docker/build.sh --version local

	# build FVP components
	# remove set user / group to execute it as a root
	# add `FORCE_UNSAFE_CONFIGURE` to build buildroot as a root
	sed -i 's|else|if is_docker|g' shrinkwrap/shrinkwrap/utils/runtime.py
	sed -i "s|self._rt.set_user('shrinkwrap')|self._rt.environment = { 'FORCE_UNSAFE_CONFIGURE': '1', 'CCACHE_DIR': '/mnt/ccache' }|g" shrinkwrap/shrinkwrap/utils/runtime.py
	sed -i '/set_group/d' shrinkwrap/shrinkwrap/utils/runtime.py
	shrinkwrap --runtime=docker-local \
		--image=shrinkwraptool/base-slim:local-x86_64 \
		build cca-3world.yaml \
		--overlay=${fvp_dir}/linux-containerd.yaml
#	shrinkwrap --runtime=docker-local \
#		--image=shrinkwraptool/base-slim:local-x86_64 \
#		build cca-3world.yaml \
#		--overlay buildroot.yaml \
#		--btvar GUEST_ROOTFS='${artifact:BUILDROOT}' \
#		--overlay=${fvp_dir}/linux-containerd.yaml \
#		--overlay=${fvp_dir}/buildroot-containerd.yaml \
#		--btvar BUILDROOT_CONFIG=${fvp_dir}/buildroot-containerd.config
}

function build_rootfs() {
	info "Building FVP rootfs"
	export PATH=$(pwd)/shrinkwrap/shrinkwrap:$PATH
	export SHRINKWRAP_BUILD=$(pwd)/build
	export SHRINKWRAP_PACKAGE=$(pwd)/package

	# build docker images
	# do not use cmake v4.0.0 because some compatibility is removed
	sed -i 's|cmake|cmake==3.31.6|g' shrinkwrap/docker/Dockerfile.slim
	./shrinkwrap/docker/build.sh --version local

	# build FVP components
	# remove set user / group to execute it as a root
	# add `FORCE_UNSAFE_CONFIGURE` to build buildroot as a root
	sed -i 's|else|if is_docker|g' shrinkwrap/shrinkwrap/utils/runtime.py
	sed -i "s|self._rt.set_user('shrinkwrap')|self._rt.environment = { 'FORCE_UNSAFE_CONFIGURE': '1', 'CCACHE_DIR': '/mnt/ccache' }|g" shrinkwrap/shrinkwrap/utils/runtime.py
	sed -i '/set_group/d' shrinkwrap/shrinkwrap/utils/runtime.py
	shrinkwrap --runtime=docker-local \
		--image=shrinkwraptool/base-slim:local-x86_64 \
		build buildroot.yaml \
		--btvar GUEST_ROOTFS='${artifact:BUILDROOT}' \
		--overlay=${fvp_dir}/buildroot-containerd.yaml \
		--btvar BUILDROOT_CONFIG=${fvp_dir}/buildroot-containerd.config
}

function unmount() {
	sudo rm -rf $ROOT/usr/bin/qemu-aarch64-static
	sudo umount $ROOT/dev || true
	sudo umount $ROOT || true
	rm -rf $ROOT
}

function prepare_rootfs() {
	info "Building FVP components"
	export PATH=$(pwd)/shrinkwrap/shrinkwrap:$PATH

	# mount rootfs
	trap unmount ERR
	rootfs=$(pwd)/package/buildroot/rootfs.ext2
	mkdir -p $ROOT
	sudo mount $rootfs $ROOT
	sudo mount -o bind /dev $ROOT/dev
	sudo cp /usr/bin/qemu-aarch64-static $ROOT/usr/bin/

	# config sshd
	sudo chroot $ROOT ssh-keygen -A
	echo -e "root\nroot" | sudo chroot $ROOT passwd
	sudo sed -i -e 's/#PermitRootLogin.*$/PermitRootLogin yes/g' $ROOT/etc/ssh/sshd_config
	ssh-keygen -t rsa -N "" -f $HOME/.ssh/id_rsa
	sudo mkdir -p $ROOT/root/.ssh
	sudo chmod 700 $ROOT/root/.ssh
	pub=$(cat $HOME/.ssh/id_rsa.pub)
	echo $pub | sudo tee -a $ROOT/root/.ssh/authorized_keys
	sudo chmod 600 $ROOT/root/.ssh/authorized_keys
	sudo sed -i -e 's/#   StrictHostKeyChecking.*$/    StrictHostKeyChecking no/g' /etc/ssh/ssh_config
	echo -e "Host fvp" >> $HOME/.ssh/config
	echo -e "\tHostName localhost" >> $HOME/.ssh/config
	echo -e "\tUser root" >> $HOME/.ssh/config
	echo -e "\tPort $PORT" >> $HOME/.ssh/config

	# create mount.fuse
	cd $ROOT/usr/sbin
	sudo ln -sf mount.fuse3 mount.fuse
	cd -

	# install kernel modules
	sudo tar -xf $(pwd)/package/cca-3world/modules.tgz -C $ROOT/usr/

	# install containerd
	project="containerd/containerd"
	base_version="v2.0"
	version=$(get_latest_patch_release_from_a_github_project "${project}" "${base_version}")
	tarball_name="containerd-${version//v}-linux-${ARCH}.tar.gz"
	download_github_project_tarball "${project}" "${version}" "${tarball_name}"
	sudo mkdir -p $ROOT/usr/local/bin
	sudo tar --keep-directory-symlink -xvf "${tarball_name}" -C $ROOT/usr/local/
	rm -f "${tarball_name}"
	sudo mkdir -p $ROOT/etc/containerd
	sudo tee $ROOT/etc/containerd/config.toml << EOF
[proxy_plugins]
  [proxy_plugins.nydus]
    type = "snapshot"
    address = "/run/containerd-nydus/containerd-nydus-grpc.sock"
EOF
	sudo mkdir -p $ROOT/etc/systemd/system
	sudo tee $ROOT/etc/systemd/system/containerd.service <<EOF
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd

Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
# Having non-zero Limit*s causes performance problems due to accounting overhead
# in the kernel. We recommend using cgroups to do container-local accounting.
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
# Comment TasksMax if your systemd version does not supports it.
# Only systemd 226 and above support this version.
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF

	# install crictl
	project="kubernetes-sigs/cri-tools"
	base_version="v1.32"
	version=$(get_latest_patch_release_from_a_github_project "${project}" "${base_version}")
	tarball_name="crictl-${version}-linux-${ARCH}.tar.gz"
	download_github_project_tarball "${project}" "${version}" "${tarball_name}"
	sudo mkdir -p $ROOT/usr/local/bin
	sudo tar -xvf "${tarball_name}" -C $ROOT/usr/local/bin
	rm -f "${tarball_name}"

	# install cni plugin
	project="containernetworking/plugins"
	base_version="v1.6"
	version=$(get_latest_patch_release_from_a_github_project "${project}" "${base_version}")
	tarball_name="cni-plugins-linux-${ARCH}-${version}.tgz"
	download_github_project_tarball "${project}" "${version}" "${tarball_name}"
	sudo mkdir -p $ROOT/opt/cni/bin
	sudo tar -xvf "${tarball_name}" -C $ROOT/opt/cni/bin
	rm -f "${tarball_name}"
	sudo mkdir -p $ROOT/etc/cni/net.d

	# install kata-containers
	tarball_name="kata-static.tar.xz"
	# download from https://gitlab.geo.arm.com/software/ias/containers/confidential-containers/kata-containers/-/jobs/799319/artifacts/file/kata-static.tar.xz
	sudo tar -xvf "${tarball_name}" -C $ROOT/
	sudo chroot $ROOT bash -c 'for b in $(ls /opt/kata/bin/); do ln -sf /opt/kata/bin/$b /usr/local/bin/$(basename $b); done'
	if [ "$CCA" == "true" ]; then
		sudo sed -i 's|path = "/opt/kata/bin/qemu-system-aarch64"|path = "/opt/kata/bin/qemu-system-aarch64-cca-experimental"|g' $ROOT/opt/kata/share/defaults/kata-containers/configuration-qemu.toml
		sudo sed -i 's|kernel = "/opt/kata/share/kata-containers/vmlinux.container"|kernel = "/opt/kata/share/kata-containers/vmlinux-confidential.container"|g' $ROOT/opt/kata/share/defaults/kata-containers/configuration-qemu.toml
		sudo sed -i 's|image = "/opt/kata/share/kata-containers/kata-containers.img"|image = "/opt/kata/share/kata-containers/kata-containers-confidential.img"|g' $ROOT/opt/kata/share/defaults/kata-containers/configuration-qemu.toml
		sudo sed -i 's|# confidential_guest = true|confidential_guest = true|g' $ROOT/opt/kata/share/defaults/kata-containers/configuration-qemu.toml
		sudo sed -i 's|shared_fs = "virtio-fs"|shared_fs = "none"|g' $ROOT/opt/kata/share/defaults/kata-containers/configuration-qemu.toml
		sudo sed -i 's|dial_timeout = 45|dial_timeout = 450|g' $ROOT/opt/kata/share/defaults/kata-containers/configuration-qemu.toml
	fi

	# install nydus-snapshotter
	project="containerd/nydus-snapshotter"
	base_version="v0.15"
	version=$(get_latest_patch_release_from_a_github_project "${project}" "${base_version}")
	tarball_name="nydus-snapshotter-${version}-linux-${ARCH}.tar.gz"
	download_github_project_tarball "${project}" "${version}" "${tarball_name}"
	sudo mkdir -p $ROOT/usr/local/bin
	sudo tar -xvf "${tarball_name}" -C $ROOT/usr/local/bin --strip-components=1
	rm -f "${tarball_name}"
	sudo mkdir -p $ROOT/etc/containerd
	sudo tee $ROOT/etc/containerd/nydus-snapshotter.toml <<EOF
version = 1

# Snapshotter's own home directory where it stores and creates necessary resources
root = "/var/lib/containerd-nydus"

# The snapshotter's GRPC server socket, containerd will connect to plugin on this socket
address = "/run/containerd-nydus/containerd-nydus-grpc.sock"

[daemon]
# Enable proxy mode
fs_driver = "proxy"

[snapshot]
# Insert Kata volume information to Mount.Options
enable_kata_volume = true
EOF
	sudo mkdir -p $ROOT/etc/systemd/system
	sudo tee $ROOT/etc/systemd/system/nydus-snapshotter.service <<EOF
[Unit]
Description=Nydus snapshotter
After=network.target local-fs.target
Before=containerd.service

[Service]
ExecStart=/usr/local/bin/containerd-nydus-grpc --config /etc/containerd/nydus-snapshotter.toml --log-to-stdout

[Install]
RequiredBy=containerd.service
EOF

	# install nerdctl
	project="containerd/nerdctl"
	base_version="v2.0"
	version=$(get_latest_patch_release_from_a_github_project "${project}" "${base_version}")
	tarball_name="nerdctl-${version//v}-linux-${ARCH}.tar.gz"
	download_github_project_tarball "${project}" "${version}" "${tarball_name}"
	sudo mkdir -p $ROOT/usr/local/bin
	sudo tar -xvf "${tarball_name}" -C $ROOT/usr/local/bin
	rm -f "${tarball_name}"

	# unmount rootfs
	unmount
	trap - ERR
}

function shutdown() {
	ssh -o ConnectTimeout=5 fvp poweroff || true
	pids=$(ps -ef | grep shrinkwrap-input | grep tail | awk '{ print $2 }')
	for pid in $pids; do kill -9 $pid; done
	rm -rf /tmp/shrinkwrap-input
}

function print_log() {
	if [ -f journal.log ]; then
		echo -e "section_start:`date +%s`:journal-log[collapsed=true]\r\e[0Kjournal log"
		cat journal.log
		echo -e "section_end:`date +%s`:journal-log\r\e[0K"
	fi
	if [ -f shrinkwrap.log ]; then
		echo -e "section_start:`date +%s`:shrinkwrap-log[collapsed=true]\r\e[0Kshrinkwrap log"
		cat shrinkwrap.log
		echo -e "section_end:`date +%s`:shrinkwrap-log\r\e[0K"
	fi
}

function run() {
	info "Running the FVP tests"
	export PATH=$(pwd)/shrinkwrap/shrinkwrap:$PATH
	export PATH=$(pwd)/Base_RevC_AEMvA_pkg/models/Linux64_GCC-9.3:$PATH
	export SHRINKWRAP_PACKAGE=$(pwd)/package
	rootfs=$(pwd)/package/buildroot/rootfs.ext2

	# execute the FVP
	trap shutdown EXIT
	trap print_log ERR
	mkfifo /tmp/shrinkwrap-input
	tail -f /tmp/shrinkwrap-input | shrinkwrap --runtime=null \
		run cca-3world.yaml \
		--rtvar=ROOTFS=$rootfs \
		--overlay=${fvp_dir}/fastram.yaml \
		--rtvar=FASTRAM_CONFIG=${fvp_dir}/fastram.cfg &>shrinkwrap.log &

	# Wait the FVP
	sleep 10
	count=0
	until ssh -o ConnectTimeout=2 fvp exit; do
		count=$((count+1))
		if [ $count -gt 100 ]; then exit -1; fi
		sleep 1
	done

	# log
	ssh fvp journalctl -f &>journal.log &

	# enable services
	ssh fvp systemctl enable nydus-snapshotter
	ssh fvp systemctl enable containerd
	ssh fvp systemctl restart containerd

	# host:
	#   [    0.765484] kvm [1]: RMI ABI version 1.0
	ssh fvp 'uname -r; dmesg | grep -e RME -e RMI'

	# guest with CCA:
	#   [    0.000000] RME: Using RSI version 1.0
	# guest without CCA:
	#   - no output -
	ssh fvp 'nerdctl --snapshotter nydus run --runtime io.containerd.kata.v2 --name test --rm --annotation io.kubernetes.cri.image-name=docker.io/library/busybox:latest docker.io/library/busybox:latest sh -c "uname -r; dmesg | grep -e RME -e RMI || true"'
}

function main() {
	action="${1:-}"
	case "${action}" in
		install-dependencies) install_dependencies ;;
		build-packages) build_packages ;;
		build-rootfs) build_rootfs ;;
		prepare-rootfs) prepare_rootfs ;;
		run) run ;;
		*) >&2 die "Invalid argument" ;;
	esac
}

main "$@"
