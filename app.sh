#!/bin/bash
set -uo pipefail

# 检查必要环境变量
if [ -z "${REGISTRY:-}" ] || [ -z "${NAMESPACE:-}" ]; then
    echo "ERROR: 环境变量 REGISTRY 和 NAMESPACE 必须设置" >&2
    exit 1
fi

# 并发数量，根据仓库限流调整
CONCURRENCY=3
retries=3
# 初始化日志文件
> succeeded.log
> failed.log

# 处理单个镜像
process_image() {
    local image="$1"
    image=$(echo "$image" | xargs)
    [[ -z "$image" || "$image" =~ ^# ]] && return 0

    local tmp_success
    local tmp_failed
    tmp_success=$(mktemp)
    tmp_failed=$(mktemp)

    echo -e "\n===== 处理镜像: $image ====="
    # 解析镜像名称与标签
    if [[ "$image" =~ ^([^:]+)(:([^:]+))?$ ]]; then
        image_name="${BASH_REMATCH[1]}"
        image_tag="${BASH_REMATCH[3]:-latest}"
    else
        echo "ERROR: 镜像格式无效: $image"
        echo "INVALID|$image|镜像格式无效" >> "$tmp_failed"
        cat "$tmp_failed" >> failed.log
        rm "$tmp_success" "$tmp_failed"
        return 1
    fi

    short_name=$(basename "$image_name")
    target_image="${REGISTRY}/${NAMESPACE}/${short_name}:${image_tag}"
    echo "目标镜像地址: $target_image"

    # 1. 拉取镜像，带重试
    local pull_ok=0
    for ((i=1; i<=retries; i++)); do
        if docker pull "$image"; then
            pull_ok=1
            break
        else
            echo "WARN: 拉取失败，第 $i 次重试..."
            sleep 2
        fi
    done
    if [ "$pull_ok" -ne 1 ]; then
        echo "ERROR: 镜像拉取失败（重试${retries}次）: $image"
        echo "PULL_FAIL|$image|拉取镜像失败" >> "$tmp_failed"
        cat "$tmp_failed" >> failed.log
        rm "$tmp_success" "$tmp_failed"
        return 1
    fi

    # 2. 打标签
    if ! docker tag "$image" "$target_image"; then
        echo "ERROR: 镜像打标签失败: $image -> $target_image"
        echo "TAG_FAIL|$image|打标签失败" >> "$tmp_failed"
        cat "$tmp_failed" >> failed.log
        # 清理
        docker rmi "$image" "$target_image" 2>/dev/null || true
        rm "$tmp_success" "$tmp_failed"
        return 1
    fi

    # 3. 推送镜像，带重试
    local push_ok=0
    for ((i=1; i<=retries; i++)); do
        if docker push "$target_image"; then
            push_ok=1
            break
        else
            echo "WARN: 推送失败，第 $i 次重试..."
            sleep 2
        fi
    done
    if [ "$push_ok" -ne 1 ]; then
        echo "ERROR: 镜像推送失败（重试${retries}次）: $target_image"
        echo "PUSH_FAIL|$image|推送镜像失败" >> "$tmp_failed"
        cat "$tmp_failed" >> failed.log
        # 清理本地镜像
        docker rmi "$image" "$target_image" 2>/dev/null || true
        rm "$tmp_success" "$tmp_failed"
        return 1
    fi

    # ✅ 同步成功，写入成功日志
    echo "SUCCESS|$image" >> "$tmp_success"
    echo "SUCCESS: 镜像同步完成: $image"
    cat "$tmp_success" >> succeeded.log

    # 【重点】同步完成立刻删除本地镜像，释放Runner磁盘
    docker rmi "$image" "$target_image" 2>/dev/null || true

    rm "$tmp_success" "$tmp_failed"
    return 0
}

# 导出函数，供xargs并发调用
export -f process_image
export REGISTRY NAMESPACE retries

# 读取镜像清单，过滤注释和空行，并发执行
cat images.yaml | while IFS= read -r line; do
    line=$(echo "$line" | xargs)
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    echo "$line"
done | xargs -P "${CONCURRENCY}" -I {} bash -c 'process_image "$@"' _ {}

# ========== 统计汇总【一定会执行！】 ==========
success_count=$(wc -l < succeeded.log)
fail_count=$(wc -l < failed.log)

echo -e "\n==================== 同步结果汇总 ===================="
echo "✅ 成功镜像数量：${success_count}"
echo "❌ 失败镜像数量：${fail_count}"
if [ "${fail_count}" -gt 0 ]; then
    echo -e "\n----- 失败镜像清单 -----"
    cat failed.log
fi
echo "======================================================"
