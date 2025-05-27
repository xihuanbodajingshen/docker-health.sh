#!/bin/sh
HF_TOKEN=$(printenv HF_TOKEN)
DATASET_ID=$(printenv DATASET_ID)
SYNC_INTERVAL=$(printenv SYNC_INTERVAL)
# Ensure we are in the correct directory
# 启动数据同步服务（如果提供了必要的环境变量）
if [ ! -z "${HF_TOKEN}" ] && [ ! -z "${DATASET_ID}" ]; then
  echo "启动数据同步服务..."
  nohup ${BASE}/sync_data.sh > ${BASE}/sync_data.log 2>&1 &
  echo "数据同步服务已在后台启动"
else
  echo "未提供HF_TOKEN或DATASET_ID，不启动数据同步服务"
fi

#!/bin/sh

# 添加更详细的日志
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1"
}

# 检查环境变量
if [ -z "$HF_TOKEN" ] || [ -z "$DATASET_ID" ]; then
    log_error "未启用备份功能 - 缺少HF_TOKEN或DATASET_ID环境变量"
    log_info "HF_TOKEN=${HF_TOKEN:0:3}... DATASET_ID=${DATASET_ID}"
    exit 0
fi

# 创建临时目录
TEMP_DIR="/tmp/sillytavern_backup"
DATA_DIR="/home/node/app/data"

# 确保目录存在并有正确权限
mkdir -p $TEMP_DIR
chmod -R 777 $TEMP_DIR
mkdir -p $DATA_DIR
chmod -R 777 $DATA_DIR

log_info "临时目录: $TEMP_DIR"
log_info "数据目录: $DATA_DIR"
log_info "HF_TOKEN: ${HF_TOKEN:0:5}..."
log_info "DATASET_ID: $DATASET_ID"

# 安装python和huggingface_hub
if ! command -v python3 > /dev/null 2>&1; then
    log_info "正在安装Python..."
    apk add --no-cache python3 py3-pip
else
    log_info "Python3已安装: $(python3 --version)"
fi

# 确保pip已安装
if ! command -v pip3 > /dev/null 2>&1; then
    log_info "正在安装pip..."
    apk add --no-cache py3-pip
else
    log_info "Pip3已安装: $(pip3 --version)"
fi

# 安装或更新huggingface_hub
log_info "正在安装/更新huggingface_hub..."
pip3 install --no-cache-dir --upgrade huggingface_hub
log_info "huggingface_hub安装完成"

# 测试huggingface_hub是否正常工作
if ! python3 -c "import huggingface_hub; print('huggingface_hub版本:', huggingface_hub.__version__)" > /dev/null 2>&1; then
    log_error "huggingface_hub导入失败，正在重试安装..."
    pip3 install --no-cache-dir huggingface_hub
fi

# 测试权限是否正常
touch "${TEMP_DIR}/test_file" && rm "${TEMP_DIR}/test_file"
if [ $? -ne 0 ]; then
    log_error "临时目录权限测试失败，正在修复权限..."
    chmod -R 777 $TEMP_DIR
fi

# 测试与HuggingFace API的连接
log_info "正在测试与HuggingFace API的连接..."
python3 -c "
from huggingface_hub import HfApi
try:
    api = HfApi(token='$HF_TOKEN')
    user_info = api.whoami()
    print(f'成功连接到HuggingFace API，用户: {user_info}')
except Exception as e:
    print(f'连接HuggingFace API失败: {str(e)}')
    exit(1)
"
if [ $? -ne 0 ]; then
    log_error "HuggingFace API连接测试失败，请检查令牌是否有效"
else
    log_info "HuggingFace API连接测试成功"
fi

# 生成唯一的测试文件名
TEST_FILE_NAME="test_file_$(date +%s)"

# 测试数据集权限
log_info "正在测试Dataset权限..."
python3 -c "
from huggingface_hub import HfApi
try:
    api = HfApi(token='$HF_TOKEN')
    
    # 创建本地测试文件
    with open('$TEMP_DIR/test_file', 'w') as f:
        f.write('test')
    
    # 上传测试文件
    test_file_name = '$TEST_FILE_NAME'
    print(f'正在上传测试文件: {test_file_name}')
    
    api.upload_file(
        path_or_fileobj='$TEMP_DIR/test_file',
        path_in_repo=test_file_name,
        repo_id='$DATASET_ID',
        repo_type='dataset'
    )
    print('成功上传测试文件到Dataset')
    
    # 删除已上传的测试文件
    print('正在删除测试文件...')
    api.delete_file(
        path_in_repo=test_file_name,
        repo_id='$DATASET_ID',
        repo_type='dataset'
    )
    print('已成功删除测试文件')
    
except Exception as e:
    print(f'Dataset权限测试失败: {str(e)}')
    exit(1)
"
if [ $? -ne 0 ]; then
    log_error "Dataset权限测试失败，请检查DATASET_ID是否正确且有写入权限"
else
    log_info "Dataset权限测试成功，测试文件已清理"
fi

# 确保本地测试文件被删除
rm -f "$TEMP_DIR/test_file"

# 上传备份
upload_backup() {
    file_path="$1"
    file_name="$2"
    
    if [ ! -f "$file_path" ]; then
        log_error "备份文件不存在: $file_path"
        return 1
    fi
    
    log_info "开始上传备份: $file_name ($(du -h $file_path | cut -f1))"
    
    python3 -c "
from huggingface_hub import HfApi
import sys
import os
import time

def manage_backups(api, repo_id, max_files=10):
    try:
        files = api.list_repo_files(repo_id=repo_id, repo_type='dataset')
        backup_files = [f for f in files if f.startswith('sillytavern_backup_') and f.endswith('.tar.gz')]
        backup_files.sort()
        
        if len(backup_files) >= max_files:
            files_to_delete = backup_files[:(len(backup_files) - max_files + 1)]
            for file_to_delete in files_to_delete:
                try:
                    api.delete_file(path_in_repo=file_to_delete, repo_id=repo_id, repo_type='dataset')
                    print(f'已删除旧备份: {file_to_delete}')
                except Exception as e:
                    print(f'删除 {file_to_delete} 时出错: {str(e)}')
    except Exception as e:
        print(f'管理备份文件时出错: {str(e)}')

token='$HF_TOKEN'
repo_id='$DATASET_ID'

try:
    api = HfApi(token=token)
    
    # 检查文件大小
    file_size = os.path.getsize('$file_path')
    print(f'备份文件大小: {file_size / (1024*1024):.2f} MB')

    # 确认Dataset存在
    try:
        dataset_info = api.dataset_info(repo_id=repo_id)
        print(f'Dataset信息: {dataset_info.id}')
    except Exception as e:
        print(f'获取Dataset信息失败: {str(e)}')
    
    start_time = time.time()
    print(f'开始上传: {start_time}')
    
    # 上传文件
    api.upload_file(
        path_or_fileobj='$file_path',
        path_in_repo='$file_name',
        repo_id=repo_id,
        repo_type='dataset'
    )
    
    end_time = time.time()
    print(f'上传完成，耗时: {end_time - start_time:.2f} 秒')
    print(f'成功上传 $file_name')
    
    # 管理备份
    manage_backups(api, repo_id)
except Exception as e:
    print(f'上传文件时出错: {str(e)}')
    sys.exit(1)
"
    if [ $? -ne 0 ]; then
        log_error "备份上传失败"
        return 1
    else
        log_info "备份上传成功"
        return 0
    fi
}

# 下载最新备份
download_latest_backup() {
    log_info "开始下载最新备份..."
    
    python3 -c "
from huggingface_hub import HfApi
import sys
import os
import tarfile
import tempfile
import time

try:
    api = HfApi(token='$HF_TOKEN')
    print('已创建API实例')
    
    # 列出仓库文件
    try:
        files = api.list_repo_files(repo_id='$DATASET_ID', repo_type='dataset')
        print(f'仓库文件数量: {len(files)}')
    except Exception as e:
        print(f'列出仓库文件失败: {str(e)}')
        sys.exit(1)
    
    backup_files = [f for f in files if f.startswith('sillytavern_backup_') and f.endswith('.tar.gz')]
    print(f'找到备份文件数量: {len(backup_files)}')
    
    if not backup_files:
        print('未找到备份文件')
        sys.exit(0)
    
    # 按名称排序（实际上是按时间戳排序）
    latest_backup = sorted(backup_files)[-1]
    print(f'最新备份文件: {latest_backup}')
    
    with tempfile.TemporaryDirectory() as temp_dir:
        print(f'创建临时目录: {temp_dir}')
        
        start_time = time.time()
        print(f'开始下载: {start_time}')
        
        # 下载文件
        try:
            filepath = api.hf_hub_download(
                repo_id='$DATASET_ID',
                filename=latest_backup,
                repo_type='dataset',
                local_dir=temp_dir
            )
            print(f'文件下载到: {filepath}')
        except Exception as e:
            print(f'下载文件失败: {str(e)}')
            sys.exit(1)
        
        end_time = time.time()
        print(f'下载完成，耗时: {end_time - start_time:.2f} 秒')
        
        if filepath and os.path.exists(filepath):
            # 确保目标目录存在
            os.makedirs('$DATA_DIR', exist_ok=True)
            
            # 检查文件权限
            print(f'文件权限: {oct(os.stat(filepath).st_mode)[-3:]}')
            
            # 解压文件
            try:
                with tarfile.open(filepath, 'r:gz') as tar:
                    print('开始解压文件...')
                    tar.extractall('$DATA_DIR')
                    print('文件解压完成')
            except Exception as e:
                print(f'解压文件失败: {str(e)}')
                sys.exit(1)
            
            print(f'成功从 {latest_backup} 恢复备份')
        else:
            print('下载的文件路径无效')
            sys.exit(1)
except Exception as e:
    print(f'下载备份过程中出错: {str(e)}')
    sys.exit(1)
"
    if [ $? -ne 0 ]; then
        log_error "备份下载失败"
        return 1
    else
        log_info "备份下载成功"
        return 0
    fi
}

# 首次启动时下载最新备份
log_info "正在从HuggingFace下载最新备份..."
download_latest_backup

# 同步函数
sync_data() {
    log_info "数据同步服务已启动"
    
    while true; do
        log_info "开始同步进程，时间: $(date)"
        
        if [ -d "$DATA_DIR" ]; then
            timestamp=$(date +%Y%m%d_%H%M%S)
            backup_file="sillytavern_backup_${timestamp}.tar.gz"
            backup_path="${TEMP_DIR}/${backup_file}"
            
            log_info "创建备份文件: $backup_path"
            
            # 检查数据目录内容
            file_count=$(find "$DATA_DIR" -type f | wc -l)
            log_info "数据目录文件数量: $file_count"
            
            if [ "$file_count" -eq 0 ]; then
                log_info "数据目录为空，跳过备份"
            else
                # 压缩数据目录
                tar -czf "$backup_path" -C "$DATA_DIR" .
                if [ $? -ne 0 ]; then
                    log_error "创建压缩文件失败"
                else
                    log_info "压缩文件创建成功: $(du -h $backup_path | cut -f1)"
                    
                    # 上传备份
                    log_info "正在上传备份到HuggingFace..."
                    upload_backup "$backup_path" "$backup_file"
                    
                    # 删除临时备份文件
                    rm -f "$backup_path"
                    log_info "已删除临时备份文件"
                fi
            fi
        else
            log_error "数据目录不存在: $DATA_DIR"
            mkdir -p "$DATA_DIR"
            chmod -R 777 "$DATA_DIR"
        fi
        
        # 设置同步间隔
        SYNC_INTERVAL=${SYNC_INTERVAL:-3600}
        log_info "下次同步将在 ${SYNC_INTERVAL} 秒后进行..."
        sleep $SYNC_INTERVAL
    done
}



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
node server.js & sync_data 

# 启动同步进程
sync_data 

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
# 启动同步进程
sync_data 

# The script will ideally never reach here because of the infinite loop.
# However, if the loop somehow breaks or the node process exits,
# we might want to handle that. For now, the health check loop includes
# a check if the node process is still alive.
wait $NODE_PID # Wait for the node process if the loop ever exits (unlikely)
