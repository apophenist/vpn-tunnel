#!/bin/bash

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly STATE_DIR="$HOME/.vpn-tunnel"
readonly STATE_FILE="$STATE_DIR/active.state"
readonly INSTANCE_TAG_KEY="VpnTunnel"
readonly INSTANCE_TAG_VALUE="OnDemand"
readonly SECURITY_GROUP_BASE="vpn-tunnel-sg"
readonly KEY_PAIR_BASE="vpn-tunnel-key"
readonly DEFAULT_IDLE_TIMEOUT=30  # minutes
readonly MAX_INSTANCE_LIFETIME=60  # minutes

print_usage() {
    cat << EOF
Usage: $SCRIPT_NAME <command> [options]

Commands:
    start --region <REGION>    Start VPN tunnel
    stop                       Stop active VPN tunnel
    status                     Show tunnel status
    cleanup                    Force cleanup of resources

Options:
    --region <REGION>         AWS region or alias (EU, US, ASIA, etc.)
    --instance-type <TYPE>    Instance type (default: t3.nano)
    --idle-timeout <MINUTES>  Idle timeout in minutes (default: $DEFAULT_IDLE_TIMEOUT)
    --help                    Show this help

Examples:
    $SCRIPT_NAME start --region EU
    $SCRIPT_NAME start --region us-west-2
    $SCRIPT_NAME status
    $SCRIPT_NAME stop
EOF
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

error() {
    log "ERROR: $*"
    exit 1
}

check_dependencies() {
    command -v aws >/dev/null 2>&1 || error "AWS CLI not found. Please install and configure AWS CLI."
    command -v sshuttle >/dev/null 2>&1 || error "sshuttle not found. Please install sshuttle."
    
    # Check AWS configuration
    aws sts get-caller-identity >/dev/null 2>&1 || error "AWS CLI not configured. Run 'aws configure'."
}

init_state_dir() {
    mkdir -p "$STATE_DIR"
}

is_tunnel_active() {
    [[ -f "$STATE_FILE" ]] && [[ -s "$STATE_FILE" ]]
}

get_state() {
    if is_tunnel_active; then
        cat "$STATE_FILE"
    else
        return 1
    fi
}

save_state() {
    local instance_id="$1"
    local region="$2"
    local key_file="$3"
    
    cat > "$STATE_FILE" << EOF
INSTANCE_ID=$instance_id
REGION=$region
KEY_FILE=$key_file
STARTED_AT=$(date '+%s')
EOF
}

clear_state() {
    rm -f "$STATE_FILE"
}

# Region mapping functions
map_region_alias() {
    local region="$1"
    local upper_region
    
    # Convert to uppercase using tr for compatibility
    upper_region=$(echo "$region" | tr '[:lower:]' '[:upper:]')
    
    case "$upper_region" in
        EU)
            echo "eu-west-1"
            ;;
        US)
            echo "us-east-1"
            ;;
        ASIA)
            echo "ap-southeast-1"
            ;;
        APAC)
            echo "ap-southeast-1"
            ;;
        *)
            # Assume it's already a valid AWS region
            echo "$region"
            ;;
    esac
}

validate_aws_region() {
    local region="$1"
    
    # Check if region exists by attempting to describe availability zones
    if aws ec2 describe-availability-zones --region "$region" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

resolve_region() {
    local input_region="$1"
    local mapped_region
    
    mapped_region=$(map_region_alias "$input_region")
    
    if validate_aws_region "$mapped_region"; then
        echo "$mapped_region"
    else
        error "Invalid or inaccessible AWS region: $mapped_region (from input: $input_region)"
    fi
}

# AWS resource management functions
get_latest_ubuntu_ami() {
    local region="$1"
    
    aws ec2 describe-images \
        --region "$region" \
        --owners 099720109477 \
        --filters \
            'Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*' \
            'Name=state,Values=available' \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text
}

create_security_group() {
    local region="$1"
    local group_name="$2"
    
    log "Creating security group: $group_name"
    
    # Check if security group already exists
    if aws ec2 describe-security-groups --region "$region" --group-names "$group_name" >/dev/null 2>&1; then
        log "Security group $group_name already exists"
        aws ec2 describe-security-groups --region "$region" --group-names "$group_name" --query 'SecurityGroups[0].GroupId' --output text
        return
    fi
    
    # Create security group
    local group_id
    group_id=$(aws ec2 create-security-group \
        --region "$region" \
        --group-name "$group_name" \
        --description "VPN Tunnel SSH access" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=$INSTANCE_TAG_KEY,Value=$INSTANCE_TAG_VALUE}]" \
        --query 'GroupId' --output text)
    
    # Add SSH rule
    aws ec2 authorize-security-group-ingress \
        --region "$region" \
        --group-id "$group_id" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 >/dev/null
    
    echo "$group_id"
}

create_key_pair() {
    local region="$1"
    local key_name="$2"
    local key_file="$STATE_DIR/$key_name.pem"
    
    log "Creating SSH key pair: $key_name"
    
    # Remove existing key file
    rm -f "$key_file"
    
    # Delete existing key pair if it exists
    aws ec2 delete-key-pair --region "$region" --key-name "$key_name" >/dev/null 2>&1 || true
    
    # Create new key pair
    aws ec2 create-key-pair \
        --region "$region" \
        --key-name "$key_name" \
        --tag-specifications "ResourceType=key-pair,Tags=[{Key=$INSTANCE_TAG_KEY,Value=$INSTANCE_TAG_VALUE}]" \
        --query 'KeyMaterial' --output text > "$key_file"
    
    chmod 600 "$key_file"
    echo "$key_file"
}

launch_spot_instance() {
    local region="$1"
    local instance_type="$2"
    local ami_id="$3"
    local key_name="$4"
    local security_group_id="$5"
    local idle_timeout="$6"
    
    log "Launching spot instance ($instance_type) in $region"
    
    # Create user data script for auto-termination
    local user_data
    user_data=$(cat << 'EOF' | base64 | tr -d '\n'
#!/bin/bash
# Update system (Ubuntu, not CentOS)
apt-get update -y
apt-get install -y bc at

# Self-termination script
cat > /usr/local/bin/check-idle.sh << 'IDLESCRIPT'
#!/bin/bash
IDLE_THRESHOLD=90
IDLE_DURATION=1800  # 30 minutes

# Get CPU idle percentage
cpu_idle=$(top -bn1 | grep "Cpu(s)" | awk '{print $8}' | sed 's/%id,//' | sed 's/%id//')

# Use basic comparison since bc might not be available initially
if [[ $(echo "$cpu_idle > $IDLE_THRESHOLD" | bc -l 2>/dev/null || echo 0) -eq 1 ]]; then
    # Check if idle for extended period
    if [[ -f /tmp/idle_start ]]; then
        idle_start=$(cat /tmp/idle_start)
        now=$(date +%s)
        idle_time=$((now - idle_start))
        if [[ $idle_time -gt $IDLE_DURATION ]]; then
            logger "VPN tunnel idle for ${idle_time}s, terminating instance"
            shutdown -h now
        fi
    else
        date +%s > /tmp/idle_start
    fi
else
    rm -f /tmp/idle_start
fi
IDLESCRIPT

chmod +x /usr/local/bin/check-idle.sh

# Add cron job for idle checking every 5 minutes
echo "*/5 * * * * /usr/local/bin/check-idle.sh" | crontab -

# Self-destruct after max lifetime using at command
echo "shutdown -h now" | at now + IDLE_TIMEOUT_PLACEHOLDER minutes 2>/dev/null || true

# Log startup
logger "VPN tunnel instance started with auto-termination after IDLE_TIMEOUT_PLACEHOLDER minutes"
EOF
)
    
    # Replace placeholder with actual timeout
    user_data=$(echo "$user_data" | base64 -d | sed "s/IDLE_TIMEOUT_PLACEHOLDER/$((idle_timeout * 2))/" | base64 | tr -d '\n')
    
    # Launch spot instance
    local instance_id
    instance_id=$(aws ec2 run-instances \
        --region "$region" \
        --image-id "$ami_id" \
        --instance-type "$instance_type" \
        --key-name "$key_name" \
        --security-group-ids "$security_group_id" \
        --user-data "$user_data" \
        --instance-market-options 'MarketType=spot,SpotOptions={MaxPrice=0.10,SpotInstanceType=one-time}' \
        --tag-specifications "ResourceType=instance,Tags=[{Key=$INSTANCE_TAG_KEY,Value=$INSTANCE_TAG_VALUE},{Key=Name,Value=vpn-tunnel-instance}]" \
        --query 'Instances[0].InstanceId' --output text)
    
    echo "$instance_id"
}

wait_for_instance_ready() {
    local region="$1"
    local instance_id="$2"
    local key_file="$3"
    local max_wait=300  # 5 minutes
    local waited=0
    
    log "Waiting for instance $instance_id to be ready..."
    
    # Wait for instance to be running
    aws ec2 wait instance-running --region "$region" --instance-ids "$instance_id"
    
    # Get public IP
    local public_ip
    public_ip=$(aws ec2 describe-instances \
        --region "$region" \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
    
    log "Instance public IP: $public_ip"
    
    # Wait for SSH to be available
    while [[ $waited -lt $max_wait ]]; do
        if ssh -i "$key_file" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
           ubuntu@"$public_ip" "echo 'SSH ready'" >/dev/null 2>&1; then
            log "Instance is ready for SSH connections"
            echo "$public_ip"
            return 0
        fi
        
        log "Waiting for SSH... ($waited/${max_wait}s)"
        sleep 10
        waited=$((waited + 10))
    done
    
    error "Instance failed to become ready within ${max_wait} seconds"
}

# sshuttle integration functions
start_sshuttle_tunnel() {
    local public_ip="$1"
    local key_file="$2"
    local tunnel_pid_file="$STATE_DIR/sshuttle.pid"
    
    log "Starting sshuttle tunnel to $public_ip..."
    
    # Start sshuttle in background and capture PID
    sshuttle \
        --ssh-cmd "ssh -i $key_file -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
        -r ubuntu@"$public_ip" \
        0.0.0.0/0 \
        --pidfile="$tunnel_pid_file" \
        --daemon
    
    # Wait a moment for tunnel to establish
    sleep 3
    
    # Check if tunnel is running
    if [[ -f "$tunnel_pid_file" ]] && kill -0 "$(cat "$tunnel_pid_file")" 2>/dev/null; then
        log "sshuttle tunnel started successfully (PID: $(cat "$tunnel_pid_file"))"
        echo "$(cat "$tunnel_pid_file")"
    else
        error "Failed to start sshuttle tunnel"
    fi
}

monitor_sshuttle_tunnel() {
    local tunnel_pid="$1"
    local cleanup_func="$2"
    
    log "Monitoring sshuttle tunnel (PID: $tunnel_pid)"
    log "Press Ctrl+C to stop the VPN tunnel"
    
    # Set trap for cleanup on exit
    trap "$cleanup_func" EXIT INT TERM
    
    # Monitor tunnel process
    while kill -0 "$tunnel_pid" 2>/dev/null; do
        sleep 5
    done
    
    log "sshuttle tunnel has stopped"
}

stop_sshuttle_tunnel() {
    local tunnel_pid_file="$STATE_DIR/sshuttle.pid"
    
    if [[ -f "$tunnel_pid_file" ]]; then
        local pid
        pid=$(cat "$tunnel_pid_file")
        
        if kill -0 "$pid" 2>/dev/null; then
            log "Stopping sshuttle tunnel (PID: $pid)"
            kill "$pid"
            
            # Wait for process to stop
            local waited=0
            while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 30 ]]; do
                sleep 1
                waited=$((waited + 1))
            done
            
            if kill -0 "$pid" 2>/dev/null; then
                log "Force killing sshuttle process"
                kill -9 "$pid" || true
            fi
        fi
        
        rm -f "$tunnel_pid_file"
    fi
}

# Cleanup and resource management functions
cleanup_aws_resources() {
    local region="$1"
    local instance_id="$2"
    local key_name="$3"
    local security_group_name="$4"
    
    log "Cleaning up AWS resources..."
    
    # Terminate instance
    if [[ -n "$instance_id" && "$instance_id" != "None" ]]; then
        log "Terminating instance: $instance_id"
        aws ec2 terminate-instances --region "$region" --instance-ids "$instance_id" >/dev/null 2>&1 || true
        
        # Wait for instance to terminate
        log "Waiting for instance to terminate..."
        aws ec2 wait instance-terminated --region "$region" --instance-ids "$instance_id" 2>/dev/null || true
    fi
    
    # Delete key pair
    if [[ -n "$key_name" ]]; then
        log "Deleting key pair: $key_name"
        aws ec2 delete-key-pair --region "$region" --key-name "$key_name" >/dev/null 2>&1 || true
        rm -f "$STATE_DIR/$key_name.pem"
    fi
    
    # Delete security group (with retry logic)
    if [[ -n "$security_group_name" ]]; then
        log "Deleting security group: $security_group_name"
        local retries=5
        local wait_time=5
        
        for ((i=1; i<=retries; i++)); do
            if aws ec2 delete-security-group --region "$region" --group-name "$security_group_name" >/dev/null 2>&1; then
                log "Security group deleted successfully"
                break
            elif [[ $i -eq $retries ]]; then
                log "Warning: Could not delete security group after $retries attempts"
            else
                log "Security group deletion failed, retrying in ${wait_time}s... ($i/$retries)"
                sleep $wait_time
            fi
        done
    fi
}

cleanup_session() {
    log "Cleaning up current session..."
    
    # Stop sshuttle tunnel
    stop_sshuttle_tunnel
    
    # Clean up AWS resources if we have state
    if is_tunnel_active; then
        local state
        state=$(get_state)
        eval "$state"
        
        cleanup_aws_resources "$REGION" "$INSTANCE_ID" "$ACTIVE_KEY_NAME" "$ACTIVE_SECURITY_GROUP_NAME"
    fi
    
    # Clear state
    clear_state
    
    log "Session cleanup completed"
}

cleanup_all() {
    log "Performing complete cleanup..."
    
    # First do session cleanup
    cleanup_session
    
    # Then do comprehensive orphaned resource cleanup
    log "Performing comprehensive cleanup across all regions..."
    cleanup_orphaned_resources ""
    
    log "Complete cleanup finished"
}

cleanup_orphaned_resources() {
    local target_region="$1"
    
    if [[ -n "$target_region" ]]; then
        log "Checking for orphaned VPN tunnel resources in region: $target_region"
        local regions="$target_region"
    else
        log "Checking for orphaned VPN tunnel resources in all regions..."
        # Get all regions to check (fallback for comprehensive cleanup)
        local regions
        regions=$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text)
    fi
    
    for region in $regions; do
        log "Checking region: $region"
        
        # Find tagged instances
        local instances
        instances=$(aws ec2 describe-instances \
            --region "$region" \
            --filters "Name=tag:$INSTANCE_TAG_KEY,Values=$INSTANCE_TAG_VALUE" "Name=instance-state-name,Values=running,pending" \
            --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)
        
        if [[ -n "$instances" ]]; then
            log "Found orphaned instances in $region: $instances"
            for instance in $instances; do
                log "Terminating orphaned instance: $instance"
                aws ec2 terminate-instances --region "$region" --instance-ids "$instance" >/dev/null 2>&1 || true
            done
        fi
        
        # Find tagged security groups
        local security_groups
        security_groups=$(aws ec2 describe-security-groups \
            --region "$region" \
            --filters "Name=tag:$INSTANCE_TAG_KEY,Values=$INSTANCE_TAG_VALUE" \
            --query 'SecurityGroups[].GroupName' --output text 2>/dev/null || true)
        
        if [[ -n "$security_groups" ]]; then
            log "Found orphaned security groups in $region: $security_groups"
            for sg in $security_groups; do
                log "Deleting orphaned security group: $sg"
                # Add delay to let instances fully terminate
                sleep 10
                aws ec2 delete-security-group --region "$region" --group-name "$sg" >/dev/null 2>&1 || true
            done
        fi
        
        # Find tagged key pairs
        local key_pairs
        key_pairs=$(aws ec2 describe-key-pairs \
            --region "$region" \
            --filters "Name=tag:$INSTANCE_TAG_KEY,Values=$INSTANCE_TAG_VALUE" \
            --query 'KeyPairs[].KeyName' --output text 2>/dev/null || true)
        
        if [[ -n "$key_pairs" ]]; then
            log "Found orphaned key pairs in $region: $key_pairs"
            for kp in $key_pairs; do
                log "Deleting orphaned key pair: $kp"
                aws ec2 delete-key-pair --region "$region" --key-name "$kp" >/dev/null 2>&1 || true
            done
        fi
    done
}

# Command handlers
cmd_start() {
    local region=""
    local instance_type="t3.nano"
    local idle_timeout="$DEFAULT_IDLE_TIMEOUT"
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --region)
                region="$2"
                shift 2
                ;;
            --instance-type)
                instance_type="$2"
                shift 2
                ;;
            --idle-timeout)
                idle_timeout="$2"
                shift 2
                ;;
            *)
                error "Unknown option: $1"
                ;;
        esac
    done
    
    [[ -n "$region" ]] || error "Region is required. Use --region option."
    
    if is_tunnel_active; then
        error "VPN tunnel is already active. Use '$SCRIPT_NAME stop' first."
    fi
    
    # Resolve region
    region=$(resolve_region "$region")
    log "Starting VPN tunnel in region $region..."
    
    # Generate unique names
    local timestamp
    timestamp=$(date +%s)
    local key_name="${KEY_PAIR_BASE}-${timestamp}"
    local security_group_name="${SECURITY_GROUP_BASE}-${timestamp}"
    
    # Get latest Ubuntu AMI
    log "Finding latest Ubuntu AMI..."
    local ami_id
    ami_id=$(get_latest_ubuntu_ami "$region")
    log "Using AMI: $ami_id"
    
    # Create security group
    local security_group_id
    security_group_id=$(create_security_group "$region" "$security_group_name")
    
    # Create SSH key pair
    local key_file
    key_file=$(create_key_pair "$region" "$key_name")
    
    # Launch spot instance
    local instance_id
    instance_id=$(launch_spot_instance "$region" "$instance_type" "$ami_id" "$key_name" "$security_group_id" "$idle_timeout")
    log "Instance launched: $instance_id"
    
    # Save state
    save_state "$instance_id" "$region" "$key_file"
    echo "ACTIVE_SECURITY_GROUP_NAME=$security_group_name" >> "$STATE_FILE"
    echo "ACTIVE_KEY_NAME=$key_name" >> "$STATE_FILE"
    
    # Set up cleanup on exit (fast session cleanup only)
    trap 'cleanup_session' EXIT INT TERM
    
    # Wait for instance to be ready
    local public_ip
    public_ip=$(wait_for_instance_ready "$region" "$instance_id" "$key_file")
    
    # Start sshuttle tunnel
    local tunnel_pid
    tunnel_pid=$(start_sshuttle_tunnel "$public_ip" "$key_file")
    
    # Monitor tunnel (this blocks until tunnel stops)
    monitor_sshuttle_tunnel "$tunnel_pid" "cleanup_session"
}

cmd_stop() {
    if ! is_tunnel_active; then
        log "No active VPN tunnel found."
        return 0
    fi
    
    log "Stopping VPN tunnel..."
    cleanup_session
}

cmd_status() {
    if ! is_tunnel_active; then
        echo "No active VPN tunnel."
        return 0
    fi
    
    local state
    state=$(get_state)
    eval "$state"
    
    echo "VPN Tunnel Status:"
    echo "  Instance ID: $INSTANCE_ID"
    echo "  Region: $REGION"
    echo "  Started: $(date -r "$STARTED_AT" '+%Y-%m-%d %H:%M:%S')"
    
    # Check instance status
    local instance_state
    instance_state=$(aws ec2 describe-instances \
        --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null || echo "unknown")
    echo "  Instance State: $instance_state"
    
    # Check sshuttle tunnel status
    local tunnel_pid_file="$STATE_DIR/sshuttle.pid"
    if [[ -f "$tunnel_pid_file" ]]; then
        local tunnel_pid
        tunnel_pid=$(cat "$tunnel_pid_file")
        if kill -0 "$tunnel_pid" 2>/dev/null; then
            echo "  sshuttle Status: Running (PID: $tunnel_pid)"
        else
            echo "  sshuttle Status: Not running"
        fi
    else
        echo "  sshuttle Status: Not started"
    fi
    
    # Show runtime
    local now
    now=$(date +%s)
    local runtime=$((now - STARTED_AT))
    echo "  Runtime: $((runtime / 3600))h $((runtime % 3600 / 60))m $((runtime % 60))s"
}

cmd_cleanup() {
    log "Performing cleanup of VPN tunnel resources..."
    cleanup_all
    
    # For manual cleanup command, do comprehensive check of all regions
    log "Performing comprehensive cleanup across all regions..."
    cleanup_orphaned_resources ""
}

main() {
    if [[ $# -eq 0 ]]; then
        print_usage
        exit 1
    fi
    
    check_dependencies
    init_state_dir
    
    local command="$1"
    shift
    
    case "$command" in
        start)
            cmd_start "$@"
            ;;
        stop)
            cmd_stop "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        cleanup)
            cmd_cleanup "$@"
            ;;
        --help|-h|help)
            print_usage
            exit 0
            ;;
        *)
            error "Unknown command: $command. Use --help for usage information."
            ;;
    esac
}

main "$@"