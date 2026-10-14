#!/bin/bash
set -uo pipefail

# ========== 颜色定义 ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 环境变量，可在 workflow 传入，带默认值
REGISTRY="${REGISTRY:-}"
NAMESPACE="${NAMESPACE:-}"
CONCURRENCY="${CONCURRENCY:-4}"
RETRIES="${RETRIES:-3}"

if [[ -z "${REGISTRY}" || -z "${NAMESPACE}" ]];then
    echo -e "${RED}ERROR: REGISTRY 和 NAMESPACE 环境变量必须设置${NC}" >&2
    exit 1
fi

# 清空日志
> succeeded.log
> failed.log

# 单镜像处理函数
process_image(){
    local src_img="$1"
    src_img=$(echo "$src_img" | xargs)
    [[ -z "$src_img" || "$src_img" =~ ^# ]] && return 0

    local tmp_success
    tmp_success=$(mktemp)
    local tmp_fail
    tmp_fail=$(mktemp)

    echo -e "\n===== 处理镜像: ${src_img} ====="

    # 解析源镜像名称和tag
    if [[ "${src_img}" =~ ^(.*):([^:]+)$ ]];then
        img_name="${BASH_REMATCH[1]}"
        img_tag="${BASH_REMATCH[2]}"
    else
        echo "INVALID|${src_img}|镜像格式解析失败" >> "${tmp_fail}"
        echo -e "${RED}ERROR: 镜像格式无效 ${src_img}${NC}"
        cat "${tmp_fail}" >> failed.log
        rm -f "${tmp_success}" "${tmp_fail}"
        return 1
    fi

    # 目标镜像
    short_img="${img_name##*/}"
    dest_img="${REGISTRY}/${NAMESPACE}/${short_img}:${img_tag}"
    echo "目标镜像: ${dest_img}"

    # ========== latest标签强制同步，跳过manifest检查 ==========
    if [[ "${img_tag}" != "latest" ]];then
        # 非latest标签：原有逻辑，存在则跳过
        if crane manifest "${dest_img}" >/dev/null 2>&1;then
            echo "SUCCESS|${src_img}" >> "${tmp_success}"
            echo -e "${GREEN}SKIP: 镜像已存在，跳过 ${src_img}${NC}"
            cat "${tmp_success}" >> succeeded.log
            rm -f "${tmp_success}" "${tmp_fail}"
            return 0
        fi
    fi

    # latest标签 / 目标不存在：执行copy
    local copy_ok=0
    for ((i=1; i<=RETRIES; i++));do
        if crane copy "${src_img}" "${dest_img}" --allow-nondistributable;then
            copy_ok=1
            break
        else
            echo -e "${YELLOW}WARN: 拷贝失败，第 ${i}/${RETRIES} 次重试${NC}"
            sleep 1
        fi
    done

    if [[ ${copy_ok} -eq 1 ]];then
        echo "SUCCESS|${src_img}" >> "${tmp_success}"
        echo -e "${GREEN}SUCCESS: 镜像同步完成 ${src_img}${NC}"
        cat "${tmp_success}" >> succeeded.log
    else
        echo "COPY_FAIL|${src_img}|crane copy 拷贝镜像失败" >> "${tmp_fail}"
        echo -e "${RED}ERROR: 镜像拷贝失败 ${src_img}${NC}"
        cat "${tmp_fail}" >> failed.log
    fi

    rm -f "${tmp_success}" "${tmp_fail}"
}

export -f process_image
export REGISTRY NAMESPACE CONCURRENCY RETRIES RED GREEN YELLOW NC

# 读取images.yaml，过滤注释空行，并发执行
cat images.yaml | while IFS= read -r line;do
    line=$(echo "$line" | xargs)
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    echo "$line"
done | xargs -P"${CONCURRENCY}" -I {} bash -c 'process_image "{}"'

# ========== 汇总统计 ==========
success_count=$(wc -l < succeeded.log)
fail_count=$(wc -l < failed.log)

echo -e "\n==================== 同步结果汇总 ===================="
echo -e "${GREEN}✅ 成功镜像数量：${success_count}${NC}"
echo -e "${RED}❌ 失败镜像数量：${fail_count}${NC}"
if [[ ${fail_count} -gt 0 ]];then
    echo -e "\n------ 失败镜像清单 -----"
    cat failed.log
fi
echo "======================================================"
