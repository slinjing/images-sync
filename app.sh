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

# 设置日志文件
LOG_FILE="image_sync_$(date +%Y%m%d_%H%M%S).log"
ERROR_FILE="image_sync_errors_$(date +%Y%m%d_%H%M%S).log"

# 日志函数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" | tee -a "$ERROR_FILE" >&2
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
    if ! docker pull "$image"; then
        log_error "拉取镜像失败: $image"
        return 1
    fi
    
    # 重新标记
    if ! docker tag "$image" "$target_image"; then
        log_error "重新标记镜像失败: $image -> $target_image"
        return 1
    fi
    
    # 推送镜像
    if ! docker push "$target_image"; then
        log_error "推送镜像失败: $target_image"
        return 1
    fi
    
    log "成功同步镜像: $image -> $target_image"
    return 0
}

# 主循环
while IFS= read -r image; do
    # 跳过空行和注释
    [[ -z "$image" || "$image" =~ ^#.*$ ]] && continue
    
    # 处理镜像
    if ! process_image "$image"; then
        log_error "处理镜像时遇到错误: $image"
        # 可以选择是否继续处理下一个镜像
        # exit 1
    fi
done < images.yaml

log "所有镜像处理完成"
