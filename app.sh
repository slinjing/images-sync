#!/bin/bash
# GitHub Actions 专用镜像同步脚本
# 特性：失败继续、并发控制、完善日志
# 使用方法：./gha_sync_images.sh images.yaml

set -eo pipefail

# 配置区
REGISTRY="registry.cn-hangzhou.aliyuncs.com"
NAMESPACE="your-namespace"
MAX_JOBS=4                # 并发进程数
TIMEOUT=600               # 单镜像超时时间(秒)

# 初始化日志
LOG_DIR="sync_logs"
mkdir -p "$LOG_DIR"
CURRENT_TS=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/sync_${CURRENT_TS}.log"
FAILED_FILE="$LOG_DIR/failed_${CURRENT_TS}.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "====== 镜像同步开始 $(date) ======"
echo "🛠️ 并发数: $MAX_JOBS | 超时: ${TIMEOUT}s"

# 检查依赖
check_deps() {
    if ! command -v docker &> /dev/null; then
        echo "❌ Docker未安装!"
        exit 1
    fi
    if ! command -v parallel &> /dev/null; then
        echo "⚠️ 未找到GNU parallel，将使用串行模式"
        MAX_JOBS=1
    fi
}

# 单个镜像处理函数
process_image() {
    local image=$1
    local start_time=$(date +%s)
    
    echo "🔄 [$(date +%H:%M:%S)] 开始处理: $image"
    
    # 解析镜像名和标签
    local image_name="${image%:*}"
    local image_tag="${image#*:}"
    [[ "$image" == *:* ]] || {
        image_name="$image"
        image_tag="latest"
    }
    local final_name="${image_name##*/}"
    local target_image="${REGISTRY}/${NAMESPACE}/${final_name}:${image_tag}"
    
    # 拉取镜像 (带超时)
    if ! timeout $TIMEOUT docker pull --quiet "$image"; then
        echo "❌ [$(date +%H:%M:%S)] 拉取超时/失败: $image" | tee -a "$FAILED_FILE"
        return 1
    fi
    
    # 打标签
    if ! docker tag "$image" "$target_image"; then
        echo "❌ [$(date +%H:%M:%S)] 标签失败: $image" | tee -a "$FAILED_FILE"
        return 1
    fi
    
    # 推送镜像
    if timeout $TIMEOUT docker push --quiet "$target_image"; then
        echo "✅ [$(date +%H:%M:%S)] 同步成功: $image → $target_image"
        docker rmi "$image" "$target_image" --force >/dev/null 2>&1 || true
    else
        echo "❌ [$(date +%H:%M:%S)] 推送失败: $target_image" | tee -a "$FAILED_FILE"
        return 1
    fi
    
    local end_time=$(date +%s)
    echo "⏱️ [$(date +%H:%M:%S)] 处理完成: $image (耗时 $((end_time - start_time))s"
}

export -f process_image
export REGISTRY NAMESPACE TIMEOUT FAILED_FILE LOG_FILE

main() {
    check_deps
    
    # # 登录阿里云ACR
    # echo "🔐 正在登录阿里云ACR..."
    # echo "$ALIYUN_ACR_PASSWORD" | docker login \
    #     --username="$ALIYUN_ACR_USERNAME" \
    #     --password-stdin \
    #     "$REGISTRY" || {
    #     echo "❌ ACR登录失败!"
    #     exit 1
    }
    
    # 处理输入文件
    local input_file=$1
    if [ ! -f "$input_file" ]; then
        echo "❌ 文件不存在: $input_file"
        exit 1
    fi
    
    # 过滤有效镜像列表
    local valid_images=$(grep -vE '^[[:space:]]*(#|$)' "$input_file")
    local total_count=$(echo "$valid_images" | wc -l)
    echo "📋 共发现 $total_count 个有效镜像"
    
    # 并发处理
    if [ "$MAX_JOBS" -gt 1 ]; then
        echo "⚡ 启用并发模式 (最大 $MAX_JOBS 进程)"
        echo "$valid_images" | parallel -j "$MAX_JOBS" --halt never process_image
    else
        echo "🐌 使用串行模式"
        while IFS= read -r image; do
            process_image "$image"
        done <<< "$valid_images"
    fi
    
    # 结果统计
    local success_count=$(grep -c "✅" "$LOG_FILE" || true)
    local fail_count=$(grep -c "❌" "$FAILED_FILE" || true)
    
    echo "====== 同步结果 ======"
    echo "✅ 成功: $success_count"
    echo "❌ 失败: $fail_count"
    [ -s "$FAILED_FILE" ] && echo "失败的镜像详见: $FAILED_FILE"
    echo "📅 完整日志: $LOG_FILE"
}

main "$@"
