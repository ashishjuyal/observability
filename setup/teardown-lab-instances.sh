#!/usr/bin/env bash
# =============================================================================
# teardown-lab-instances.sh
# Terminates all EC2 instances and removes supporting resources created by
# provision-lab-instances.sh for the DevSecOps lab.
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# CONFIGURATION — must match provision-lab-instances.sh
# -----------------------------------------------------------------------------
AWS_REGION="us-east-1"
COURSE_NAME="devsecops"

IAM_ROLE_NAME="${COURSE_NAME}-lab-ssm-role"
IAM_INSTANCE_PROFILE_NAME="${COURSE_NAME}-lab-instance-profile"
SG_NAME="${COURSE_NAME}-lab-sg"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARNING: $*" >&2; }

export AWS_DEFAULT_REGION="$AWS_REGION"

# -----------------------------------------------------------------------------
# Step 1 — Terminate EC2 instances tagged with Course=<COURSE_NAME>
# -----------------------------------------------------------------------------
terminate_instances() {
  log "Looking for instances tagged Course=$COURSE_NAME ..."

  local instance_ids
  instance_ids=$(aws ec2 describe-instances \
    --filters \
      "Name=tag:Course,Values=$COURSE_NAME" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[*].Instances[*].InstanceId" \
    --output text)

  if [[ -z "$instance_ids" ]]; then
    log "No running instances found for Course=$COURSE_NAME — skipping."
    return
  fi

  log "Terminating instances: $instance_ids"
  aws ec2 terminate-instances --instance-ids $instance_ids --output text > /dev/null

  log "Waiting for instances to terminate (this may take ~60s) ..."
  aws ec2 wait instance-terminated --instance-ids $instance_ids
  log "All instances terminated."
}

# -----------------------------------------------------------------------------
# Step 2 — Delete security group
# -----------------------------------------------------------------------------
delete_security_group() {
  log "Looking for security group: $SG_NAME ..."

  local sg_id
  sg_id=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SG_NAME" \
    --query "SecurityGroups[0].GroupId" \
    --output text 2>/dev/null || echo "None")

  if [[ "$sg_id" == "None" || -z "$sg_id" ]]; then
    log "Security group not found — skipping."
    return
  fi

  log "Deleting security group: $sg_id ..."
  aws ec2 delete-security-group --group-id "$sg_id"
  log "Security group deleted."
}

# -----------------------------------------------------------------------------
# Step 3 — Remove IAM role and instance profile
# -----------------------------------------------------------------------------
delete_iam_role() {
  log "Checking IAM instance profile: $IAM_INSTANCE_PROFILE_NAME ..."

  if aws iam get-instance-profile --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" &>/dev/null; then
    log "Detaching role from instance profile ..."
    aws iam remove-role-from-instance-profile \
      --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" \
      --role-name "$IAM_ROLE_NAME" 2>/dev/null || true

    log "Deleting instance profile: $IAM_INSTANCE_PROFILE_NAME ..."
    aws iam delete-instance-profile \
      --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME"
    log "Instance profile deleted."
  else
    log "Instance profile not found — skipping."
  fi

  log "Checking IAM role: $IAM_ROLE_NAME ..."

  if aws iam get-role --role-name "$IAM_ROLE_NAME" &>/dev/null; then
    log "Detaching managed policies from role ..."
    local policies
    policies=$(aws iam list-attached-role-policies \
      --role-name "$IAM_ROLE_NAME" \
      --query "AttachedPolicies[*].PolicyArn" \
      --output text)

    for arn in $policies; do
      log "  Detaching: $arn"
      aws iam detach-role-policy --role-name "$IAM_ROLE_NAME" --policy-arn "$arn"
    done

    log "Deleting IAM role: $IAM_ROLE_NAME ..."
    aws iam delete-role --role-name "$IAM_ROLE_NAME"
    log "IAM role deleted."
  else
    log "IAM role not found — skipping."
  fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
echo "============================================================"
echo " Teardown: $COURSE_NAME lab — region: $AWS_REGION"
echo "============================================================"
echo ""
read -r -p "This will TERMINATE all instances and delete IAM/SG resources. Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
echo ""

terminate_instances
delete_security_group
delete_iam_role

echo ""
echo "============================================================"
echo " Teardown complete. All $COURSE_NAME lab resources removed."
echo "============================================================"
