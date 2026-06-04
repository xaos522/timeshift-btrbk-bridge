#!/usr/bin/env bash
#
# install-dependencies.sh - Install dependencies for timeshift-btrbk-bridge
#
# This script downloads and installs required bash libraries and utilities
# for the timeshift-btrbk-bridge tool.
#
# Usage: sudo ./install-dependencies.sh
#

set -euo pipefail

# Configuration
BASH_LOGGER_REPO="https://github.com/xaos522/bash-logger.git"
BASH_LOGGER_VERSION="main"  # or specify a specific tag/commit
INSTALL_DIR="/usr/local/lib/bash-logger"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Check for root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        echo "Usage: sudo $0"
        exit 1
    fi
}

# Check for required commands
check_requirements() {
    local required_commands=("git" "bash")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done
    
    log_success "All required commands available"
}

# Install bash-logger
install_bash_logger() {
    log_info "Installing bash-logger from $BASH_LOGGER_REPO"
    
    # Create installation directory if it doesn't exist
    if [[ ! -d "$INSTALL_DIR" ]]; then
        log_info "Creating installation directory: $INSTALL_DIR"
        mkdir -p "$INSTALL_DIR"
    fi
    
    # Check if bash-logger is already installed
    if [[ -f "$INSTALL_DIR/logging.sh" ]]; then
        log_warning "bash-logger already installed at $INSTALL_DIR"
        read -p "Do you want to update it? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$INSTALL_DIR"
            mkdir -p "$INSTALL_DIR"
        else
            log_info "Skipping bash-logger installation"
            return 0
        fi
    fi
    
    # Clone the repository
    log_info "Cloning bash-logger repository..."
    if git clone --depth 1 --branch "$BASH_LOGGER_VERSION" "$BASH_LOGGER_REPO" "$INSTALL_DIR"; then
        log_success "bash-logger cloned successfully"
    else
        log_error "Failed to clone bash-logger repository"
        exit 1
    fi
    
    # Verify the logging.sh file exists
    if [[ ! -f "$INSTALL_DIR/logging.sh" ]]; then
        log_error "logging.sh not found in $INSTALL_DIR"
        exit 1
    fi
    
    # Set proper permissions
    chmod 644 "$INSTALL_DIR/logging.sh"
    log_success "bash-logger installed to $INSTALL_DIR"
}

# Verify installation
verify_installation() {
    log_info "Verifying bash-logger installation..."
    
    if [[ ! -f "$INSTALL_DIR/logging.sh" ]]; then
        log_error "bash-logger verification failed: logging.sh not found"
        exit 1
    fi
    
    # Test that the logging.sh file can be sourced
    if bash -c "source '$INSTALL_DIR/logging.sh' 2>/dev/null && echo 'OK'" | grep -q "OK"; then
        log_success "bash-logger installation verified"
    else
        log_error "bash-logger verification failed: cannot source logging.sh"
        exit 1
    fi
}

# Create symlink or copy to standard locations
create_symlink() {
    local symlink_dir="/usr/local/lib"
    local symlink_name="bash-logger"
    
    if [[ -L "$symlink_dir/$symlink_name" ]]; then
        log_info "Symlink already exists at $symlink_dir/$symlink_name"
    else
        log_info "Creating symlink: $symlink_dir/$symlink_name -> $INSTALL_DIR"
        ln -s "$INSTALL_DIR" "$symlink_dir/$symlink_name" 2>/dev/null || log_warning "Could not create symlink (may already exist or require different permissions)"
    fi
}

# Print installation summary
print_summary() {
    cat << EOF

${GREEN}========================================${NC}
${GREEN}Installation Complete!${NC}
${GREEN}========================================${NC}

bash-logger has been installed to:
  ${BLUE}$INSTALL_DIR${NC}

To use bash-logger in your scripts:
  ${BLUE}source /usr/local/lib/bash-logger/logging.sh${NC}

Quick Start Example:
  ${BLUE}#!/usr/bin/env bash${NC}
  ${BLUE}source /usr/local/lib/bash-logger/logging.sh${NC}
  ${BLUE}init_logger -l info${NC}
  ${BLUE}log_info "Hello, World!"${NC}

For more information, visit:
  https://github.com/xaos522/bash-logger

${GREEN}========================================${NC}
EOF
}

# Main installation flow
main() {
    echo
    log_info "timeshift-btrbk-bridge Dependency Installer"
    echo
    
    check_root
    check_requirements
    install_bash_logger
    verify_installation
    create_symlink
    print_summary
}

# Run main function
main "$@"
