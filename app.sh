#!/bin/bash

# 启用错误检测和管道错误检测
set -eo pipefail

# 检查必要文件和环境变量
if [[ ! -f "images.yaml" ]]; then
    echo "错误: images.yaml 文件不存在" >&2
    exit 1
fi

if [[ -z "$REGISTRY" || -z "$NAMESPACE" ]]; then
    echo "错误: 必须设置 REGISTRY 和 NAMESPACE 环境变量" >&2
    exit 1
fi

# 配置参数
MAX_PARALLEL=${MAX_PARALLEL:-4}               # 默认并行度为4
RETRY_COUNT=${RETRY_COUNT:-2}                # 默认重试次数
LOG_DIR=${LOG_DIR:-./logs}                   # 日志目录
TIMEOUT=${TIMEOUT:-600}                      # 单个任务超时时间(秒)

# 创建日志目录
mkdir -p "$LOG_DIR"

# 设置日志文件
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/image_sync_${TIMESTAMP}.log"
ERROR_FILE="$LOG_DIR/image_sync_errors_${TIMESTAMP}.log"
SUCCESS_FILE="$LOG_DIR/image_sync_success_${TIMESTAMP}.log"
TASK_LOG_DIR="$LOG_DIR/task_logs"
mkdir -p "$TASK_LOG_DIR"

# 初始化计数器
declare -i TOTAL=0 SUCCESS=0 FAILED=0 SKIPPED=0

# 日志函数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] $1" | tee -a "$SUCCESS_FILE" >> "$LOG_FILE"
    ((SUCCESS++))
}

log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" | tee -a "$ERROR_FILE" >&2 >> "$LOG_FILE"
    ((FAILED++))
}

# 清理函数
cleanup() {
    log "正在清理..."
    # 杀死所有子进程
    pkill -P $$ 2>/dev/null || true
    log "同步完成。总计: $TOTAL, 成功: $SUCCESS, 失败: $FAILED, 跳过: $SKIPPED"
    exit 0
}

# 捕获退出信号
trap cleanup INT TERM EXIT

# 处理单个镜像的函数
process_image() {
    local image=$1
    local task_id=$2
    local task_log="$TASK_LOG_DIR/task_${task_id}.log"
    
    echo "=== 开始任务 $task_id: $image ===" > "$task_log"
    
    # 解析镜像名称
    local image_name=$(echo "$image" | awk -F: '{print $1}' | awk -F/ '{print $NF}')
    local image_tag=$(echo "$image" | awk -F: '{print $2}')
    image_tag=${image_tag:-latest}
    
    echo "镜像详情: 名称=$image_name, 标签=$image_tag" >> "$task_log"
    
    # 目标镜像地址
    local target_image="${REGISTRY}/${NAMESPACE}/${image_name}:${image_tag}"
    
    # 重试逻辑
    local attempt=0
    while [[ $attempt -le $RETRY_COUNT ]]; do
        attempt=$((attempt + 1))
        
        # 拉取镜像
        if timeout $TIMEOUT docker pull "$image" >> "$task_log" 2>&1; then
            echo "拉取镜像成功: $image (尝试 $attempt)" >> "$task_log"
            break
        else
            echo "拉取镜像失败: $image (尝试 $attempt)" >> "$task_log"
            if [[ $attempt -gt $RETRY_COUNT ]]; then
                log_error "[任务 $task_id] 拉取镜像失败: $image (超过最大重试次数)"
                return 1
            fi
            sleep $((attempt * 2))  # 指数退避
        fi
    done
    
    # 重新标记
    if ! docker tag "$image" "$target_image" >> "$task_log" 2>&1; then
        log_error "[任务 $task_id] 重新标记镜像失败: $image -> $target_image"
        return 1
    fi
    
    # 推送镜像
    attempt=0
    while [[ $attempt -le $RETRY_COUNT ]]; do
        attempt=$((attempt + 1))
        
        if timeout $TIMEOUT docker push "$target_image" >> "$task_log" 2>&1; then
            echo "推送镜像成功: $target_image (尝试 $attempt)" >> "$task_log"
            break
        else
            echo "推送镜像失败: $target_image (尝试 $attempt)" >> "$task_log"
            if [[ $attempt -gt $RETRY_COUNT ]]; then
                log_error "[任务 $task_id] 推送镜像失败: $target_image (超过最大重试次数)"
                return 1
            fi
            sleep $((attempt * 2))  # 指数退避
        fi
    done
    
    log_success "[任务 $task_id] 成功同步镜像: $image -> $target_image"
    return 0
}

# 主循环
log "开始镜像同步任务，最大并行度: $MAX_PARALLEL"
TASK_ID=0

while IFS= read -r image; do
    # 跳过空行和注释
    [[ -z "$image" || "$image" =~ ^#.*$ ]] && { ((SKIPPED++)); continue; }
    
    ((TOTAL++))
    ((TASK_ID++))
    
    # 等待有空闲的并行槽位
    while [[ $(jobs -rp | wc -l) -ge $MAX_PARALLEL ]]; do
        sleep 1
    done
    
    # 后台处理镜像
    process_image "$image" "$TASK_ID" &
    
    sleep 0.1  # 避免任务ID冲突
done < images.yaml

# 等待所有后台任务完成
wait

log "所有镜像处理完成。总计: $TOTAL, 成功: $SUCCESS, 失败: $FAILED, 跳过: $SKIPPED"
exit $((FAILED > 0 ? 1 : 0))
