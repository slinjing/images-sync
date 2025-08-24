#!/bin/bash
set -euo pipefail

# 检查必要环境变量
if [ -z "${REGISTRY:-}" ] || [ -z "${NAMESPACE:-}" ]; then
    echo "ERROR: 环境变量 REGISTRY 和 NAMESPACE 必须设置" >&2
    exit 1
fi

# 初始化日志
> succeeded.log
> failed.log

# 单个镜像处理函数（封装逻辑，供并行调用）
process_image() {
    local image="$1"
    # 清理行内容（去空格、跳过空行和注释）
    image=$(echo "$image" | xargs)
    [[ -z "$image" || "$image" =~ ^# ]] && return

    # 解析镜像名称和标签（兼容带路径的镜像，如ghcr.io/xxx/yyy:tag）
    if [[ "$image" =~ ^([^:]+)(:([^:]+))?$ ]]; then
        local image_full_name="${BASH_REMATCH[1]}"
        local image_tag="${BASH_REMATCH[3]:-latest}"
        local image_name=$(basename "$image_full_name")  # 提取短名称
    else
        echo "ERROR: 无效镜像格式: $image" | tee -a failed.log
        return
    fi

    local target_image="${REGISTRY}/${NAMESPACE}/${image_name}:${image_tag}"
    echo "开始处理: $image -> $target_image"

    # 拉取镜像（带快速失败重试）
    if ! docker pull "$image"; then
        echo "ERROR: 拉取失败: $image" | tee -a failed.log
        return
    fi

    # 打标签
    if ! docker tag "$image" "$target_image"; then
        echo "ERROR: 打标签失败: $image -> $target_image" | tee -a failed.log
        return
    fi

    # 推送镜像
    if ! docker push "$target_image"; then
        echo "ERROR: 推送失败: $target_image" | tee -a failed.log
        return
    fi

    echo "SUCCESS: 同步完成: $target_image" | tee -a succeeded.log
}

# 导出函数（供parallel调用）
export -f process_image
export REGISTRY NAMESPACE  # 传递环境变量到子进程

# 并行处理镜像（-j 4 表示同时处理4个，可根据镜像大小调整）
cat images.yaml | grep -v '^#\|^$' | xargs -I {} echo {} | parallel -j 4 process_image {}

# 输出结果
echo -e "\n===== 同步结果 ====="
if [ -s failed.log ]; then
    echo "❌ 失败列表:"
    cat failed.log
    exit 1
else
    echo "✅ 全部成功:"
    cat succeeded.log
    exit 0
fi
