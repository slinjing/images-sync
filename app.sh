#!/bin/bash

# 检查必要文件和环境变量
if [ ! -f "images.yaml" ]; then
    echo "错误: images.yaml 文件不存在" >&2
    exit 1
fi

if [ -z "$REGISTRY" ] || [ -z "$NAMESPACE" ]; then
    echo "错误: 必须设置 REGISTRY 和 NAMESPACE 环境变量" >&2
    exit 1
fi

# 配置并行度（可根据需要调整）
MAX_JOBS=4
CURRENT_JOBS=0

# 设置日志文件
# LOG_FILE="image_sync_$(date +%Y%m%d_%H%M%S).log"
# ERROR_FILE="image_sync_errors_$(date +%Y%m%d_%H%M%S).log"
# SUCCESS_FILE="image_sync_success_$(date +%Y%m%d_%H%M%S).log"
SUCCESS_FILE_COUNT=$(mktemp)
FAILED_FILE_COUNT=$(mktemp)
echo 0 > "$SUCCESS_FILE_COUNT"
echo 0 > "$FAILED_FILE_COUNT"

# 初始化计数器
TOTAL=0
SUCCESS=0
FAILED=0

# 日志函数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# log_success() {
#     echo "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] $1" | tee -a "$SUCCESS_FILE" >> "$LOG_FILE"
#     ((SUCCESS++))
# }

# log_error() {
#     echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" | tee -a "$ERROR_FILE" >&2 >> "$LOG_FILE"
#     ((FAILED++))
# }

log_success() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] $1" | tee -a "$SUCCESS_FILE" >> "$LOG_FILE"
    # 递增成功计数（原子操作）
    flock -x "$SUCCESS_FILE_COUNT" -c "echo \$(( \$(cat "$SUCCESS_FILE_COUNT") + 1 )) > $SUCCESS_FILE_COUNT"
}

log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" | tee -a "$ERROR_FILE" >&2 >> "$LOG_FILE"
    # 递增失败计数（原子操作）
    flock -x "$FAILED_FILE_COUNT" -c "echo \$(( \$(cat "$FAILED_FILE_COUNT") + 1 )) > $FAILED_FILE_COUNT"
}

# 处理单个镜像的函数
process_image() {
    local image=$1
    
    log "开始处理镜像: $image"
    
    # 解析镜像名称
    local image_name=$(echo "$image" | awk -F: '{print $1}' | awk -F/ '{print $NF}')
    local image_tag=$(echo "$image" | awk -F: '{print $2}')
    image_tag=${image_tag:-latest}
    
    log "镜像名称: $image_name, 标签: $image_tag"
    
    # 目标镜像地址
    local target_image="${REGISTRY}/${NAMESPACE}/${image_name}:${image_tag}"
    
    # 拉取镜像
    if ! docker pull "$image" >> "$LOG_FILE" 2>&1; then
        log_error "拉取镜像失败: $image"
        return 1
    fi
    
    # 重新标记
    if ! docker tag "$image" "$target_image" >> "$LOG_FILE" 2>&1; then
        log_error "重新标记镜像失败: $image -> $target_image"
        return 1
    fi
    
    # 推送镜像
    if ! docker push "$target_image" >> "$LOG_FILE" 2>&1; then
        log_error "推送镜像失败: $target_image"
        return 1
    fi
    
    log_success "成功同步镜像: $image -> $target_image"
    return 0
}

# 主循环
log "开始镜像同步任务，最大并行度: $MAX_JOBS"
while IFS= read -r image; do
    # 跳过空行和注释
    [[ -z "$image" || "$image" =~ ^#.*$ ]] && continue
    
    ((TOTAL++))
    
    # 如果当前任务数达到最大值，等待
    while [ $(jobs -rp | wc -l) -ge $MAX_JOBS ]; do
        sleep 1
    done
    
    # 后台处理镜像
    process_image "$image" &
    
done < images.yaml

# 等待所有后台任务完成
wait

SUCCESS=$(cat "$SUCCESS_FILE_COUNT")
FAILED=$(cat "$FAILED_FILE_COUNT")

log "所有镜像处理完成。总计: $TOTAL, 成功: $SUCCESS, 失败: $FAILED"
exit $((FAILED > 0 ? 1 : 0))
