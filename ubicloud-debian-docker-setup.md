# Ubicloud Setup Guide for Debian (Docker-based)

## Overview

This guide provides step-by-step instructions for setting up Ubicloud on a Debian headless machine using Docker. This is the fastest and simplest way to get Ubicloud running.

**What is Ubicloud?**

Ubicloud is an open-source cloud platform (Infrastructure as a Service) that provides cloud features on bare metal providers like Hetzner, Leaseweb, and AWS Bare Metal. Think of it as an open alternative to AWS/Azure/GCP.

**What you'll get:**
- Control plane web console (accessible via browser)
- REST API for programmatic access
- Background job processor for managing resources
- PostgreSQL database
- Ability to cloudify bare metal servers and provision VMs

---

## Prerequisites

### System Requirements

**Minimum Hardware:**
- 2 CPU cores
- 4 GB RAM
- 20 GB disk space
- Network connectivity

**Operating System:**
- Debian 11 or 12 (recommended)
- Ubuntu 20.04, 22.04, or 24.04 also supported

**Required Software:**
- Docker Engine
- Docker Compose
- Git
- Basic command-line tools (curl, bash)

---

## Installation Steps

### Step 1: Update Your System

```bash
# Update package index and upgrade existing packages
sudo apt-get update && sudo apt-get upgrade -y

# Install basic utilities
sudo apt-get install -y curl git
```

### Step 2: Install Docker

```bash
# Download and run Docker installation script
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Add your user to the docker group (to run docker without sudo)
sudo usermod -aG docker $USER

# IMPORTANT: Log out and log back in for group changes to take effect
# Or run: newgrp docker
```

**Verify Docker Installation:**

```bash
# Check Docker version
docker --version
# Expected output: Docker version 24.x.x or newer

# Test Docker
docker run hello-world
# Should download and run a test container
```

### Step 3: Install Docker Compose (if not included)

Docker Compose usually comes with Docker Desktop, but on servers you may need to install it separately:

```bash
# Check if docker-compose is already available
docker-compose --version

# If not installed, install it:
sudo apt-get install -y docker-compose-plugin

# Or install standalone version:
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Verify installation
docker-compose --version
```

### Step 4: Clone the Ubicloud Repository

```bash
# Navigate to your preferred directory
cd ~

# Clone the repository
git clone https://github.com/ubicloud/ubicloud.git

# Enter the directory
cd ubicloud
```

### Step 5: Generate Environment Configuration

The repository includes a script to generate secure random secrets:

```bash
# Generate .env file with random secrets
./demo/generate_env

# Verify the file was created
cat demo/.env
```

**What this creates:**

The `.env` file contains:
- `RACK_ENV=development` - Environment mode
- `POSTGRES_DB=clover` - Database name
- `POSTGRES_PASSWORD` - Random PostgreSQL password
- `CLOVER_DATABASE_URL` - Database connection string
- `CLOVER_SESSION_SECRET` - Random session encryption key
- `CLOVER_COLUMN_ENCRYPTION_KEY` - Random column encryption key

### Step 6: Start Ubicloud Services

```bash
# Build and start all services in detached mode
docker-compose -f demo/docker-compose.yml up -d

# This will start three services:
# 1. ubicloud-postgres - PostgreSQL 15.8 database
# 2. ubicloud-db-migrator - Runs database migrations
# 3. ubicloud-app - Web server and background workers
```

**Monitor the startup:**

```bash
# View logs from all services
docker-compose -f demo/docker-compose.yml logs -f

# View logs from specific service
docker-compose -f demo/docker-compose.yml logs -f app

# Check service status
docker-compose -f demo/docker-compose.yml ps
```

### Step 7: Verify Services Are Running

```bash
# Check running containers
docker ps

# You should see three containers:
# - ubicloud-postgres (port 5432)
# - ubicloud-db-migrator (completed)
# - ubicloud-app (port 3000)

# Test web server
curl http://localhost:3000

# Should return HTML content from the Ubicloud web console
```

### Step 8: Access the Web Console

**Option A: Direct Access (if you have GUI access)**

Open a web browser and visit:
```
http://localhost:3000
```

**Option B: SSH Tunnel (for headless servers)**

From your local machine, create an SSH tunnel:

```bash
# Replace 'user' and 'server-ip' with your actual values
ssh -L 3000:localhost:3000 user@your-server-ip
```

Then open your browser to:
```
http://localhost:3000
```

**Option C: Configure Firewall and Access Remotely**

```bash
# Allow port 3000 through firewall (use with caution)
sudo ufw allow 3000/tcp

# Access via server IP
# http://your-server-ip:3000
```

### Step 9: Create Your First Account

1. Visit the web console URL
2. Click "Sign Up" to create an account
3. Fill in your details (email, password)
4. **Important**: Without SMTP configured, check the Docker logs for the verification link:

```bash
docker-compose -f demo/docker-compose.yml logs app | grep verify
```

5. Copy the verification URL and visit it in your browser
6. Log in with your credentials

---

## Service Architecture

### Running Services

**PostgreSQL Container (`ubicloud-postgres`):**
- Database: `clover`
- Port: 5432
- Data persistence via Docker volume
- Health checks every 5 seconds

**Application Container (`ubicloud-app`):**
- Web server (Puma) on port 3000
- Background job processor (`respirate`)
- Health monitor service
- Managed by Foreman (reads from Procfile)

### Processes Inside App Container

The app container runs three processes via Foreman:

1. **web**: Puma web server for HTTP requests
2. **respirate**: Background job scheduler for VM management, networking, etc.
3. **monitor**: Health monitoring service

---

## Managing Your Installation

### Starting and Stopping Services

```bash
# Stop all services
docker-compose -f demo/docker-compose.yml down

# Stop and remove volumes (WARNING: deletes all data)
docker-compose -f demo/docker-compose.yml down -v

# Start services
docker-compose -f demo/docker-compose.yml up -d

# Restart services
docker-compose -f demo/docker-compose.yml restart

# Restart specific service
docker-compose -f demo/docker-compose.yml restart app
```

### Viewing Logs

```bash
# All services
docker-compose -f demo/docker-compose.yml logs -f

# Specific service
docker-compose -f demo/docker-compose.yml logs -f app
docker-compose -f demo/docker-compose.yml logs -f postgres

# Last 100 lines
docker-compose -f demo/docker-compose.yml logs --tail=100
```

### Accessing Container Shell

```bash
# Execute bash in app container
docker exec -it ubicloud-app /bin/sh

# Access PostgreSQL
docker exec -it ubicloud-postgres psql -U postgres -d clover

# Run Rails console
docker exec -it ubicloud-app ./bin/pry
```

### Updating Ubicloud

```bash
# Navigate to repository
cd ~/ubicloud

# Pull latest changes
git pull origin main

# Rebuild and restart containers
docker-compose -f demo/docker-compose.yml down
docker-compose -f demo/docker-compose.yml up -d --build
```

---

## Optional: Cloudifying Bare Metal Servers

To actually provision VMs, you need to cloudify bare metal servers from providers like Hetzner.

### Prerequisites for Cloudification

1. **Bare metal server** from Hetzner/Leaseweb/AWS
2. **Ubuntu 24.04 LTS** installed
3. **Additional subnet** (/29) ordered from provider
4. **SSH access** to the server
5. **Hetzner credentials** (if using Hetzner)

### Configuration Steps

#### 1. Update Environment Configuration

Edit `demo/.env` and add:

```bash
# Hetzner Account Credentials
HETZNER_USER=your_hetzner_account_id
HETZNER_PASSWORD=your_hetzner_password

# SSH Keys (public key as single line, private key with \n for newlines)
HETZNER_SSH_PUBLIC_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAA..."
HETZNER_SSH_PRIVATE_KEY="-----BEGIN OPENSSH PRIVATE KEY-----\nbase64content\n-----END OPENSSH PRIVATE KEY-----"

# Operator SSH keys for accessing VMs
OPERATOR_SSH_PUBLIC_KEYS="ssh-rsa AAAAB3NzaC1yc2EAAAA..."
```

**Note**: For `HETZNER_SSH_PRIVATE_KEY`, replace actual newlines with `\n`.

#### 2. Restart Services with New Configuration

```bash
docker-compose -f demo/docker-compose.yml restart app
```

#### 3. Run Cloudification Script

```bash
# Execute the cloudify script inside the container
docker exec -it ubicloud-app ./demo/cloudify_server

# You will be prompted to enter:
# - Hostname/IP of your bare metal server
# - Provider name (e.g., "hetzner")
```

The script will:
1. Connect to your bare metal server
2. Install required software (Cloud Hypervisor, networking tools)
3. Configure networking (IPsec tunnels, nftables)
4. Download boot images (Ubuntu, Debian, AlmaLinux)
5. Register the host in Ubicloud's control plane

#### 4. Monitor Cloudification Progress

```bash
# Watch the logs
docker-compose -f demo/docker-compose.yml logs -f app

# When you see "VmHost cloudification complete", the server is ready
```

### Creating Your First VM

Once cloudified, you can create VMs via:

1. **Web Console**: Navigate to "Virtual Machines" → "Create"
2. **API**: Use the REST API endpoints
3. **CLI**: Use `bin/ubi` command-line tool

---

## Advanced Configuration

### Email (SMTP) Setup

To enable email verification and notifications, add to `demo/.env`:

```bash
SMTP_HOSTNAME=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=your-email@gmail.com
SMTP_PASSWORD=your-app-password
SMTP_FROM=noreply@yourdomain.com
```

Then restart:
```bash
docker-compose -f demo/docker-compose.yml restart app
```

### GitHub OAuth Setup

For team access via GitHub:

1. Create OAuth App at https://github.com/settings/developers
2. Set callback URL: `http://your-domain:3000/auth/github/callback`
3. Add to `demo/.env`:

```bash
OMNIAUTH_GITHUB_KEY=your_oauth_app_id
OMNIAUTH_GITHUB_SECRET=your_oauth_app_secret
```

### Google OAuth Setup

1. Create OAuth credentials in Google Cloud Console
2. Add to `demo/.env`:

```bash
OMNIAUTH_GOOGLE_KEY=your_google_client_id.apps.googleusercontent.com
OMNIAUTH_GOOGLE_SECRET=your_google_client_secret
```

### Stripe Payment Integration

For billing and payments:

```bash
STRIPE_SECRET_KEY=sk_test_your_stripe_secret_key
```

### Cloudflare Turnstile (CAPTCHA)

```bash
CLOUDFLARE_TURNSTILE_SECRET_KEY=your_secret_key
CLOUDFLARE_TURNSTILE_SITE_KEY=your_site_key
```

---

## Production Deployment

### Using Nginx Reverse Proxy

For production, use Nginx with SSL:

#### 1. Install Nginx

```bash
sudo apt-get install -y nginx certbot python3-certbot-nginx
```

#### 2. Configure Nginx

Create `/etc/nginx/sites-available/ubicloud`:

```nginx
server {
    listen 80;
    server_name your-domain.com;

    # Redirect HTTP to HTTPS
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name your-domain.com;

    # SSL certificates (will be configured by certbot)
    ssl_certificate /etc/letsencrypt/live/your-domain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/your-domain.com/privkey.pem;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;

    # Proxy to Ubicloud
    location / {
        proxy_pass http://localhost:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # Increase timeouts for long-running requests
    proxy_connect_timeout 600;
    proxy_send_timeout 600;
    proxy_read_timeout 600;
    send_timeout 600;
}
```

#### 3. Enable Site and Get SSL Certificate

```bash
# Enable site
sudo ln -s /etc/nginx/sites-available/ubicloud /etc/nginx/sites-enabled/

# Test configuration
sudo nginx -t

# Reload Nginx
sudo systemctl reload nginx

# Get SSL certificate
sudo certbot --nginx -d your-domain.com

# Enable auto-renewal
sudo systemctl enable certbot.timer
```

### Automatic Startup on Boot

Create systemd service at `/etc/systemd/system/ubicloud.service`:

```ini
[Unit]
Description=Ubicloud Docker Compose Service
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/home/your-user/ubicloud
ExecStart=/usr/bin/docker-compose -f demo/docker-compose.yml up -d
ExecStop=/usr/bin/docker-compose -f demo/docker-compose.yml down
User=your-user

[Install]
WantedBy=multi-user.target
```

Enable the service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable ubicloud
sudo systemctl start ubicloud
```

### Backup Strategy

#### Backup Database

```bash
# Create backup directory
mkdir -p ~/ubicloud-backups

# Backup database
docker exec ubicloud-postgres pg_dump -U postgres clover > ~/ubicloud-backups/clover-$(date +%Y%m%d-%H%M%S).sql

# Compress backup
gzip ~/ubicloud-backups/clover-*.sql
```

#### Automated Backup Script

Create `/usr/local/bin/backup-ubicloud.sh`:

```bash
#!/bin/bash
BACKUP_DIR="/home/your-user/ubicloud-backups"
RETENTION_DAYS=30

mkdir -p "$BACKUP_DIR"

# Backup database
docker exec ubicloud-postgres pg_dump -U postgres clover | gzip > "$BACKUP_DIR/clover-$(date +%Y%m%d-%H%M%S).sql.gz"

# Backup .env file
cp /home/your-user/ubicloud/demo/.env "$BACKUP_DIR/.env-$(date +%Y%m%d-%H%M%S)"

# Remove old backups
find "$BACKUP_DIR" -name "clover-*.sql.gz" -mtime +$RETENTION_DAYS -delete

echo "Backup completed: $(date)"
```

Make executable and add to crontab:

```bash
chmod +x /usr/local/bin/backup-ubicloud.sh

# Run daily at 2 AM
(crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/backup-ubicloud.sh >> /var/log/ubicloud-backup.log 2>&1") | crontab -
```

#### Restore from Backup

```bash
# Stop application
docker-compose -f demo/docker-compose.yml stop app

# Restore database
gunzip -c ~/ubicloud-backups/clover-YYYYMMDD-HHMMSS.sql.gz | docker exec -i ubicloud-postgres psql -U postgres -d clover

# Restart application
docker-compose -f demo/docker-compose.yml start app
```

---

## Monitoring and Maintenance

### Health Checks

```bash
# Check if services are healthy
docker-compose -f demo/docker-compose.yml ps

# Check web server
curl -f http://localhost:3000/health || echo "Service unhealthy"

# Check database connection
docker exec ubicloud-postgres pg_isready -U postgres
```

### View Resource Usage

```bash
# Container resource usage
docker stats

# Disk usage
docker system df

# Volume usage
docker volume ls
```

### Cleaning Up

```bash
# Remove unused images
docker image prune -a

# Remove unused volumes (WARNING: can delete data)
docker volume prune

# Complete cleanup
docker system prune -a --volumes
```

---

## Troubleshooting

### Common Issues and Solutions

#### Port 3000 Already in Use

```bash
# Find process using port 3000
sudo lsof -i :3000

# Kill the process
sudo kill -9 <PID>

# Or change the port in docker-compose.yml
# Change "3000:3000" to "8080:3000"
```

#### Database Connection Errors

```bash
# Check if PostgreSQL is running
docker-compose -f demo/docker-compose.yml ps postgres

# View PostgreSQL logs
docker-compose -f demo/docker-compose.yml logs postgres

# Restart PostgreSQL
docker-compose -f demo/docker-compose.yml restart postgres

# Check database connectivity
docker exec -it ubicloud-postgres psql -U postgres -d clover -c "SELECT version();"
```

#### Container Won't Start

```bash
# View detailed logs
docker-compose -f demo/docker-compose.yml logs --tail=100 app

# Remove and recreate containers
docker-compose -f demo/docker-compose.yml down
docker-compose -f demo/docker-compose.yml up -d

# Rebuild from scratch
docker-compose -f demo/docker-compose.yml down -v
docker-compose -f demo/docker-compose.yml build --no-cache
docker-compose -f demo/docker-compose.yml up -d
```

#### Out of Disk Space

```bash
# Check disk usage
df -h

# Clean up Docker resources
docker system prune -a --volumes

# Remove old logs
docker-compose -f demo/docker-compose.yml logs --tail=0
```

#### Can't Access Web Console

```bash
# Verify app is running
docker ps | grep ubicloud-app

# Check if port is listening
sudo netstat -tlnp | grep 3000

# Check firewall
sudo ufw status

# Test locally
curl -v http://localhost:3000

# Check nginx if using reverse proxy
sudo nginx -t
sudo systemctl status nginx
```

#### IPv6 Connectivity Issues

If you can't connect to VMs (they use IPv6 by default):

**Option 1**: Use VPN with IPv6 support (Mullvad, etc.)

**Option 2**: Use tunnel broker
```bash
# Hurricane Electric's tunnelbroker.net
# Follow their setup instructions
```

**Option 3**: Add IPv4 addresses from your provider

---

## Security Considerations

### Essential Security Practices

1. **Change Default Secrets**: Never use the demo-generated secrets in production
2. **Use HTTPS**: Always use SSL/TLS in production (via Nginx)
3. **Firewall Configuration**: Only expose necessary ports
4. **Regular Updates**: Keep Docker and Ubicloud updated
5. **Backup Encryption**: Encrypt backups, especially `.env` files
6. **SSH Key Management**: Use strong SSH keys, rotate regularly
7. **Database Access**: Don't expose PostgreSQL port publicly

### Recommended Firewall Rules

```bash
# Install UFW
sudo apt-get install -y ufw

# Default policies
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow SSH (change 22 if using custom port)
sudo ufw allow 22/tcp

# Allow HTTP/HTTPS (if using Nginx)
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Don't expose port 3000 or 5432 publicly if using Nginx
# Only allow from localhost or specific IPs

# Enable firewall
sudo ufw enable
```

### Updating Secrets

To regenerate secrets:

```bash
# Backup current .env
cp demo/.env demo/.env.backup

# Remove old .env
rm demo/.env

# Generate new secrets
./demo/generate_env

# Manually copy any custom configuration from backup
# (HETZNER_*, SMTP_*, etc.)

# Restart services
docker-compose -f demo/docker-compose.yml restart
```

---

## Performance Tuning

### Increase PostgreSQL Performance

Edit `demo/docker-compose.yml` and add under postgres service:

```yaml
postgres:
  # ... existing config ...
  command: >
    postgres
    -c shared_buffers=256MB
    -c max_connections=200
    -c effective_cache_size=1GB
    -c maintenance_work_mem=64MB
    -c random_page_cost=1.1
```

### Increase Application Workers

Edit Procfile in the repository and increase Puma workers:

```
web: bundle exec puma -C puma_config.rb -w 4
```

Then rebuild:
```bash
docker-compose -f demo/docker-compose.yml up -d --build
```

---

## Useful Commands Reference

### Docker Compose Commands

```bash
# Start services
docker-compose -f demo/docker-compose.yml up -d

# Stop services
docker-compose -f demo/docker-compose.yml down

# View logs
docker-compose -f demo/docker-compose.yml logs -f

# Restart service
docker-compose -f demo/docker-compose.yml restart app

# Rebuild and restart
docker-compose -f demo/docker-compose.yml up -d --build

# Check status
docker-compose -f demo/docker-compose.yml ps
```

### Docker Container Commands

```bash
# List running containers
docker ps

# Execute command in container
docker exec -it ubicloud-app /bin/sh

# View container logs
docker logs -f ubicloud-app

# Inspect container
docker inspect ubicloud-app

# Container resource usage
docker stats ubicloud-app
```

### Database Commands

```bash
# Access PostgreSQL CLI
docker exec -it ubicloud-postgres psql -U postgres -d clover

# Run SQL query
docker exec -it ubicloud-postgres psql -U postgres -d clover -c "SELECT COUNT(*) FROM accounts;"

# Backup database
docker exec ubicloud-postgres pg_dump -U postgres clover > backup.sql

# Restore database
cat backup.sql | docker exec -i ubicloud-postgres psql -U postgres -d clover
```

---

## Getting Help

### Resources

- **Documentation**: https://www.ubicloud.com/docs
- **Community Forum**: https://github.com/ubicloud/ubicloud/discussions
- **Issue Tracker**: https://github.com/ubicloud/ubicloud/issues
- **Official Website**: https://www.ubicloud.com
- **Blog**: https://www.ubicloud.com/blog

### Reporting Issues

When reporting issues, include:

1. System information (`uname -a`)
2. Docker version (`docker --version`)
3. Container logs (`docker-compose logs`)
4. Steps to reproduce
5. Expected vs actual behavior

### Contributing

Ubicloud is open source! Contributions welcome:

```bash
# Fork the repository on GitHub
# Clone your fork
git clone https://github.com/YOUR_USERNAME/ubicloud.git

# Create a branch
git checkout -b my-feature

# Make changes and test
docker-compose -f demo/docker-compose.yml up -d --build

# Commit and push
git commit -m "Add my feature"
git push origin my-feature

# Create Pull Request on GitHub
```

---

## Next Steps

After successful installation:

1. **Explore the Web Console**: Familiarize yourself with the UI
2. **Read the Documentation**: Understand VM management, networking, storage
3. **Set Up Monitoring**: Configure VictoriaMetrics for metrics
4. **Configure Integrations**: Enable OAuth, SMTP, Stripe as needed
5. **Cloudify Servers**: Add bare metal hosts to provision VMs
6. **Create Your First VM**: Test the platform with a simple VM
7. **Set Up Networking**: Configure VPCs, subnets, firewalls
8. **Explore API**: Try the REST API endpoints
9. **Join the Community**: Participate in discussions and forums

---

## Appendix: Full Example Setup Script

Save this as `setup-ubicloud.sh` for automated installation:

```bash
#!/bin/bash
set -e

echo "=== Ubicloud Docker Setup Script ==="

# Check if running on Debian/Ubuntu
if [ ! -f /etc/debian_version ]; then
    echo "This script is designed for Debian/Ubuntu"
    exit 1
fi

# Update system
echo "Updating system..."
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y curl git

# Install Docker
echo "Installing Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo usermod -aG docker $USER
    rm get-docker.sh
    echo "Docker installed. Please log out and back in, then run this script again."
    exit 0
fi

# Install Docker Compose
echo "Installing Docker Compose..."
if ! command -v docker-compose &> /dev/null; then
    sudo apt-get install -y docker-compose-plugin
fi

# Clone repository
echo "Cloning Ubicloud repository..."
cd ~
if [ -d "ubicloud" ]; then
    echo "Directory 'ubicloud' already exists. Updating..."
    cd ubicloud
    git pull
else
    git clone https://github.com/ubicloud/ubicloud.git
    cd ubicloud
fi

# Generate environment
echo "Generating environment configuration..."
if [ -f "demo/.env" ]; then
    echo "Environment file already exists. Skipping generation."
else
    ./demo/generate_env
fi

# Start services
echo "Starting Ubicloud services..."
docker-compose -f demo/docker-compose.yml up -d

# Wait for services to start
echo "Waiting for services to start..."
sleep 10

# Check status
echo "Checking service status..."
docker-compose -f demo/docker-compose.yml ps

echo ""
echo "=== Setup Complete! ==="
echo ""
echo "Ubicloud is now running!"
echo "Access the web console at: http://localhost:3000"
echo ""
echo "For remote access, create an SSH tunnel:"
echo "  ssh -L 3000:localhost:3000 $USER@$(hostname -I | awk '{print $1}')"
echo ""
echo "View logs:"
echo "  docker-compose -f demo/docker-compose.yml logs -f"
echo ""
echo "Stop services:"
echo "  docker-compose -f demo/docker-compose.yml down"
echo ""
```

Make it executable and run:

```bash
chmod +x setup-ubicloud.sh
./setup-ubicloud.sh
```

---

**Document Version**: 1.0
**Last Updated**: 2025-10-24
**Ubicloud Version**: Latest (main branch)
**Tested On**: Debian 12, Ubuntu 22.04

---

For questions or issues with this guide, please visit the [Community Forum](https://github.com/ubicloud/ubicloud/discussions).
