#!/bin/bash
set -euo pipefail  # 启用严格模式，捕获未定义变量和命令失败

# 检查必要环境变量
if [ -z "${REGISTRY:-}" ] || [ -z "${NAMESPACE:-}" ]; then
    echo "ERROR: 环境变量 REGISTRY 和 NAMESPACE 必须设置" >&2  # 错误输出到stderr
    exit 1
fi

# 初始化日志文件
> succeeded.log
> failed.log

# 处理镜像列表
while IFS= read -r image; do
    # 清理行内容（去空格、跳过空行和注释）
    image=$(echo "$image" | xargs)
    [[ -z "$image" || "$image" =~ ^# ]] && continue

    # 提取镜像名称和标签（更健壮的正则匹配）
    if [[ "$image" =~ ^([^:]+)(:([^:]+))?$ ]]; then
        image_name="${BASH_REMATCH[1]}"
        image_tag="${BASH_REMATCH[3]:-latest}"  # 默认为latest
    else
        echo "ERROR: 镜像格式无效: $image" | tee -a failed.log
        continue
    fi

    # 提取镜像短名称（处理带路径的情况，如ghcr.io/xxx/yyy -> yyy）
    short_name=$(basename "$image_name")

    # 目标镜像地址
    target_image="${REGISTRY}/${NAMESPACE}/${short_name}:${image_tag}"

    echo -e "\n===== 处理镜像: $image ====="
    echo "目标地址: $target_image"

    # 拉取镜像（带重试机制）
    retries=3
    for ((i=1; i<=retries; i++)); do
        if docker pull "$image"; then
            break
        else
            if [ $i -eq $retries ]; then
                echo "ERROR: 镜像拉取失败（重试$retries次）: $image" | tee -a failed.log
                continue 2  # 跳过当前镜像
            fi
            echo "WARN: 拉取失败，第$i次重试..."
            sleep 2
        fi
    done

    # 打标签
    if ! docker tag "$image" "$target_image"; then
        echo "ERROR: 镜像打标签失败: $image -> $target_image" | tee -a failed.log
        continue
    fi

    # 推送镜像（带重试机制）
    for ((i=1; i<=retries; i++)); do
        if docker push "$target_image"; then
            break
        else
            if [ $i -eq $retries ]; then
                echo "ERROR: 镜像推送失败（重试$retries次）: $target_image" | tee -a failed.log
                continue 2
            fi
            echo "WARN: 推送失败，第$i次重试..."
            sleep 2
        fi
    done

    # 记录成功日志
    echo "SUCCESS: 镜像同步完成: $image -> $target_image" | tee -a succeeded.log

done < images.yaml

# 输出最终结果
echo -e "\n===== 同步结果 ====="
if [ -s failed.log ]; then
    echo "❌ 部分镜像同步失败:"
    cat failed.log
    exit 1
else
    echo "✅ 所有镜像同步成功:"
    cat succeeded.log
    exit 0
fi
