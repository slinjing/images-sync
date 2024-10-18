while IFS= read -r image; do

    [[ -z "$image" || "$image" =~ ^#.*$ ]] && continue


    # 镜像名称:
    image_name=$(echo $image | cut -d ":" -f 1)
    if [[ $image_name == */* ]]; then
        image_name=${image_name##*/}
    fi
    echo "镜像名称: $image_name"

    # 获取镜像版本:
    if [[ $image == *:* ]]; then
        image_tag=$(echo "$image" | cut -d':' -f2)
    else
        image_tag=latest
    fi
    echo "镜像版本: $image_tag"


    # 拼接仓库信息:
    target_image="${REGISTRY}/${NAMESPACE}/${image_name}:$image_tag"

    # 处理镜像:
    echo "正在处理镜像: ${image_name}:$image_tag"
    echo "拉取镜像: ${image_name}:$image_tag"
    docker pull $image
    
    if [ $? -eq 0 ]; then
        echo "镜像: $image 拉取完成"
        # # 获取镜ID:
        # # last_image=$(docker images --format '{{.Repository}}:{{.Tag}}' -q | tail -1)
        # # image_id=$(docker images | grep $image_name | awk '{print $3}')
        # image_id=$(docker images --format '{{.ID}}' | head -n 1)
        # a=$(docker images --format '{{.Repository}}:{{.Tag}}' | head -n 1)
        # echo "镜像ID: $image_id"
        # echo "镜像名称: $a"

        # docker images 

        
        docker tag $image $target_image
        if [ $? -eq 0 ]; then
            echo "正在推送: $image_name:$image_tag 到 $target_image"
            docker push $target_image
            if [ $? -eq 0 ]; then
                echo "镜像: $image_name:$image_tag 同步完成，已推送到 $target_image"
            else
                echo "镜像: $image_name:$image_tag Push失败，退出状态码为 $?"
                exit 1
            fi                
        else
            echo "镜像: $image_name:$image_tag Tag失败，退出状态码为 $?"
            exit 1
        fi
    else
        echo "镜像: $image_name:$image_tag Pull失败，退出状态码为 $?"
        exit 1
    fi

done < images.yaml
