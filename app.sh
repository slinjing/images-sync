#!/bin/bash
set -euo pipefail
# 检查必要环境变量
if [ -z "${REGISTRY:-}" ] || [ -z "${NAMESPACE:-}" ]; then
    echo "ERROR: 环境变量 REGISTRY 和 NAMESPACE 必须设置" >&2
    exit 1
fi

# 并发数，根据仓库限流调整，推荐 2~4
CONCURRENCY=3

# 主日志文件
> succeeded.log
> failed.log

# 定义处理单个镜像函数
process_image() {
    local image="$1"
    image=$(echo "$image" | xargs)
    [[ -z "$image" || "$image" =~ ^# ]] && return 0

    # 每个任务独立临时文件，防止并发日志错乱
    local tmp_success
    local tmp_failed
    tmp_success=$(mktemp)
    tmp_failed=$(mktemp)

    echo -e "\n===== 处理镜像: $image ====="
    # 提取镜像名称和标签
    if [[ "$image" =~ ^([^:]+)(:([^:]+))?$ ]]; then
        image_name="${BASH_REMATCH[1]}"
        image_tag="${BASH_REMATCH[3]:-latest}"
    else
        echo "INVALID|$image|镜像格式无效" >> "$tmp_failed"
        echo "ERROR: 镜像格式无效: $image"
        cat "$tmp_failed" >> failed.log
        rm "$tmp_success" "$tmp_failed"
        return 1
    fi

    short_name=$(basename "$image_name")
    target_image="${REGISTRY}/${NAMESPACE}/${short_name}:${image_tag}"
    echo "目标地址: $target_image"

    retries=3
    # pull
    local pull_ok=0
    for ((i=1; i<=retries; i++)); do
        if docker pull "$image"; then
            pull_ok=1
            break
        else
            if [ $i -eq $retries ]; then
                echo "ERROR: 镜像拉取失败（重试$retries次）: $image"
                echo "PULL_FAIL|$image|拉取镜像失败" >> "$tmp_failed"
                cat "$tmp_failed" >> failed.log
                rm "$tmp_success" "$tmp_failed"
                return 1
            fi
            echo "WARN: 拉取失败，第$i次重试..."
            sleep 2
        fi
    done
    if [ "$pull_ok" -ne 1 ]; then
        cat "$tmp_failed" >> failed.log
        rm "$tmp_success" "$tmp_failed"
        return 1
    fi

    # tag
    if ! docker tag "$image" "$target_image"; then
        echo "ERROR: 镜像打标签失败: $image -> $target_image"
        echo "TAG_FAIL|$image|打标签失败" >> "$tmp_failed"
        cat "$tmp_failed" >> failed.log
        rm "$tmp_success" "$tmp_failed"
        return 1
    fi

    # push
    local push_ok=0
    for ((i=1; i<=retries; i++)); do
        if docker push "$target_image"; then
            push_ok=1
            break
        else
            if [ $i -eq $retries ]; then
                echo "ERROR: 镜像推送失败（重试$retries次）: $target_image"
                echo "PUSH_FAIL|$image|推送镜像失败" >> "$tmp_failed"
                cat "$tmp_failed" >> failed.log
                rm "$tmp_success" "$tmp_failed"
                return 1
            fi
            echo "WARN: 推送失败，第$i次重试..."
            sleep 2
        fi
    done
    if [ "$push_ok" -ne 1 ]; then
        cat "$tmp_failed" >> failed.log
        rm "$tmp_success" "$tmp_failed"
        return 1
    fi

    # =========【重点修改这里】=========
    # 只记录源镜像，不再写入目标镜像地址，不会出现***掩码
    echo "SUCCESS|$image" >> "$tmp_success"
    echo "SUCCESS: 镜像同步完成: $image"
    cat "$tmp_success" >> succeeded.log
    rm "$tmp_success" "$tmp_failed"
    return 0
}
export -f process_image
export REGISTRY NAMESPACE retries

# 读取镜像列表，过滤空行注释，xargs并行执行
cat images.yaml | while IFS= read -r line; do
    line=$(echo "$line" | xargs)
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    echo "$line"
done | xargs -P "${CONCURRENCY}" -I {} bash -c 'process_image "$@"' _ {}

# ========== 统计汇总 ==========
success_count=$(wc -l < succeeded.log)
fail_count=$(wc -l < failed.log)

echo -e "\n===== 同步结果汇总 ====="
echo "✅ 成功数量：${success_count}"
echo "❌ 失败数量：${fail_count}"

if [[ ${fail_count} -gt 0 ]]; then
    echo -e "\n失败镜像清单："
    cat failed.log
else
    echo -e "\n全部镜像同步成功！"
    cat succeeded.log
fi
