#!/bin/bash

#############################################################################
# IBM Cloud Code Engine Deployment Script for OpenPages MCP Server
#############################################################################

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
RESOURCE_GROUP="itz-wxo-6a1d881878d3942e54cff3"
REGISTRY_NAMESPACE="cr-itz-cacwgp2x"
GITHUB_REPO="https://github.com/jpradier/ibm-openpages-mcp-server.git"
PROJECT_NAME="openpages-mcp"
APP_NAME="openpages-mcp-server"
REGION="us-south"  # Change to your preferred region: us-south, eu-de, etc.
REGISTRY_SERVER="us.icr.io"  # Change based on region: us.icr.io, de.icr.io, etc.

# Application configuration
APP_CPU="1"
APP_MEMORY="2G"
APP_MIN_SCALE="0"
APP_MAX_SCALE="5"
APP_PORT="8000"
APP_CONCURRENCY="100"

# Secret names
REGISTRY_SECRET="icr-secret"
GITHUB_SECRET="github-ssh-key"
OPENPAGES_SECRET="openpages-credentials"

# SSH key path
SSH_KEY_PATH="$HOME/.ssh/openpages_mcp_deploy_key"

#############################################################################
# Helper Functions
#############################################################################

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

check_command() {
    if ! command -v $1 &> /dev/null; then
        print_error "$1 is not installed. Please install it first."
        exit 1
    fi
}

#############################################################################
# Load Environment Variables
#############################################################################

print_header "Loading Environment Configuration"

if [ ! -f ".env" ]; then
    print_error ".env file not found. Please create it first from .env.example"
    echo ""
    echo "Example:"
    echo "  cp .env.example .env"
    echo "  # Edit .env with your OpenPages credentials and WXO_API_KEY"
    exit 1
fi

# Load .env file
set -a
source .env
set +a

# Check if WXO_API_KEY is set
if [ -z "$WXO_API_KEY" ]; then
    print_error "WXO_API_KEY not found in .env file"
    echo ""
    echo "Please add your IBM Cloud API key to .env:"
    echo "  WXO_API_KEY=your_ibm_cloud_api_key"
    exit 1
fi

print_success "Loaded environment variables from .env"
print_success "Found WXO_API_KEY for registry access"

#############################################################################
# Pre-flight Checks
#############################################################################

print_header "Pre-flight Checks"

# Check if IBM Cloud CLI is installed
check_command "ibmcloud"
print_success "IBM Cloud CLI is installed"

# Check if Code Engine plugin is installed
if ! ibmcloud plugin list | grep -q "code-engine"; then
    print_warning "Code Engine plugin not found. Installing..."
    ibmcloud plugin install code-engine -f
    print_success "Code Engine plugin installed"
else
    print_success "Code Engine plugin is installed"
fi

# Check if logged in
if ! ibmcloud target &> /dev/null; then
    print_error "Not logged in to IBM Cloud. Please run: ibmcloud login --sso"
    exit 1
fi
print_success "Logged in to IBM Cloud"

#############################################################################
# Target Resource Group and Region
#############################################################################

print_header "Targeting Resource Group and Region"

ibmcloud target -g "$RESOURCE_GROUP" -r "$REGION"
print_success "Targeted resource group: $RESOURCE_GROUP"
print_success "Targeted region: $REGION"

#############################################################################
# Create or Select Code Engine Project
#############################################################################

print_header "Setting up Code Engine Project"

# Check if project exists
if ibmcloud ce project get --name "$PROJECT_NAME" &> /dev/null; then
    print_info "Project '$PROJECT_NAME' already exists"
    ibmcloud ce project select --name "$PROJECT_NAME"
    print_success "Selected existing project: $PROJECT_NAME"
else
    print_info "Creating new project: $PROJECT_NAME"
    ibmcloud ce project create --name "$PROJECT_NAME"
    print_success "Created and selected project: $PROJECT_NAME"
fi

#############################################################################
# Create Registry Secret (if not exists)
#############################################################################

print_header "Setting up Container Registry Secret"

# Check if registry secret exists
if ibmcloud ce secret get --name "$REGISTRY_SECRET" &> /dev/null; then
    print_info "Registry secret '$REGISTRY_SECRET' already exists"
    read -p "Do you want to update it with WXO_API_KEY from .env? (y/N): " update_registry
    if [[ $update_registry =~ ^[Yy]$ ]]; then
        print_info "Updating registry secret with WXO_API_KEY..."
        ibmcloud ce secret update --name "$REGISTRY_SECRET" \
            --format registry \
            --server "$REGISTRY_SERVER" \
            --username iamapikey \
            --password "$WXO_API_KEY"
        print_success "Updated registry secret"
    fi
else
    print_info "Creating registry secret with WXO_API_KEY from .env..."
    ibmcloud ce secret create --name "$REGISTRY_SECRET" \
        --format registry \
        --server "$REGISTRY_SERVER" \
        --username iamapikey \
        --password "$WXO_API_KEY"
    print_success "Created registry secret"
fi

#############################################################################
# Setup GitHub SSH Key and Secret
#############################################################################

print_header "Setting up GitHub SSH Secret"

# Check if SSH key already exists
if [ -f "$SSH_KEY_PATH" ]; then
    print_success "SSH key already exists at $SSH_KEY_PATH"
else
    print_info "SSH key not found. Generating new SSH key..."
    ssh-keygen -t ed25519 -C "code-engine-deploy" -f "$SSH_KEY_PATH" -N ""
    print_success "Generated new SSH key at $SSH_KEY_PATH"
    echo ""
    print_warning "IMPORTANT: Add the following public key to GitHub:"
    echo ""
    cat "${SSH_KEY_PATH}.pub"
    echo ""
    echo "Go to: https://github.com/jpradier/ibm-openpages-local-mcp-server/settings/keys"
    echo "Click 'Add deploy key', paste the key above, and save."
    echo ""
    read -p "Press Enter after adding the key to GitHub..."
fi

# Check if GitHub secret exists
if ibmcloud ce secret get --name "$GITHUB_SECRET" &> /dev/null; then
    print_info "GitHub SSH secret '$GITHUB_SECRET' already exists"
    read -p "Do you want to update it? (y/N): " update_github
    if [[ $update_github =~ ^[Yy]$ ]]; then
        print_info "Updating GitHub SSH secret..."
        ibmcloud ce secret update --name "$GITHUB_SECRET" \
            --format ssh \
            --key-path "$SSH_KEY_PATH"
        print_success "Updated GitHub SSH secret"
    fi
else
    print_info "Creating GitHub SSH secret..."
    ibmcloud ce secret create --name "$GITHUB_SECRET" \
        --format ssh \
        --key-path "$SSH_KEY_PATH"
    print_success "Created GitHub SSH secret"
fi

#############################################################################
# Create OpenPages Credentials Secret (if not exists)
#############################################################################

print_header "Setting up OpenPages Credentials Secret"

# Check if OpenPages secret exists
if ibmcloud ce secret get --name "$OPENPAGES_SECRET" &> /dev/null; then
    print_info "OpenPages credentials secret '$OPENPAGES_SECRET' already exists"
    read -p "Do you want to update it from .env? (y/N): " update_secret
    if [[ $update_secret =~ ^[Yy]$ ]]; then
        print_info "Updating secret from .env file..."
        ibmcloud ce secret update --name "$OPENPAGES_SECRET" --from-env-file .env
        print_success "Updated OpenPages credentials secret"
    fi
else
    print_info "Creating secret from .env file..."
    ibmcloud ce secret create --name "$OPENPAGES_SECRET" --from-env-file .env
    print_success "Created OpenPages credentials secret"
fi

#############################################################################
# Create or Update Application
#############################################################################

print_header "Deploying Application"

# Check if application exists
if ibmcloud ce app get --name "$APP_NAME" &> /dev/null; then
    print_info "Application '$APP_NAME' already exists. Updating..."
    
    ibmcloud ce app update --name "$APP_NAME" \
        --build-source "$GITHUB_REPO" \
        --build-context-dir . \
        --build-dockerfile Dockerfile \
        --build-git-repo-secret "$GITHUB_SECRET" \
        --image "$REGISTRY_SERVER/$REGISTRY_NAMESPACE/$APP_NAME" \
        --registry-secret "$REGISTRY_SECRET" \
        --cpu "$APP_CPU" \
        --memory "$APP_MEMORY" \
        --min-scale "$APP_MIN_SCALE" \
        --max-scale "$APP_MAX_SCALE" \
        --port "$APP_PORT" \
        --concurrency "$APP_CONCURRENCY" \
        --env-from-secret "$OPENPAGES_SECRET" \
        --probe-live /health/live \
        --probe-ready /health/ready \
        --wait
    
    print_success "Application updated successfully"
else
    print_info "Creating new application: $APP_NAME"
    
    ibmcloud ce app create --name "$APP_NAME" \
        --build-source "$GITHUB_REPO" \
        --build-context-dir . \
        --build-dockerfile Dockerfile \
        --build-git-repo-secret "$GITHUB_SECRET" \
        --image "$REGISTRY_SERVER/$REGISTRY_NAMESPACE/$APP_NAME" \
        --registry-secret "$REGISTRY_SECRET" \
        --cpu "$APP_CPU" \
        --memory "$APP_MEMORY" \
        --min-scale "$APP_MIN_SCALE" \
        --max-scale "$APP_MAX_SCALE" \
        --port "$APP_PORT" \
        --concurrency "$APP_CONCURRENCY" \
        --env-from-secret "$OPENPAGES_SECRET" \
        --probe-live /health/live \
        --probe-ready /health/ready \
        --wait
    
    print_success "Application created successfully"
fi

#############################################################################
# Get Application URL and Test
#############################################################################

print_header "Deployment Complete"

# Get application URL
APP_URL=$(ibmcloud ce app get --name "$APP_NAME" --output url)

print_success "Application deployed successfully!"
echo ""
echo -e "${GREEN}Application URL:${NC} $APP_URL"
echo ""
echo "Testing health endpoint..."

# Wait a bit for the app to be ready
sleep 5

# Test health endpoint
if curl -f -s "$APP_URL/health" > /dev/null; then
    print_success "Health check passed!"
    echo ""
    echo "Full health response:"
    curl -s "$APP_URL/health" | jq '.' 2>/dev/null || curl -s "$APP_URL/health"
else
    print_warning "Health check failed. The application might still be starting up."
    echo "Check logs with: ibmcloud ce app logs --name $APP_NAME"
fi

echo ""
echo -e "${BLUE}Useful commands:${NC}"
echo "  View logs:        ibmcloud ce app logs --name $APP_NAME --follow"
echo "  Get app details:  ibmcloud ce app get --name $APP_NAME"
echo "  Update app:       ./deploy-to-code-engine.sh"
echo "  Delete app:       ibmcloud ce app delete --name $APP_NAME"
echo ""
echo -e "${BLUE}SSH Key Location:${NC}"
echo "  Private key: $SSH_KEY_PATH"
echo "  Public key:  ${SSH_KEY_PATH}.pub"
echo ""
print_success "Deployment script completed!"

# Made with Bob
