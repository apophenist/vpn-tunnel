#!/bin/bash

# Simple test script for vpn-tunnel.sh
# This script tests basic functionality without actually launching instances

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPN_SCRIPT="$SCRIPT_DIR/vpn-tunnel.sh"

echo "=== VPN Tunnel Test Script ==="
echo

# Test 1: Help output
echo "1. Testing help output..."
if "$VPN_SCRIPT" --help >/dev/null; then
    echo "   ✓ Help output works"
else
    echo "   ✗ Help output failed"
    exit 1
fi

# Test 2: Status with no active tunnel
echo "2. Testing status with no active tunnel..."
output=$("$VPN_SCRIPT" status)
if [[ "$output" == "No active VPN tunnel." ]]; then
    echo "   ✓ Status correctly shows no active tunnel"
else
    echo "   ✗ Status output unexpected: $output"
    exit 1
fi

# Test 3: Region mapping (extract functions and test them)
echo "3. Testing region mapping..."
source "$VPN_SCRIPT"

# Test region alias mapping
test_regions=("EU" "US" "ASIA" "us-west-2" "eu-central-1")
expected=("eu-west-1" "us-east-1" "ap-southeast-1" "us-west-2" "eu-central-1")

for i in "${!test_regions[@]}"; do
    input="${test_regions[$i]}"
    expected_output="${expected[$i]}"
    actual_output=$(map_region_alias "$input")
    
    if [[ "$actual_output" == "$expected_output" ]]; then
        echo "   ✓ Region mapping: $input -> $actual_output"
    else
        echo "   ✗ Region mapping failed: $input -> $actual_output (expected: $expected_output)"
        exit 1
    fi
done

# Test 4: Dependency check
echo "4. Testing dependency checks..."
if check_dependencies 2>/dev/null; then
    echo "   ✓ Dependencies check passed"
else
    echo "   ✗ Dependencies missing (AWS CLI or sshuttle not found/configured)"
    echo "     This is expected if you haven't configured AWS CLI or installed sshuttle"
fi

# Test 5: Validate script syntax
echo "5. Testing script syntax..."
if bash -n "$VPN_SCRIPT"; then
    echo "   ✓ Script syntax is valid"
else
    echo "   ✗ Script has syntax errors"
    exit 1
fi

echo
echo "=== Basic tests completed successfully ==="
echo
echo "NOTE: To fully test this script, you would need:"
echo "1. AWS CLI configured with valid credentials"
echo "2. sshuttle installed"
echo "3. Permissions to create EC2 instances, security groups, and key pairs"
echo
echo "Usage example:"
echo "  $VPN_SCRIPT start --region EU"
echo "  # Wait for tunnel to establish, then press Ctrl+C to stop"