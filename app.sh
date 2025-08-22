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

# 配置并行度
MAX_JOBS=4

# 设置日志文件
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="image_sync_${TIMESTAMP}.log"
ERROR_FILE="image_sync_errors_${TIMESTAMP}.log"
SUCCESS_FILE="image_sync_success_${TIMESTAMP}.log"

# 记录镜像名称的文件
SUCCESS_IMAGES_FILE=$(mktemp)
FAILED_IMAGES_FILE=$(mktemp)

# 日志函数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

log_success() {
    local image=$1
    local target_image=$2
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] $image -> $target_image" | tee -a "$SUCCESS_FILE" >> "$LOG_FILE"
    echo "$image" >> "$SUCCESS_IMAGES_FILE"
}

log_error() {
    local image=$1
    local reason=$2
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $image ($reason)" | tee -a "$ERROR_FILE" >&2 >> "$LOG_FILE"
    echo "$image" >> "$FAILED_IMAGES_FILE"
}

# 处理单个镜像的函数
process_image() {
    local image=$1
    
    log "开始处理镜像: $image"
    
    # 解析镜像名称
    local image_name=$(echo "$image" | awk -F: '{print $1}' | awk -F/ '{print $NF}')
    local image_tag=$(echo "$image" | awk -F: '{print $2}')
    image_tag=${image_tag:-latest}
    
    # 目标镜像地址
    local target_image="${REGISTRY}/${NAMESPACE}/${image_name}:${image_tag}"
    
    log "目标镜像: $target_image"
    
    # 拉取镜像
    if ! docker pull "$image" >> "$LOG_FILE" 2>&1; then
        log_error "$image" "拉取镜像失败"
        return 1
    fi
    log "镜像拉取成功: $image"
    
    # 重新标记
    if ! docker tag "$image" "$target_image" >> "$LOG_FILE" 2>&1; then
        log_error "$image" "重新标记镜像失败"
        return 1
    fi
    log "镜像标记成功: $image -> $target_image"
    
    # 推送镜像
    if ! docker push "$target_image" >> "$LOG_FILE" 2>&1; then
        log_error "$image" "推送镜像失败"
        return 1
    fi
    log "镜像推送成功: $target_image"
    
    log_success "$image" "$target_image"
    return 0
}

# 主循环
log "===== 开始镜像同步任务 ====="
log "最大并行度: $MAX_JOBS"
log "目标仓库: $REGISTRY/$NAMESPACE"
log "开始时间: $(date '+%Y-%m-%d %H:%M:%S')"

TOTAL=0
SUCCESS_COUNT=0
FAILED_COUNT=0

while IFS= read -r image; do
    [[ -z "$image" || "$image" =~ ^#.*$ ]] && continue
    ((TOTAL++))
    while [ $(jobs -rp | wc -l) -ge $MAX_JOBS ]; do
        sleep 1
    done
    process_image "$image" &
done < images.yaml

# 等待所有后台任务完成
wait

# 统计结果
SUCCESS=$(wc -l < "$SUCCESS_IMAGES_FILE" 2>/dev/null | tr -d ' ' || echo 0)
FAILED=$(wc -l < "$FAILED_IMAGES_FILE" 2>/dev/null | tr -d ' ' || echo 0)

# 打印汇总报告
log "===== 同步结果汇总 ====="
log "总计处理: $TOTAL 个镜像"
log "成功: $SUCCESS 个"
log "失败: $FAILED 个"

if [ "$SUCCESS" -gt 0 ]; then
    log "成功镜像列表:"
    cat "$SUCCESS_IMAGES_FILE" 2>/dev/null | sed 's/^/  - /' | tee -a "$LOG_FILE"
fi

if [ "$FAILED" -gt 0 ]; then
    log "失败镜像列表:"
    cat "$FAILED_IMAGES_FILE" 2>/dev/null | sed 's/^/  - /' | tee -a "$LOG_FILE"
fi

log "结束时间: $(date '+%Y-%m-%d %H:%M:%S')"
log "===== 任务完成 ====="

# 清理临时文件
rm -f "$SUCCESS_IMAGES_FILE" "$FAILED_IMAGES_FILE"

exit $((FAILED > 0 ? 1 : 0))
