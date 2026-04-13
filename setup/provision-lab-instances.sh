#!/usr/bin/env bash
# =============================================================================
# provision-lab-instances.sh
# Provisions one EC2 instance per participant for DevSecOps lab sessions.
# Access is via AWS Systems Manager Session Manager (no SSH / no port 22).
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# CONFIGURATION — edit these before running
# -----------------------------------------------------------------------------
AWS_ACCOUNT_ID="775937640988"          # Your AWS account ID
AWS_REGION="us-east-1"                 # Region to deploy instances in
PARTICIPANT_COUNT=1                    # Number of participants (instances)
INSTANCE_TYPE="t3.medium"             # 2 vCPU / 4 GB — good for Docker labs
COURSE_NAME="devsecops"               # Used for tagging and naming resources

# Ports that lab containers expose — opened in the security group
LAB_PORTS=(3000 8080 8090 9000)

# CIDR allowed to reach the lab ports. "0.0.0.0/0" = open to everyone.
# Restrict to your training network IP range for better security, e.g. "203.0.113.0/24"
ALLOWED_CIDR="0.0.0.0/0"

# IAM role name that will be created and attached to instances (for SSM access)
IAM_ROLE_NAME="${COURSE_NAME}-lab-ssm-role"
IAM_INSTANCE_PROFILE_NAME="${COURSE_NAME}-lab-instance-profile"

# Security group name
SG_NAME="${COURSE_NAME}-lab-sg"

# Amazon Linux 2023 AMI — update if you change region
# Find latest: aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --region $AWS_REGION
AMI_ID="ami-0c02fb55956c7d316"        # Amazon Linux 2023 (us-east-1) — update per region

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARNING: $*" >&2; }
die()  { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; exit 1; }

export AWS_DEFAULT_REGION="$AWS_REGION"

# -----------------------------------------------------------------------------
# Step 1 — Resolve latest Amazon Linux 2023 AMI automatically
# -----------------------------------------------------------------------------
resolve_ami() {
  log "Resolving latest Amazon Linux 2023 AMI for region $AWS_REGION ..."
  local ami
  ami=$(aws ssm get-parameter \
    --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
    --query "Parameter.Value" \
    --output text 2>/dev/null) || true

  if [[ -n "$ami" ]]; then
    AMI_ID="$ami"
    log "Resolved AMI: $AMI_ID"
  else
    warn "Could not auto-resolve AMI. Using configured value: $AMI_ID"
  fi
}

# -----------------------------------------------------------------------------
# Step 2 — Create IAM role + instance profile for SSM Session Manager
# -----------------------------------------------------------------------------
create_iam_role() {
  log "Checking IAM role: $IAM_ROLE_NAME ..."

  if aws iam get-role --role-name "$IAM_ROLE_NAME" &>/dev/null; then
    log "IAM role already exists — skipping creation."
    return
  fi

  log "Creating IAM role: $IAM_ROLE_NAME ..."
  aws iam create-role \
    --role-name "$IAM_ROLE_NAME" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": { "Service": "ec2.amazonaws.com" },
        "Action": "sts:AssumeRole"
      }]
    }' \
    --description "SSM access role for ${COURSE_NAME} lab EC2 instances" \
    --tags Key=Course,Value="$COURSE_NAME" \
    --output text --query "Role.RoleName" > /dev/null

  log "Attaching AmazonSSMManagedInstanceCore policy ..."
  aws iam attach-role-policy \
    --role-name "$IAM_ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

  log "Creating instance profile: $IAM_INSTANCE_PROFILE_NAME ..."
  aws iam create-instance-profile \
    --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" \
    --output text --query "InstanceProfile.InstanceProfileName" > /dev/null

  aws iam add-role-to-instance-profile \
    --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" \
    --role-name "$IAM_ROLE_NAME"

  log "IAM role and instance profile created."
  # Allow a few seconds for IAM to propagate
  sleep 10
}

# -----------------------------------------------------------------------------
# Step 3 — Create security group
# -----------------------------------------------------------------------------
create_security_group() {
  log "Checking security group: $SG_NAME ..."

  local existing_sg_id
  existing_sg_id=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SG_NAME" \
    --query "SecurityGroups[0].GroupId" \
    --output text 2>/dev/null || echo "None")

  if [[ "$existing_sg_id" != "None" && -n "$existing_sg_id" ]]; then
    log "Security group already exists: $existing_sg_id — skipping creation."
    SG_ID="$existing_sg_id"
    return
  fi

  log "Creating security group: $SG_NAME ..."
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "Lab security group for ${COURSE_NAME} - SSM + lab ports" \
    --query "GroupId" \
    --output text)

  log "Security group created: $SG_ID"

  # Open lab application ports (no port 22 — SSM handles shell access)
  for port in "${LAB_PORTS[@]}"; do
    log "  Opening port $port ..."
    aws ec2 authorize-security-group-ingress \
      --group-id "$SG_ID" \
      --protocol tcp \
      --port "$port" \
      --cidr "$ALLOWED_CIDR" > /dev/null
  done

  aws ec2 create-tags \
    --resources "$SG_ID" \
    --tags Key=Name,Value="$SG_NAME" Key=Course,Value="$COURSE_NAME"

  log "Security group configured: $SG_ID"
}

# -----------------------------------------------------------------------------
# Step 4 — User data: install Docker + Docker Compose on instance boot
# -----------------------------------------------------------------------------
build_user_data() {
  cat <<'USERDATA'
#!/bin/bash
set -euo pipefail

# Required for Elasticsearch/OpenSearch containers
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" >> /etc/sysctl.conf

# Update system
dnf update -y

# Install Docker
dnf install -y docker
systemctl enable docker
systemctl start docker

# Allow ec2-user to run docker without sudo
usermod -aG docker ec2-user

# SSM Session Manager connects as ssm-user. Create it now so the SSM agent
# reuses this user (with docker group membership) instead of creating a new one.
useradd -m ssm-user 2>/dev/null || true
usermod -aG docker ssm-user

# Install Docker Compose v2 (plugin)
COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest \
  | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# Convenience symlink so both `docker-compose` and `docker compose` work
ln -sf /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose

# Clone lab materials into ec2-user home (update URL if private repo)
# git clone https://github.com/your-org/your-lab-repo.git /home/ec2-user/labs
# chown -R ec2-user:ec2-user /home/ec2-user/labs

echo "Docker setup complete" > /var/log/lab-setup.log
docker --version >> /var/log/lab-setup.log
docker compose version >> /var/log/lab-setup.log
USERDATA
}

# -----------------------------------------------------------------------------
# Step 5 — Launch one EC2 instance per participant
# -----------------------------------------------------------------------------
launch_instances() {
  log "Launching $PARTICIPANT_COUNT instance(s) ..."

  local user_data
  user_data=$(build_user_data | base64)

  for i in $(seq 1 "$PARTICIPANT_COUNT"); do
    local name="${COURSE_NAME}-lab-participant-${i}"
    log "  Launching: $name ..."

    local instance_id
    instance_id=$(aws ec2 run-instances \
      --image-id "$AMI_ID" \
      --instance-type "$INSTANCE_TYPE" \
      --iam-instance-profile "Name=$IAM_INSTANCE_PROFILE_NAME" \
      --security-group-ids "$SG_ID" \
      --user-data "$user_data" \
      --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
      --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":20,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
      --tag-specifications \
        "ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=Course,Value=${COURSE_NAME}},{Key=Participant,Value=${i}}]" \
        "ResourceType=volume,Tags=[{Key=Name,Value=${name}},{Key=Course,Value=${COURSE_NAME}}]" \
      --query "Instances[0].InstanceId" \
      --output text)

    log "  Launched: $instance_id ($name)"
    INSTANCE_IDS+=("$instance_id")
  done
}

# -----------------------------------------------------------------------------
# Step 6 — Wait for instances and print connection info
# -----------------------------------------------------------------------------
print_connection_info() {
  log "Waiting for instances to reach running state ..."
  aws ec2 wait instance-running --instance-ids "${INSTANCE_IDS[@]}"
  log "All instances are running."

  echo ""
  echo "============================================================"
  echo " Lab Instance Summary"
  echo "============================================================"
  printf "%-14s %-22s %-35s %s\n" "PARTICIPANT" "INSTANCE ID" "PUBLIC DNS" "SSM CONNECT URL"
  echo "------------------------------------------------------------"

  for i in "${!INSTANCE_IDS[@]}"; do
    local id="${INSTANCE_IDS[$i]}"
    local participant=$((i + 1))
    local dns
    dns=$(aws ec2 describe-instances \
      --instance-ids "$id" \
      --query "Reservations[0].Instances[0].PublicDnsName" \
      --output text)

    local ssm_url="https://console.aws.amazon.com/systems-manager/session-manager/${id}?region=${AWS_REGION}"
    printf "%-14s %-22s %-35s %s\n" "$participant" "$id" "$dns" "$ssm_url"
  done

  echo ""
  echo "Lab ports open per instance: ${LAB_PORTS[*]}"
  echo "Access services via: http://<PUBLIC_DNS>:<PORT>"
  echo ""
  echo "NOTE: Docker install runs in the background via user data."
  echo "      Wait ~2 minutes after instance start before using Docker."
  echo "      Check progress: sudo tail -f /var/log/lab-setup.log"
  echo "============================================================"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
INSTANCE_IDS=()

resolve_ami
create_iam_role
create_security_group
launch_instances
print_connection_info
