#!/bin/bash
# Generic base provisioning for neardoc-terraform-modules' ec2-instance module. Runs on every
# boot via cloud-init (idempotent — safe to rerun). Caller-specific provisioning is appended
# below this point via var.additional_user_data; this base script knows nothing about any
# particular application, compose file, or secret store.
set -euxo pipefail

# --- 1. Base packages ---
apt-get update -y
apt-get install -y ca-certificates curl gnupg jq unzip

# --- 2. Docker ---
if ! command -v docker &> /dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
fi

# --- 3. AWS CLI v2 ---
if ! command -v aws &> /dev/null; then
  curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
fi

%{ if mount_data_volume ~}
# --- 4. Mount the separately-managed data EBS volume (optional, enabled by var.mount_data_volume) ---
DATA_DEV=$(lsblk -ndo NAME,MOUNTPOINT | awk '$2=="" && $1!~/^loop/ {print "/dev/"$1; exit}')
mkdir -p ${data_mount_path}
if [ -n "$DATA_DEV" ]; then
  if ! blkid "$DATA_DEV" &> /dev/null; then
    mkfs.ext4 "$DATA_DEV"
  fi
  if ! mountpoint -q ${data_mount_path}; then
    mount "$DATA_DEV" ${data_mount_path}
  fi
  grep -q "${data_mount_path}" /etc/fstab || echo "$DATA_DEV ${data_mount_path} ext4 defaults,nofail 0 2" >> /etc/fstab
fi
%{ endif ~}

%{ if config_s3_bucket != "" ~}
# --- 5. ECR login + sync app config from S3 (optional, enabled when var.config_s3_bucket is set) ---
REGION="${aws_region}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

mkdir -p ${app_root}
aws s3 sync "s3://${config_s3_bucket}/${config_s3_prefix}" "${app_root}" --delete
%{ endif ~}

# --- 6. Caller-specific provisioning ---
${additional_user_data}
