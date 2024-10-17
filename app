while IFS= read -r image 
do
    [[ -z "$image" || "$image" =~ ^#.*$ ]] && continue

    # 获取镜像名称：
    image_name=$(echo "$image" | sed 's/.*\/\([^:\/]*\):.*$/\1/')
    # image_name=$(echo $image | cut -d':' -f1)
    echo "镜像名称：$image_name"

    # 获取镜像版本：
    if [[ $image == *:* ]]; then
        image_tag=$(echo "$image" | cut -d':' -f2)
    else
        image_tag=latest
    fi
    echo "镜像名称：$image_tag"


    echo "正在处理镜像: $image_name:$image_tag"
    echo "拉取镜像: $image_name:$image_tag"
    docker pull $image
    if [ $? -eq 0 ]; then
        target_image="${REGISTRY}/${NAMESPACE}/${image_name}:${image_tag}"
        
        docker tag $image $target_image
        if [ $? -eq 0 ]; then
            echo "正在推送：$image 到 $target_image"
            docker push $target_image
            if [ $? -eq 0 ]; then
                echo "镜像 $image 同步完成，已推送到 $target_image"
            else
                echo "镜像Push失败，退出状态码为 $?"
                exit 1
            fi                
        else
            echo "镜像TAG失败，退出状态码为 $?"
            exit 1
        fi
    else
        echo "镜像Pull失败，退出状态码为 $?"
        exit 1
    fi

done < images.yaml
