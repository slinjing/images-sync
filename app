while IFS= read -r image 
do
    [[ -z "$image" || "$image" =~ ^#.*$ ]] && continue
    echo "读取到的行：$image "

    # 获取镜像名称：
    image_name=$(echo "$image" | sed 's/.*\/\([^:\/]*\):.*$/\1/')
    # image_name=$(echo $image | cut -d':' -f1)
    echo $image_name

    # 获取镜像版本：
    image_tag=$(echo "$image" | cut -d':' -f2)
    echo $image_tag


    echo "处理镜像: $image"
    docker pull $image
    if [ $? -eq 0 ]; then
        target_image="${REGISTRY}/${NAMESPACE}/${image_name}:${image_tag}"
        echo "$target_image"
        docker tag $image $target_image
        if [ $? -eq 0 ]; then
            docker push $target_image
            if [ $? -eq 0 ]; then
                echo "镜像 $image 同步完成，已推送到 $target_image"
            else
                echo "镜像TAG失败，退出状态码为 $?"
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
