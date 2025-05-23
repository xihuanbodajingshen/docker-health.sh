#!/bin/sh

# Ensure we are in the correct directory
cd /home/node/app

# --- BEGIN: SillyTavern Runtime Setup (copied from original Dockerfile ENTRYPOINT) ---

# Attempt to update SillyTavern Core from GitHub (staging branch)
echo '--- Attempting to update SillyTavern Core from GitHub (staging branch) ---'
if [ -d ".git" ] && [ "$(git rev-parse --abbrev-ref HEAD)" = "staging" ]; then
  echo 'Existing staging branch found. Resetting and pulling latest changes...'
  # Use git reset --hard and git pull to ensure we have the latest code
  git reset --hard HEAD && \
  git pull origin staging || echo 'WARN: git pull failed, continuing with existing code.';
  echo '--- SillyTavern Core update check finished. ---'
else
  echo 'WARN: .git directory not found or not on staging branch. Skipping runtime update. Code from build time will be used.';
fi;

echo '--- Checking for CONFIG_YAML environment variable ---';
# Ensure the CWD has correct permissions for writing config.yaml
# mkdir -p ./config && chown node:node ./config; # Removed mkdir
if [ -n "$CONFIG_YAML" ]; then
  echo 'Environment variable CONFIG_YAML found. Writing to ./config.yaml (root directory)...';
  # Write directly to ./config.yaml in the CWD
  printf '%s\n' "$CONFIG_YAML" > ./config.yaml && \
  chown node:node ./config.yaml && \
  echo 'Config written to ./config.yaml and permissions set successfully.';
else
  echo 'Warning: Environment variable CONFIG_YAML is not set or empty. Attempting to copy default config...';
  # Copy default if ENV VAR is missing and the example exists
  if [ -f "./public/config.yaml.example" ]; then
      # Copy default to ./config.yaml in the CWD
      cp "./public/config.yaml.example" "./config.yaml" && \
      chown node:node ./config.yaml && \
      echo 'Copied default config to ./config.yaml';
  else
      echo 'Warning: Default config ./public/config.yaml.example not found.';
  fi;
fi;

# --- BEGIN: Configure Git default identity at Runtime (Needed for some plugins/extensions) ---
echo '--- Configuring Git default user identity at runtime ---';
git config --global user.name "SillyTavern Sync" && \
git config --global user.email "sillytavern-sync@example.com";
echo '--- Git identity configured for runtime user. ---';
# --- END: Configure Git default identity at Runtime ---

# --- BEGIN: Dynamically Install Plugins at Runtime ---
echo '--- Checking for PLUGINS environment variable ---';
if [ -n "$PLUGINS" ]; then
  echo "*** Installing Plugins specified in PLUGINS environment variable: $PLUGINS ***" && \
  # Ensure plugins directory exists
  mkdir -p ./plugins && chown node:node ./plugins && \
  # Set comma as delimiter
  IFS=',' && \
  # Loop through each plugin URL
  for plugin_url in $PLUGINS; do \
    # Trim leading/trailing whitespace
    plugin_url=$(echo "$plugin_url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//') && \
    if [ -z "$plugin_url" ]; then continue; fi && \
    # Extract plugin name
    plugin_name_git=$(basename "$plugin_url") && \
    plugin_name=${plugin_name_git%.git} && \
    plugin_dir="./plugins/$plugin_name" && \
    echo "--- Installing plugin: $plugin_name from $plugin_url into $plugin_dir ---" && \
    # Remove existing dir if it exists
    rm -rf "$plugin_dir" && \
    # Clone the plugin (run as root, fix perms later)
    git clone --depth 1 "$plugin_url" "$plugin_dir" && \
    if [ -f "$plugin_dir/package.json" ]; then \
      echo "--- Installing dependencies for $plugin_name ---" && \
      (cd "$plugin_dir" && npm install --no-audit --no-fund --loglevel=error --no-progress --omit=dev --force && npm cache clean --force) || echo "WARN: Failed to install dependencies for $plugin_name"; \
    else \
       echo "--- No package.json found for $plugin_name, skipping dependency install. ---"; \
    fi || echo "WARN: Failed to clone $plugin_name from $plugin_url, skipping..."; \
  done && \
  # Reset IFS
  unset IFS && \
  # Fix permissions for plugins directory after installation
  echo "--- Setting permissions for plugins directory ---" && \
  chown -R node:node ./plugins && \
  echo "*** Plugin installation finished. ***"; \
else
  echo 'PLUGINS environment variable is not set or empty, skipping runtime plugin installation.';
fi;
# --- END: Dynamically Install Plugins at Runtime ---

# --- BEGIN: Auto-configure cloud-saves plugin if secrets provided ---
echo '--- Checking for cloud-saves plugin auto-configuration ---';
if [ -d "./plugins/cloud-saves" ] && [ -n "$REPO_URL" ] && [ -n "$GITHUB_TOKEN" ]; then
  echo "*** Auto-configuring cloud-saves plugin with provided secrets ***" && \
  config_file="./plugins/cloud-saves/config.json" && \
  echo "--- Creating config.json for cloud-saves plugin at $config_file ---" && \
  # Note: autoSaveEnabled is now defaulted to false
  printf '{\n  "repo_url": "%s",\n  "branch": "main",\n  "username": "",\n  "github_token": "%s",\n  "display_name": "user",\n  "is_authorized": true,\n  "last_save": null,\n  "current_save": null,\n  "has_temp_stash": false,\n  "autoSaveEnabled": false,\n  "autoSaveInterval": %s,\n  "autoSaveTargetTag": "%s"\n}\n' "$REPO_URL" "$GITHUB_TOKEN" "${AUTOSAVE_INTERVAL:-30}" "${AUTOSAVE_TARGET_TAG:-}" > "$config_file" && \
  chown node:node "$config_file" && \
  echo "*** cloud-saves plugin auto-configuration completed ***";
else
  if [ ! -d "./plugins/cloud-saves" ]; then
    echo 'cloud-saves plugin not found, skipping auto-configuration.';
  elif [ -z "$REPO_URL" ] || [ -z "$GITHUB_TOKEN" ]; then
    echo 'REPO_URL or GITHUB_TOKEN environment variables not provided, skipping cloud-saves auto-configuration.';
  fi;
fi;
# --- END: Auto-configure cloud-saves plugin ---

# --- BEGIN: Dynamically Install Extensions at Runtime ---
echo '--- Checking for EXTENSIONS environment variable ---';
if [ -n "$EXTENSIONS" ]; then
  echo "*** Installing Extensions specified in EXTENSIONS environment variable: $EXTENSIONS ***" && \
  # Determine extension installation directory based on INSTALL_FOR_ALL_USERS
  if [ "$INSTALL_FOR_ALL_USERS" = "true" ]; then
    ext_install_dir="./public/scripts/extensions/third-party" && \
    echo "--- Installing extensions for all users (system-wide) to $ext_install_dir ---";
  else
    ext_install_dir="./data/default-user/extensions" && \
    echo "--- Installing extensions for default user only to $ext_install_dir ---";
  fi && \
  # Ensure extension directory exists
  mkdir -p "$ext_install_dir" && chown node:node "$ext_install_dir" && \
  # Set comma as delimiter
  IFS=',' && \
  # Loop through each extension URL
  for ext_url in $EXTENSIONS; do \
    # Trim leading/trailing whitespace
    ext_url=$(echo "$ext_url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//') && \
    if [ -z "$ext_url" ]; then continue; fi && \
    # Extract extension name
    ext_name_git=$(basename "$ext_url") && \
    ext_name=${ext_name_git%.git} && \
    ext_dir="$ext_install_dir/$ext_name" && \
    echo "--- Installing extension: $ext_name from $ext_url into $ext_dir ---" && \
    # Remove existing dir if it exists
    rm -rf "$ext_dir" && \
    # Clone the extension (run as root, fix perms later)
    git clone --depth 1 "$ext_url" "$ext_dir" && \
    if [ -f "$ext_dir/package.json" ]; then \
      echo "--- Installing dependencies for extension $ext_name ---" && \
      (cd "$ext_dir" && npm install --no-audit --no-fund --loglevel=error --no-progress --omit=dev --force && npm cache clean --force) || echo "WARN: Failed to install dependencies for extension $ext_name"; \
    else \
       echo "--- No package.json found for extension $ext_name, skipping dependency install. ---"; \
    fi || echo "WARN: Failed to clone extension $ext_name from $ext_url, skipping..."; \
  done && \
  # Reset IFS
  unset IFS && \
  # Fix permissions for extensions directory after installation
  echo "--- Setting permissions for extensions directory ---" && \
  chown -R node:node "$ext_install_dir" && \
  echo "*** Extension installation finished. ***"; \
else
  echo 'EXTENSIONS environment variable is not set or empty, skipping runtime extension installation.';
fi;
# --- END: Dynamically Install Extensions at Runtime ---

echo 'Starting SillyTavern server in background...';
# Execute node server directly in the background
node server.js &

# Get the PID of the background node process
NODE_PID=$!

echo "SillyTavern server started with PID $NODE_PID. Waiting for it to become responsive..."

# Wait for SillyTavern to be responsive (Health Check)
until curl --output /dev/null --silent --head --fail http://localhost:8000/; do
  echo "SillyTavern is still starting or not responsive on port 8000, waiting 5 seconds..."
  # Check if the node process is still running while waiting
  if ! kill -0 $NODE_PID 2>/dev/null; then
    echo "ERROR: SillyTavern node process (PID $NODE_PID) has exited unexpectedly."
    exit 1
  fi
  sleep 5
done

echo "SillyTavern started successfully! Beginning periodic keep-alive..."

# Periodic Keep-Alive Loop
while true; do
  echo "Sending keep-alive request to http://localhost:8000/"
  # Send a simple GET request. Don't care about the output.
  curl http://localhost:8000/ > /dev/null 2>&1
  echo "Keep-alive request sent. Sleeping for 30 minutes."
  sleep 7200 # Sleep for 2 hours (2 * 60 * 60 = 7200 seconds)
done

# The script will ideally never reach here because of the infinite loop.
# However, if the loop somehow breaks or the node process exits,
# we might want to handle that. For now, the health check loop includes
# a check if the node process is still alive.
wait $NODE_PID # Wait for the node process if the loop ever exits (unlikely)
