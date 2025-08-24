#!/bin/bash
set -euo pipefail  # 严格模式：未定义变量报错、管道失败即终止、命令失败即终止

# 检查必要环境变量
if [ -z "${REGISTRY:-}" ] || [ -z "${NAMESPACE:-}" ]; then
    echo "ERROR: 环境变量 REGISTRY 和 NAMESPACE 必须设置"
    exit 1
fi

# 初始化日志文件（每次运行清空成功日志，记录失败日志）
> succeeded.log
> failed.log

# 读取镜像列表并处理
while IFS= read -r image; do
    # 清理行内容（去除前后空格、跳过空行和注释）
    image=$(echo "$image" | xargs)  # 去除前后空格
    [[ -z "$image" || "$image" =~ ^# ]] && continue

    # 提取镜像名称（处理带路径的镜像名，如 registry.example.com/ns/img -> img）
    image_name=$(echo "$image" | cut -d ":" -f 1 | xargs)
    image_name=$(basename "$image_name")  # 更可靠的文件名提取

    # 提取镜像版本（默认 latest）
    if [[ "$image" == *":"* ]]; then
        image_tag=$(echo "$image" | cut -d ":" -f 2 | xargs)
    else
        image_tag="latest"
    fi

    # 目标镜像地址
    target_image="${REGISTRY}/${NAMESPACE}/${image_name}:${image_tag}"

    echo -e "\nINFO: 开始处理镜像: $image"
    echo "INFO: 目标镜像地址: $target_image"

    # 拉取镜像
    if ! docker pull "$image"; then
        echo "ERROR: 镜像拉取失败: $image" | tee -a failed.log
        continue  # 继续处理下一个镜像，而非直接退出
    fi

    # 打标签
    if ! docker tag "$image" "$target_image"; then
        echo "ERROR: 镜像打标签失败: $image -> $target_image" | tee -a failed.log
        continue
    fi

    # 推送镜像
    if ! docker push "$target_image"; then
        echo "ERROR: 镜像推送失败: $target_image" | tee -a failed.log
        continue
    fi

    # 记录成功日志
    echo "SUCCESS: 镜像同步完成: $image -> $target_image" | tee -a succeeded.log

done < images.yaml

# 处理最终结果
if [ -s failed.log ]; then
    echo -e "\nERROR: 以下镜像同步失败："
    cat failed.log
    exit 1
else
    echo -e "\nSUCCESS: 所有镜像同步完成！"
    cat succeeded.log
    exit 0
fi
