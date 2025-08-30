#!/bin/bash

# SSH Debug Helper for VPN Tunnel
# This script helps debug SSH connectivity issues

set -euo pipefail

readonly STATE_DIR="$HOME/.vpn-tunnel"
readonly STATE_FILE="$STATE_DIR/active.state"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

if [[ ! -f "$STATE_FILE" ]]; then
    echo "No active VPN tunnel state found. Please start a tunnel first."
    exit 1
fi

# Load state
eval "$(cat "$STATE_FILE")"

echo "=== VPN Tunnel SSH Debug ==="
echo "Instance ID: $INSTANCE_ID"
echo "Region: $REGION"
echo "Key file: $KEY_FILE"
echo ""

# Get current instance info
log "Getting instance information..."
INSTANCE_INFO=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0]')

PUBLIC_IP=$(echo "$INSTANCE_INFO" | jq -r '.PublicIpAddress // "null"')
INSTANCE_STATE=$(echo "$INSTANCE_INFO" | jq -r '.State.Name')
SECURITY_GROUPS=$(echo "$INSTANCE_INFO" | jq -r '.SecurityGroups[].GroupId' | tr '\n' ' ')

echo "Instance State: $INSTANCE_STATE"
echo "Public IP: $PUBLIC_IP"
echo "Security Groups: $SECURITY_GROUPS"
echo ""

if [[ "$PUBLIC_IP" == "null" || -z "$PUBLIC_IP" ]]; then
    echo "ERROR: Instance has no public IP address!"
    echo "This could mean:"
    echo "  - Instance is not in a public subnet"
    echo "  - Instance doesn't have a public IP assigned"
    echo "  - Instance is still starting up"
    exit 1
fi

# Check key file
log "Checking SSH key file..."
if [[ ! -f "$KEY_FILE" ]]; then
    echo "ERROR: Key file not found: $KEY_FILE"
    exit 1
fi

KEY_PERMS=$(stat -f "%A" "$KEY_FILE" 2>/dev/null || stat -c "%a" "$KEY_FILE" 2>/dev/null)
echo "Key file permissions: $KEY_PERMS"
if [[ "$KEY_PERMS" != "600" ]]; then
    echo "WARNING: Key file permissions should be 600"
    echo "Fixing permissions..."
    chmod 600 "$KEY_FILE"
fi

# Check security group rules
log "Checking security group rules..."
for sg in $SECURITY_GROUPS; do
    echo "Security Group: $sg"
    aws ec2 describe-security-groups \
        --region "$REGION" \
        --group-ids "$sg" \
        --query 'SecurityGroups[0].IpPermissions[?FromPort==`22`]' \
        --output table
done

# Test network connectivity
log "Testing network connectivity..."
echo "Pinging instance..."
if ping -c 3 "$PUBLIC_IP" >/dev/null 2>&1; then
    echo "✓ Ping successful"
else
    echo "✗ Ping failed - network connectivity issue"
fi

echo ""
echo "Testing SSH port (22)..."
if nc -z -w5 "$PUBLIC_IP" 22 >/dev/null 2>&1; then
    echo "✓ Port 22 is open"
else
    echo "✗ Port 22 is not accessible"
    echo "This could mean:"
    echo "  - Security group doesn't allow SSH from your IP"
    echo "  - SSH service not running on instance"
    echo "  - Network routing issue"
fi

# Test SSH with verbose output
echo ""
log "Testing SSH connection with verbose output..."
echo "Attempting SSH connection (this may take a moment)..."
echo "If it hangs here, the issue is likely:"
echo "  1. SSH daemon not yet started"
echo "  2. Instance still booting"
echo "  3. Security group blocking connection"
echo ""

ssh -i "$KEY_FILE" \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes \
    -v \
    ubuntu@"$PUBLIC_IP" "echo 'SSH connection successful!'; uptime" 2>&1

echo ""
echo "=== Debug completed ==="
echo ""
echo "If SSH failed, try waiting a few more minutes for the instance to fully boot."
echo "The instance user data script may still be running in the background."
echo ""
echo "You can also try manual SSH with:"
echo "ssh -i '$KEY_FILE' -o StrictHostKeyChecking=no ubuntu@$PUBLIC_IP"
