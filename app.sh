#!/bin/bash
set -uo pipefail

# ========== 终端颜色定义 ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
SKY='\033[1;36m'
NC='\033[0m'

# 环境变量，可由 workflow 覆盖
REGISTRY="${REGISTRY:-}"
NAMESPACE="${NAMESPACE:-}"
CONCURRENCY="${CONCURRENCY:-2}"
RETRIES="${RETRIES:-3}"
SLEEP_RETRY="${SLEEP_RETRY:-2}"

# 校验仓库信息
if [[ -z "${REGISTRY}" || -z "${NAMESPACE}" ]];then
    echo -e "${RED}ERROR: REGISTRY 和 NAMESPACE 环境变量必须设置${NC}" >&2
    exit 1
fi

# 初始化日志文件
> succeeded.log
> skipped.log
> failed.log

# 单镜像处理函数
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

    echo -e "\n===== [TASK:${src_img}] 开始处理 ====="
    echo "【当前磁盘】$(df -h / | awk 'NR==2 {print $5}')"

    # Docker原生逻辑：无tag自动补 :latest
    if [[ "$src_img" != *:* ]];then
        echo -e "${YELLOW}WARN: 未指定tag，自动使用 latest → ${src_img}:latest ${NC}"
        src_img="${src_img}:latest"
    fi

    # 解析镜像名与tag
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
    echo "[${src_img}] 目标镜像: ${dest_img}"

    local need_sync=1
    # 业务规则: latest标签强制同步；其他tag先查询目标仓库
    if [[ "${img_tag}" != "latest" ]];then
        # 查询目标镜像是否存在，捕获crane退出码
        crane manifest "${dest_img}" >/dev/null 2>/dev/null
        local crane_ret=$?
        if [[ ${crane_ret} -eq 0 ]];then
            # 返回码0：镜像真实存在，直接跳过，不走pull流程
            echo "SKIP|${src_img}" >> "${tmp_skip}"
            echo -e "${SKY}[${src_img}] SKIP: 镜像已存在，跳过，不执行pull${NC}"
            cat "${tmp_skip}" >> skipped.log
            rm -f "${tmp_success}" "${tmp_skip}" "${tmp_fail}"
            return 0
        else
            # crane返回非0：两种可能：1.镜像不存在；2.crane网络/鉴权异常，都需要执行同步
            echo -e "${YELLOW}[${src_img}] INFO: 目标镜像不存在或crane查询异常，将执行同步${NC}"
            need_sync=1
        fi
    fi

    # ------------------- 只有 need_sync=1 才会走到pull流程 -------------------
    # Pull镜像，带重试
    local pull_ok=0
    for ((i=1; i<=RETRIES; i++)); do
        if docker pull "${src_img}"; then
            pull_ok=1
            break
        else
            echo -e "${YELLOW}[${src_img}] WARN: 拉取失败，第 $i/${RETRIES} 次重试${NC}"
            sleep "${SLEEP_RETRY}"
        fi
    done
    if [[ ${pull_ok} -ne 1 ]];then
        echo "PULL_FAIL|${src_img}|docker pull拉取镜像失败" >> "${tmp_fail}"
        echo -e "${RED}[${src_img}] ERROR: 镜像拉取失败 ${src_img}${NC}"
        cat "${tmp_fail}" >> failed.log
        docker rmi "${src_img}" 2>/dev/null || true
        rm -f "${tmp_success}" "${tmp_skip}" "${tmp_fail}"
        return 1
    fi

    # 打目标仓库标签
    if ! docker tag "${src_img}" "${dest_img}";then
        echo "TAG_FAIL|${src_img}|docker tag打标签失败" >> "${tmp_fail}"
        echo -e "${RED}[${src_img}] ERROR: 打标签失败 ${src_img} -> ${dest_img}${NC}"
        cat "${tmp_fail}" >> failed.log
        docker rmi "${src_img}" "${dest_img}" 2>/dev/null || true
        rm -f "${tmp_success}" "${tmp_skip}" "${tmp_fail}"
        return 1
    fi

    # Push推送，带重试
    local push_ok=0
    for ((i=1; i<=RETRIES; i++)); do
        if docker push "${dest_img}"; then
            push_ok=1
            break
        else
            echo -e "${YELLOW}[${src_img}] WARN: 推送失败，第 $i/${RETRIES} 次重试${NC}"
            sleep "${SLEEP_RETRY}"
        fi
    done

    if [[ ${push_ok} -eq 1 ]];then
        echo "SUCCESS|${src_img}" >> "${tmp_success}"
        echo -e "${GREEN}[${src_img}] SUCCESS: 镜像同步完成 ${src_img}${NC}"
        cat "${tmp_success}" >> succeeded.log
    else
        echo "PUSH_FAIL|${src_img}|docker push推送镜像失败" >> "${tmp_fail}"
        echo -e "${RED}[${src_img}] ERROR: 镜像推送失败 ${dest_img}${NC}"
        cat "${tmp_fail}" >> failed.log
    fi

    # 清理本地镜像，释放磁盘
    docker rmi "${src_img}" "${dest_img}" 2>/dev/null || true
    docker image prune -f >/dev/null 2>&1

    rm -f "${tmp_success}" "${tmp_skip}" "${tmp_fail}"
}

# 导出函数，供xargs并行调用
export -f process_image
export REGISTRY NAMESPACE CONCURRENCY RETRIES SLEEP_RETRY RED GREEN YELLOW SKY NC

# 读取镜像清单，过滤注释、空行，并行处理
while IFS= read -r line; do
    line=$(echo "$line" | xargs)
    [[ -z "${line}" || "${line}" =~ ^# ]] && continue
    echo "${line}"
done < images.yaml | xargs -P"${CONCURRENCY}" -I {} bash -c 'process_image "{}"'

# ========== 统计汇总：成功 / 跳过 / 失败 ==========
success_count=$(wc -l < succeeded.log)
skip_count=$(wc -l < skipped.log)
fail_count=$(wc -l < failed.log)

echo -e "\n==================== 同步结果汇总 ===================="
echo -e "${GREEN}✅ 成功镜像数量：${success_count}${NC}"
echo -e "${SKY}⏭️ 跳过镜像数量：${skip_count}${NC}"
echo -e "${RED}❌ 失败镜像数量：${fail_count}${NC}"

if [[ ${success_count} -gt 0 ]];then
    echo -e "\n${GREEN}------ 成功镜像清单 -----${NC}"
    cat succeeded.log
fi
if [[ ${fail_count} -gt 0 ]];then
    echo -e "\n${RED}------ 失败镜像清单 -----${NC}"
    cat failed.log
fi
echo "======================================================"
