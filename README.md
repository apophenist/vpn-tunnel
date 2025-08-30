# VPN Tunnel Script

A lightweight, cost-effective VPN solution using AWS EC2 spot instances and sshuttle.

## Features

- **Fast setup**: Launches EC2 spot instances in under 2 minutes
- **Cost-effective**: Uses spot instances with automatic termination
- **Multiple regions**: Support for high-level region aliases (EU, US, ASIA)
- **Auto-cleanup**: Comprehensive cleanup mechanisms prevent resource leaks
- **Failsafe**: Multiple auto-termination mechanisms (idle timeout, max runtime)
- **Simple interface**: Single script with intuitive commands

## Prerequisites

1. **AWS CLI** installed and configured:
   ```bash
   aws configure
   ```

2. **sshuttle** installed:
   ```bash
   # macOS
   brew install sshuttle
   
   # Ubuntu/Debian
   apt-get install sshuttle
   
   # Other systems
   pip install sshuttle
   ```

3. AWS permissions for:
   - EC2 instances (create, terminate, describe)
   - Security groups (create, delete, authorize)
   - Key pairs (create, delete)

## Usage

### Start VPN Tunnel

```bash
# Using region aliases
./vpn-tunnel.sh start --region EU
./vpn-tunnel.sh start --region US
./vpn-tunnel.sh start --region ASIA

# Using specific AWS regions
./vpn-tunnel.sh start --region us-west-2
./vpn-tunnel.sh start --region eu-central-1

# With custom options
./vpn-tunnel.sh start --region EU --instance-type t3.micro --idle-timeout 60
```

### Monitor Status

```bash
./vpn-tunnel.sh status
```

### Stop Tunnel

```bash
./vpn-tunnel.sh stop
# OR press Ctrl+C in the tunnel monitoring window
```

### Force Cleanup

```bash
./vpn-tunnel.sh cleanup
```

## Region Aliases

- **EU**: eu-west-1 (Ireland)
- **US**: us-east-1 (Virginia)
- **ASIA**/**APAC**: ap-southeast-1 (Singapore)

## How It Works

1. **Instance Launch**: Creates a spot EC2 instance with Ubuntu 22.04
2. **Network Setup**: Creates temporary security group allowing SSH access
3. **SSH Keys**: Generates temporary SSH key pair for secure access
4. **Tunnel Creation**: Establishes sshuttle tunnel routing all traffic (0.0.0.0/0)
5. **Monitoring**: Continuously monitors tunnel health
6. **Auto-cleanup**: Terminates resources when tunnel stops

## Safety Features

### Auto-termination Triggers
- **Idle detection**: Terminates after 30 minutes of low CPU usage
- **Maximum lifetime**: Hard limit of 60 minutes (2x idle timeout)
- **Manual termination**: Ctrl+C or stop command
- **Spot interruption**: Graceful handling of AWS spot interruptions

### Resource Cleanup
- **On exit**: All resources cleaned up when script exits
- **Error handling**: Cleanup on script failures or interruptions
- **Orphan detection**: `cleanup` command finds and removes orphaned resources
- **Multi-region scan**: Checks all AWS regions for orphaned resources

## Cost Considerations

- **Spot instances**: 60-90% cheaper than on-demand pricing
- **Small instances**: Default t3.nano (~$0.0052/hour spot price)
- **Auto-termination**: Prevents runaway costs
- **No persistent resources**: No ongoing charges when not in use

Typical cost: $0.01-0.05 per VPN session

## Troubleshooting

### Common Issues

1. **AWS CLI not configured**:
   ```bash
   aws configure
   # Or set AWS_PROFILE environment variable
   ```

2. **sshuttle not found**:
   ```bash
   brew install sshuttle  # macOS
   pip install sshuttle   # Other systems
   ```

3. **Permission denied**:
   - Check AWS IAM permissions
   - Ensure EC2, Security Group, and Key Pair permissions

4. **Instance launch failures**:
   - Try different instance type: `--instance-type t3.micro`
   - Try different region
   - Check AWS service health dashboard

5. **Tunnel connection issues**:
   - Check local firewall settings
   - Ensure no conflicting VPN software
   - Verify internet connectivity

### Debug Mode

Add debug output by modifying the script:
```bash
# Add at the top after set -euo pipefail
set -x  # Enable debug mode
```

### Manual Cleanup

If automatic cleanup fails:
```bash
# Find VPN tunnel resources by tag
aws ec2 describe-instances --filters "Name=tag:VpnTunnel,Values=OnDemand"
aws ec2 describe-security-groups --filters "Name=tag:VpnTunnel,Values=OnDemand"
aws ec2 describe-key-pairs --filters "Name=tag:VpnTunnel,Values=OnDemand"

# Force cleanup
./vpn-tunnel.sh cleanup
```

## Security Considerations

- **Temporary resources**: All AWS resources are temporary and tagged
- **SSH keys**: Generated fresh for each session, deleted after use
- **Security groups**: Minimal rules (SSH only), deleted after use
- **No persistence**: No long-lived infrastructure or credentials stored

## Files Created

- `~/.vpn-tunnel/`: State directory
  - `active.state`: Current session information
  - `sshuttle.pid`: Tunnel process ID
  - `vpn-tunnel-key-*.pem`: Temporary SSH keys (auto-deleted)

All files are automatically cleaned up when the tunnel stops.