#!/bin/bash
set -uo pipefail

# ========== 终端颜色定义（仅终端输出使用，日志文件不写入颜色码） ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
SKY='\033[1;36m'
NC='\033[0m'

# 可由 workflow 环境变量覆盖，默认值
REGISTRY="${REGISTRY:-}"
NAMESPACE="${NAMESPACE:-}"
CONCURRENCY="${CONCURRENCY:-2}"
RETRIES="${RETRIES:-3}"
SLEEP_RETRY="${SLEEP_RETRY:-2}"

if [[ -z "${REGISTRY}" || -z "${NAMESPACE}" ]];then
    echo -e "${RED}ERROR: REGISTRY 和 NAMESPACE 环境变量必须设置${NC}" >&2
    exit 1
fi

# 初始化三类独立日志
> succeeded.log
> skipped.log
> failed.log

process_image() {
    local src_img="$1"
    src_img=$(echo "$src_img" | xargs)
    [[ -z "$src_img" || "$src_img" =~ ^# ]] && return 0

    local tmp_success
    tmp_success=$(mktemp)
    local tmp_skip
    tmp_skip=$(mktemp)
    local tmp_fail
    tmp_fail=$(mktemp)

    echo -e "\n===== 处理镜像: ${src_img} ====="
    echo "【当前磁盘】$(df -h / | awk 'NR==2 {print $5}')"

    # 解析镜像名称与tag
    if [[ "${src_img}" =~ ^(.*):([^:]+)$ ]];then
        img_name="${BASH_REMATCH[1]}"
        img_tag="${BASH_REMATCH[2]}"
    else
        echo "INVALID|${src_img}|镜像格式解析失败" >> "${tmp_fail}"
        echo -e "${RED}ERROR: 镜像格式无效 ${src_img}${NC}"
        cat "${tmp_fail}" >> failed.log
        rm -f "${tmp_success}" "${tmp_skip}" "${tmp_fail}"
        return 1
    fi

    short_img="${img_name##*/}"
    dest_img="${REGISTRY}/${NAMESPACE}/${short_img}:${img_tag}"
    echo "目标镜像: ${dest_img}"

    # =========业务规则：latest强制同步；非latest检测存在直接跳过 =========
    if [[ "${img_tag}" != "latest" ]];then
        # 检测目标镜像是否存在，屏蔽stderr错误输出
        if crane manifest "${dest_img}" >/dev/null 2>/dev/null;then
            echo "SKIP|${src_img}" >> "${tmp_skip}"
            echo -e "${SKY}SKIP: 镜像已存在，跳过 ${src_img}${NC}"
            cat "${tmp_skip}" >> skipped.log
            rm -f "${tmp_success}" "${tmp_skip}" "${tmp_fail}"
            return 0
        fi
    fi

    # ------------------- 开始 pull‑tag‑push流程 -------------------
    local pull_ok=0
    for ((i=1; i<=RETRIES; i++)); do
        if docker pull "${src_img}"; then
            pull_ok=1
            break
        else
            echo -e "${YELLOW}WARN: 拉取失败，第 $i/${RETRIES} 次重试${NC}"
            sleep "${SLEEP_RETRY}"
        fi
    done
    if [[ ${pull_ok} -ne 1 ]];then
        echo "PULL_FAIL|${src_img}|docker pull拉取镜像失败" >> "${tmp_fail}"
        echo -e "${RED}ERROR: 镜像拉取失败 ${src_img}${NC}"
        cat "${tmp_fail}" >> failed.log
        docker rmi "${src_img}" 2>/dev/null || true
        rm -f "${tmp_success}" "${tmp_skip}" "${tmp_fail}"
        return 1
    fi

    if ! docker tag "${src_img}" "${dest_img}";then
        echo "TAG_FAIL|${src_img}|docker tag打标签失败" >> "${tmp_fail}"
        echo -e "${RED}ERROR: 打标签失败 ${src_img} -> ${dest_img}${NC}"
        cat "${tmp_fail}" >> failed.log
        docker rmi "${src_img}" "${dest_img}" 2>/dev/null || true
        rm -f "${tmp_success}" "${tmp_skip}" "${tmp_fail}"
        return 1
    fi

    local push_ok=0
    for ((i=1; i<=RETRIES; i++)); do
        if docker push "${dest_img}"; then
            push_ok=1
            break
        else
            echo -e "${YELLOW}WARN: 推送失败，第 $i/${RETRIES} 次重试${NC}"
            sleep "${SLEEP_RETRY}"
        fi
    done

    if [[ ${push_ok} -eq 1 ]];then
        echo "SUCCESS|${src_img}" >> "${tmp_success}"
        echo -e "${GREEN}SUCCESS: 镜像同步完成 ${src_img}${NC}"
        cat "${tmp_success}" >> succeeded.log
    else
        echo "PUSH_FAIL|${src_img}|docker push推送镜像失败" >> "${tmp_fail}"
        echo -e "${RED}ERROR: 镜像推送失败 ${dest_img}${NC}"
        cat "${tmp_fail}" >> failed.log
    fi

    # 【关键】立刻清理本地镜像 + 清理悬空镜像，释放磁盘
    docker rmi "${src_img}" "${dest_img}" 2>/dev/null || true
    docker image prune -f >/dev/null 2>&1

    rm -f "${tmp_success}" "${tmp_skip}" "${tmp_fail}"
}

export -f process_image
export REGISTRY NAMESPACE CONCURRENCY RETRIES SLEEP_RETRY RED GREEN YELLOW SKY NC

# 读取镜像清单 images.yaml，过滤注释、空行
cat images.yaml | while IFS= read -r line;do
    line=$(echo "$line" | xargs)
    [[ -z "${line}" || "${line}" =~ ^# ]] && continue
    echo "${line}"
done | xargs -P"${CONCURRENCY}" -I {} bash -c 'process_image "{}"'

# ========== 统计汇总：成功 / 跳过 / 失败 ==========
success_count=$(wc -l < succeeded.log)
skip_count=$(wc -l < skipped.log)
fail_count=$(wc -l < failed.log)

echo -e "\n==================== 同步结果汇总 ===================="
echo -e "${GREEN}✅ 成功镜像数量：${success_count}${NC}"
echo -e "${SKY}⏭️  跳过镜像数量：${skip_count}${NC}"
echo -e "${RED}❌ 失败镜像数量：${fail_count}${NC}"

if [[ ${skip_count} -gt 0 ]];then
    echo -e "\n------ 跳过镜像清单 -----"
    cat skipped.log
fi

if [[ ${fail_count} -gt 0 ]];then
    echo -e "\n------ 失败镜像清单 -----"
    cat failed.log
fi
echo "======================================================"
