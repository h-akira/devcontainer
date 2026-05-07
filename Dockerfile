FROM node:20

ARG TZ
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest

# Install basic development tools and iptables/ipset
RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  tmux \
  man-db \
  unzip \
  gnupg2 \
  gh \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  nano \
  ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Ensure default node user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R node:node /usr/local/share

ARG USERNAME=node

# Persist bash history.
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Create workspace and config directories and set permissions.
# Volumes mounted from devcontainer.json land at these paths; we pre-create the
# parent directories so the mount target is owned by node:node, not root, on
# the first container start. Without this the parent dir may end up root-owned
# on some Docker setups, breaking init-*.sh's mkdir -p / git clone steps.
RUN mkdir -p \
    /workspace \
    /home/node/.claude \
    /home/node/.aws \
    /home/node/.local/share/zinit \
    /home/node/.local/share/nvim \
    /home/node/.tmux/plugins && \
  chown -R node:node /workspace /home/node/.claude /home/node/.aws /home/node/.local /home/node/.tmux

WORKDIR /workspace

# Install git-delta
ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Install neovim via the official AppImage. Debian bookworm's neovim is 0.7,
# which is too old for ddc.vim / denops (require >=0.11) and lazy.nvim. We
# extract the AppImage at build time so fuse is not needed at runtime.
# We also symlink `vi` and `vim` to point to nvim — the project uses neovim
# exclusively, but tools that hard-code `vim` (git, sudoedit, etc.) still work.
ARG NVIM_VERSION=0.12.2
RUN ARCH=$(dpkg --print-architecture) && \
  case "$ARCH" in \
    amd64) NVIM_ARCH="x86_64" ;; \
    arm64) NVIM_ARCH="arm64" ;; \
    *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
  esac && \
  cd /tmp && \
  curl -fsSL "https://github.com/neovim/neovim/releases/download/v${NVIM_VERSION}/nvim-linux-${NVIM_ARCH}.appimage" -o nvim.appimage && \
  chmod +x nvim.appimage && \
  ./nvim.appimage --appimage-extract >/dev/null && \
  mv squashfs-root /opt/nvim && \
  ln -sf /opt/nvim/AppRun /usr/local/bin/nvim && \
  ln -sf /opt/nvim/AppRun /usr/local/bin/vim && \
  ln -sf /opt/nvim/AppRun /usr/local/bin/vi && \
  rm nvim.appimage

# Install Deno (required by denops.vim, which powers ddc.vim completion).
# Pulled from the official GitHub release zip for reproducibility — same pattern
# as neovim above.
ARG DENO_VERSION=2.7.14
RUN ARCH=$(dpkg --print-architecture) && \
  case "$ARCH" in \
    amd64) DENO_ARCH="x86_64-unknown-linux-gnu" ;; \
    arm64) DENO_ARCH="aarch64-unknown-linux-gnu" ;; \
    *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
  esac && \
  cd /tmp && \
  curl -fsSL "https://github.com/denoland/deno/releases/download/v${DENO_VERSION}/deno-${DENO_ARCH}.zip" -o deno.zip && \
  unzip -q deno.zip && \
  mv deno /usr/local/bin/deno && \
  chmod +x /usr/local/bin/deno && \
  rm deno.zip

# Install AWS CLI v2 (pinned version for reproducibility)
ARG AWSCLI_VERSION=2.34.41
RUN ARCH=$(dpkg --print-architecture) && \
  case "$ARCH" in \
    amd64) AWS_ARCH="x86_64" ;; \
    arm64) AWS_ARCH="aarch64" ;; \
    *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
  esac && \
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}-${AWSCLI_VERSION}.zip" -o "awscliv2.zip" && \
  unzip -q awscliv2.zip && \
  ./aws/install && \
  rm -rf awscliv2.zip aws/

# Set up non-root user
USER node

# Install uv (for awslabs MCP servers via uvx)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH=/home/node/.local/bin:$PATH

# Install global npm packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# Set the default shell to zsh rather than sh
ENV SHELL=/bin/zsh

# Set the default editor and visual.
# `vim` here is a symlink to nvim (see neovim install step above).
ENV EDITOR=vim
ENV VISUAL=vim

# Install Claude Code
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Copy devcontainer config files into the image (used by init-*.sh at runtime)
USER root
COPY config /opt/devcontainer/config
RUN chown -R node:node /opt/devcontainer

# Copy and set up init scripts
COPY init-firewall.sh init-zsh.sh init-nvim.sh init-tmux.sh init-mcp.sh init-claude.sh init-all.sh /usr/local/bin/
RUN chmod +x \
    /usr/local/bin/init-firewall.sh \
    /usr/local/bin/init-zsh.sh \
    /usr/local/bin/init-nvim.sh \
    /usr/local/bin/init-tmux.sh \
    /usr/local/bin/init-mcp.sh \
    /usr/local/bin/init-claude.sh \
    /usr/local/bin/init-all.sh && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall

# Allow node to use sudo with a password.
# AI agents cannot type passwords interactively, so prompts effectively block
# them while the human user can still run e.g. `sudo apt install ...` for
# ad-hoc experimentation. Override SUDO_PASSWORD via devcontainer.json's
# build.args to avoid baking a default into the image.
#
# IMPORTANT — this is intended for the *submodule* usage of this repo, where
# editing the Dockerfile is awkward (it would dirty the submodule). When you
# vendor this repo into a project (after `git submodule deinit`), prefer to
# COMMENT OUT the two lines below and instead bake the packages you need into
# the apt-get install list above. That keeps AI isolation strict and removes
# the password-on-image-layer footgun. See README.md for details.
ARG SUDO_PASSWORD=devcontainer
RUN echo "node:${SUDO_PASSWORD}" | chpasswd && \
  usermod -aG sudo node

USER node
