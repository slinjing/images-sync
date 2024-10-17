          # 读取 images.txt 文件中的镜像列表
          while IFS= read -r image || [[ -n "$image" ]]; do
            # 跳过空行和注释行
            [[ -z "$image" || "$image" =~ ^#.*$ ]] && continue
            
            echo "处理镜像: $image"
            
            # 拉取镜像
            docker pull $image
            
            # 解析镜像名称和标签
            IFS=':' read -r name tag <<< "$image"
            
            # 处理可能包含额外层级的镜像名称
            IFS='/' read -r org repo <<< "$name"
            if [ -z "$repo" ]; then
              repo=$org
              org=""
            fi
            
            # 构建目标镜像名称（确保使用三级目录结构）
            if [ -z "$org" ]; then
               #target_image="${REGISTRY}/${NAMESPACE}/${repo}:${tag}"
               target_image="${{secrets.REGISTRY}}/${{secrets.REGISTRY_USER}}/${repo}:${tag}"
            else
               #target_image="${REGISTRY}/${NAMESPACE}/${org}-${repo}:${tag}"
               target_image="${{secrets.REGISTRY}}/${{secrets.REGISTRY_USER}}/${org}-${repo}:${tag}"
            fi
            
            # 标记镜像
            docker tag $image $target_image
            
            # 推送镜像到腾讯云 Coding
            docker push $target_image
            
            echo "镜像 $image 同步完成，已推送到 $target_image"
          done < images.txt
