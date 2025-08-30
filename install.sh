#!/bin/bash

set -euo pipefail

# VPN Tunnel Installation Script
# Installs vpn-tunnel to system PATH and verifies dependencies

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALL_DIR="/usr/local/bin"
readonly SCRIPT_NAME="vpn-tunnel"

echo "🚀 Installing VPN Tunnel..."

# Check if running as root for installation
if [[ ! -w "$INSTALL_DIR" ]]; then
    echo "❌ Cannot write to $INSTALL_DIR"
    echo "Please run with sudo:"
    echo "  sudo ./install.sh"
    exit 1
fi

# Check dependencies
echo "🔍 Checking dependencies..."

# Check AWS CLI
if ! command -v aws >/dev/null 2>&1; then
    echo "❌ AWS CLI not found"
    echo "Please install AWS CLI:"
    echo "  https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

# Check AWS configuration
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "⚠️  AWS CLI not configured"
    echo "Please configure AWS CLI:"
    echo "  aws configure"
    echo ""
    echo "Installation will continue, but you'll need to configure AWS before using vpn-tunnel."
fi

# Check sshuttle
if ! command -v sshuttle >/dev/null 2>&1; then
    echo "❌ sshuttle not found"
    echo "Please install sshuttle:"
    echo ""
    echo "macOS:"
    echo "  brew install sshuttle"
    echo ""
    echo "Ubuntu/Debian:"
    echo "  sudo apt-get install sshuttle"
    echo ""
    echo "Other systems:"
    echo "  pip install sshuttle"
    exit 1
fi

# Create symlink
echo "📂 Installing to system PATH..."

# Remove existing installation if present
rm -f "$INSTALL_DIR/$SCRIPT_NAME"

# Create symlink
ln -s "$SCRIPT_DIR/vpn-tunnel.sh" "$INSTALL_DIR/$SCRIPT_NAME"

# Verify installation
if [[ -x "$INSTALL_DIR/$SCRIPT_NAME" ]]; then
    echo "✅ Installation successful!"
    echo ""
    echo "vpn-tunnel is now available in your PATH."
    echo ""
    echo "Usage:"
    echo "  vpn-tunnel start --region EU"
    echo "  vpn-tunnel status"
    echo "  vpn-tunnel stop"
    echo "  vpn-tunnel --help"
    echo ""
    echo "🔒 Your first VPN tunnel is just one command away!"
else
    echo "❌ Installation failed"
    echo "Symlink creation unsuccessful"
    exit 1
fi

# Test basic functionality
echo "🧪 Testing installation..."
if "$INSTALL_DIR/$SCRIPT_NAME" --help >/dev/null 2>&1; then
    echo "✅ Installation test passed"
else
    echo "❌ Installation test failed"
    exit 1
fi

echo ""
echo "🎉 Installation complete!"
echo ""
echo "Next steps:"
echo "1. Ensure AWS CLI is configured: aws configure"
echo "2. Launch your first VPN: vpn-tunnel start --region EU"
echo "3. When done: vpn-tunnel stop"
echo ""
echo "For support and documentation:"
echo "  https://github.com/apantanowitz/vpn-tunnel"