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
MAX_JOBS=${MAX_JOBS:-4}

# 设置日志文件
LOG_FILE="image_sync_$(date +%Y%m%d_%H%M%S).log"
ERROR_FILE="image_sync_errors_$(date +%Y%m%d_%H%M%S).log"
SUCCESS_FILE="image_sync_success_$(date +%Y%m%d_%H%M%S).log"

# 记录镜像名称的文件
SUCCESS_IMAGES_FILE=$(mktemp)
FAILED_IMAGES_FILE=$(mktemp)

# 日志函数
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp $message" | tee -a "$LOG_FILE"
}

log_success() {
    local image="$1"
    local target_image="$2"
    local message="[SUCCESS] $image -> $target_image"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp $message" | tee -a "$SUCCESS_FILE" >> "$LOG_FILE"
    echo "$image" >> "$SUCCESS_IMAGES_FILE"
    echo "✅ $message"
}

log_error() {
    local image="$1"
    local reason="$2"
    local message="[ERROR] $image ($reason)"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp $message" | tee -a "$ERROR_FILE" >&2 >> "$LOG_FILE"
    echo "$image" >> "$FAILED_IMAGES_FILE"
    echo "❌ $message" >&2
}

# 处理单个镜像的函数
process_image() {
    local image="$1"
    
    log "开始处理镜像: $image"
    echo "🔄 处理中: $image"
    
    # 解析镜像名称
    local image_name=$(echo "$image" | awk -F: '{print $1}' | awk -F/ '{print $NF}')
    local image_tag=$(echo "$image" | awk -F: '{print $2}')
    image_tag=${image_tag:-latest}
    
    # 目标镜像地址
    local target_image="${REGISTRY}/${NAMESPACE}/${image_name}:${image_tag}"
    
    # 拉取镜像
    echo "⬇️  拉取镜像: $image"
    if ! docker pull "$image" 2>&1 | tee -a "$LOG_FILE"; then
        log_error "$image" "拉取镜像失败"
        return 1
    fi
    
    # 重新标记
    echo "🏷️  重新标记: $image -> $target_image"
    if ! docker tag "$image" "$target_image" 2>&1 | tee -a "$LOG_FILE"; then
        log_error "$image" "重新标记镜像失败"
        return 1
    fi
    
    # 推送镜像
    echo "⬆️  推送镜像: $target_image"
    if ! docker push "$target_image" 2>&1 | tee -a "$LOG_FILE"; then
        log_error "$image" "推送镜像失败"
        return 1
    fi
    
    log_success "$image" "$target_image"
    return 0
}

# 主循环
echo "🚀 开始镜像同步任务"
echo "📊 最大并行度: $MAX_JOBS"
echo "========================================"

log "开始镜像同步任务，最大并行度: $MAX_JOBS"

TOTAL=0
SUCCESS=0
FAILED=0

# 读取镜像列表到数组
mapfile -t IMAGES < <(grep -vE '^\s*(#|$)' images.yaml)

TOTAL=${#IMAGES[@]}
echo "📋 总共需要处理: $TOTAL 个镜像"
echo ""

# 处理每个镜像
for ((i=0; i<${#IMAGES[@]}; i++)); do
    image="${IMAGES[$i]}"
    echo "========================================"
    echo "🔄 处理进度: $((i+1))/$TOTAL"
    
    # 等待直到有可用的并行槽位
    while [ $(jobs -rp | wc -l) -ge "$MAX_JOBS" ]; do
        sleep 1
    done
    
    # 处理镜像（在子进程中）
    ( process_image "$image" ) &
done

echo "========================================"
echo "⏳ 等待所有任务完成..."
wait

echo ""
echo "========================================"
echo "📊 所有任务已完成，正在生成报告..."
echo ""

# 统计结果
SUCCESS=$(wc -l < "$SUCCESS_IMAGES_FILE" | tr -d ' ')
FAILED=$(wc -l < "$FAILED_IMAGES_FILE" | tr -d ' ')

# 打印汇总报告
echo "🎯 ===== 同步结果汇总 ====="
echo "📈 总计处理: $TOTAL 个镜像"
echo "✅ 成功: $SUCCESS 个"
echo "❌ 失败: $FAILED 个"
echo ""

if [ "$SUCCESS" -gt 0 ]; then
    echo "✅ 成功镜像列表:"
    cat "$SUCCESS_IMAGES_FILE" | sed 's/^/  • /'
    echo ""
fi

if [ "$FAILED" -gt 0 ]; then
    echo "❌ 失败镜像列表:"
    cat "$FAILED_IMAGES_FILE" | sed 's/^/  • /'
    echo ""
    
    echo "📋 详细错误日志请查看: $ERROR_FILE"
fi

echo "📝 完整执行日志: $LOG_FILE"
echo "✅ 成功记录: $SUCCESS_FILE"
if [ -s "$ERROR_FILE" ]; then
    echo "❌ 错误记录: $ERROR_FILE"
fi

# 清理临时文件
rm -f "$SUCCESS_IMAGES_FILE" "$FAILED_IMAGES_FILE"

# 根据失败情况退出
if [ "$FAILED" -gt 0 ]; then
    echo ""
    echo "⚠️  同步完成，但有 $FAILED 个镜像失败"
    exit 1
else
    echo ""
    echo "🎉 同步完成，所有镜像处理成功！"
    exit 0
fi
