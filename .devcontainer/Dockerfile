FROM ubuntu:24.04

ARG RUBY_VERSION=3.4.9
ARG NODE_VERSION=24.12.0
ARG DEBIAN_FRONTEND=noninteractive
ARG WORKSPACE_FOLDER_NAME=ubicloud

# Install system dependencies
RUN apt-get update --fix-missing && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    gnupg \
    libffi-dev \
    libgmp-dev \
    libpq-dev \
    libreadline-dev \
    libssl-dev \
    libxml2-dev \
    libxslt1-dev \
    libyaml-dev \
    libz-dev \
    openssh-client \
    postgresql-client \
    psmisc \
    sudo \
    tzdata \
    wget \
    nano \
    unzip \
    vim \
    gh \
    jq \
    neovim \
    logrotate \
    cron \
    python3 \
    python3-pip \
    iproute2 \
    iputils-ping \
    net-tools \
    dnsutils \
    traceroute \
    nmap \
    tcpdump \
    netcat-openbsd \
    lsof \
    && rm -rf /var/lib/apt/lists/*

# Install AWS CLI (arch-aware)
RUN ARCH=$(uname -m) && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/awscliv2.zip

# Create non-root vscode user
RUN useradd -m -s /bin/bash vscode \
    && echo "vscode ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER vscode
WORKDIR /home/vscode

# Install mise, Ruby, Node.js, bundler, and foreman in a single layer
# to avoid devcontainer builder stage injection breaking layer ordering
RUN curl https://mise.run | sh \
    && echo 'eval "$(/home/vscode/.local/bin/mise activate bash)"' >> /home/vscode/.bashrc \
    && /home/vscode/.local/bin/mise install ruby@${RUBY_VERSION} node@${NODE_VERSION} \
    && /home/vscode/.local/bin/mise use --global ruby@${RUBY_VERSION} node@${NODE_VERSION}

ENV PATH="/home/vscode/.local/bin:/home/vscode/.local/share/mise/installs/ruby/${RUBY_VERSION}/bin:/home/vscode/.local/share/mise/installs/node/${NODE_VERSION}/bin:$PATH" \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Install bundler and foreman
RUN gem install bundler foreman

WORKDIR /workspaces/${WORKSPACE_FOLDER_NAME}

# Copy dependency files and install dependencies (cached unless Gemfile/package.json change)
COPY --chown=vscode:vscode Gemfile Gemfile.lock ./
RUN bundle install

COPY --chown=vscode:vscode package.json package-lock.json ./
RUN npm install

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

# Copy app source and generate .env.rb
COPY --chown=vscode:vscode . .
RUN rake overwrite_envrb

COPY --chown=vscode:vscode .devcontainer/entrypoint.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["entrypoint.sh"]
CMD ["sleep", "infinity"]